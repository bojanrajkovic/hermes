import AppKit
import DiffKit
import Foundation
import GitHubKit
import RepoKit
import SwiftUI
import Testing
import WebKit
@testable import DiffUI

/// Renders the diff viewer to PNG files and measures it, for looking at by
/// hand. Not part of the normal test run:
///
///     DIFFUI_RENDER=/tmp/out DIFFUI_DIFF=/path/to/some.diff swift test --filter DiffUITests.RenderTests
///
/// `DIFFUI_PR=owner/name#number` renders a live pull request instead, and
/// `DIFFUI_TREE=/path/to/worktree` a working tree against `DIFFUI_BASE` (default `HEAD`).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DIFFUI_RENDER"] != nil))
struct RenderTests {
    private let environment = ProcessInfo.processInfo.environment
    private var output: URL { URL(filePath: environment["DIFFUI_RENDER"] ?? NSTemporaryDirectory()) }

    private func loadedModel() async throws -> DiffModel {
        let client = GitHubClient()
        let cache = RepoCache()
        if let reference = environment["DIFFUI_PR"] {
            let parts = reference.split(whereSeparator: { "/#".contains($0) }).map(String.init)
            let pullRequests = try await client.openPullRequests(owner: parts[0])
            let pullRequest = try #require(pullRequests.first { $0.repository.name == parts[1] && $0.number == Int(parts[2]) })
            let model = DiffModel(source: .pullRequest(pullRequest), client: client, repoCache: cache)
            await model.reload()
            return model
        }
        if let tree = environment["DIFFUI_TREE"] {
            let source = DiffSource.workingTree(directory: URL(filePath: tree), baseRef: environment["DIFFUI_BASE"] ?? "HEAD")
            let model = DiffModel(source: source, client: client, repoCache: cache)
            await model.reload()
            return model
        }
        if let reference = environment["DIFFUI_BRANCH"] {
            // `/path/to/checkout#branch`: one branch of the checkout's local stacks.
            let parts = reference.split(separator: "#").map(String.init)
            let checkout = Checkout(repo: RepoID(owner: "local", name: "local"), directory: URL(filePath: parts[0]))
            let branches = try await checkout.stacks().flatMap(\.branches)
            let branch = try #require(branches.first { $0.name == parts[1] })
            let model = DiffModel(source: .localBranch(checkout: checkout, branch: branch), client: client, repoCache: cache)
            await model.reload()
            return model
        }
        let path = try #require(environment["DIFFUI_DIFF"])
        let model = DiffModel(
            source: .workingTree(directory: URL(filePath: "/nonexistent"), baseRef: "main"), client: client, repoCache: cache
        )
        await model.show(text: try String(contentsOfFile: path, encoding: .utf8))
        return model
    }

    /// Watches a pull request (`DIFFUI_LIVE_PR=owner/name#number`) for two
    /// minutes and reports each in-place reload. Push to the pull request's
    /// branch while it runs. The test itself only reads from GitHub.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIFFUI_LIVE_PR"] != nil))
    func pullRequestReloadsOnNewHead() async throws {
        let client = GitHubClient()
        let parts = try #require(environment["DIFFUI_LIVE_PR"]).split(whereSeparator: { "/#".contains($0) }).map(String.init)
        let pullRequests = try await client.openPullRequests(owner: parts[0])
        let pullRequest = try #require(pullRequests.first { $0.repository.name == parts[1] && $0.number == Int(parts[2]) })
        let model = DiffModel(source: .pullRequest(pullRequest), client: client, repoCache: RepoCache())
        let runner = Task { await model.run() }
        defer { runner.cancel() }
        try await wait { model.phase == .loaded }
        let first = model.files[0]
        first.setViewed(true)
        print("LIVEPR loaded files=\(model.files.map(\.id))")

        var seen: Date?
        for _ in 0..<240 {
            try await Task.sleep(for: .milliseconds(500))
            guard model.updatedAt != seen else { continue }
            seen = model.updatedAt
            print("LIVEPR updated files=\(model.files.map(\.id)) keptFirst=\(model.files.first === first) viewed=\(first.isViewed)")
        }
    }

    @Test func renderLayoutsInLightAndDark() async throws {
        let model = try await loadedModel()
        #expect(model.phase == .loaded)
        await model.background?.value
        if let region = environment["DIFFUI_EXPAND"].flatMap(Int.init), let file = model.files.first(where: \.hasRegions) {
            file.expand(region: region, .up(20))
            try await Task.sleep(for: .milliseconds(300))
        }
        if environment["DIFFUI_VIEWED"] != nil { model.files.first?.setViewed(true) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let name = environment["DIFFUI_NAME"] ?? "diff"
        for layout in DiffLayout.allCases {
            model.layout = layout
            for dark in [false, true] {
                let metrics = DiffMetrics(fontSize: environment["DIFFUI_FONT"].flatMap(Double.init) ?? DiffDefaults.fontSize)
                let host = Host(DiffContent(model: model).environment(\.diffMetrics, metrics), dark: dark)
                try await host.settle()
                if let file = environment["DIFFUI_SCROLL"].flatMap(Int.init), model.files.indices.contains(file) {
                    model.scroll.scroll(to: model.files[file].id)
                    try await host.settle()
                }
                try host.write(to: output.appending(path: "\(name)-\(layout.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// Watches a working tree (`DIFFUI_LIVE_TREE`), changes a file in it, and
    /// reports whether the list stayed on the same row through the reload.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIFFUI_LIVE_TREE"] != nil))
    func workingTreeReloadsInPlace() async throws {
        let directory = URL(filePath: try #require(environment["DIFFUI_LIVE_TREE"]))
        let source = DiffSource.workingTree(directory: directory, baseRef: "HEAD")
        let model = DiffModel(source: source, client: GitHubClient(), repoCache: RepoCache())
        let runner = Task { await model.run() }
        defer { runner.cancel() }
        try await wait { model.phase == .loaded }
        await model.background?.value

        let host = Host(DiffContent(model: model), dark: environment["DIFFUI_DARK"] != nil)
        try await host.settle()
        let expandable = try #require(model.files.first { $0.hasRegions && $0.id.hasSuffix("Checkout.swift") })
        model.scroll.scroll(to: expandable.id)
        try await host.settle()
        try host.write(to: output.appending(path: "live-collapsed.png"))
        expandable.expand(region: 1, .up(20))
        expandable.expand(region: 0, .all)
        try await host.settle()
        try host.write(to: output.appending(path: "live-expanded.png"))

        // Reveal everything, so the list is tall enough to scroll.
        for file in model.files {
            for region in 0...file.diff.hunks.count { file.expand(region: region, .all) }
        }
        let target = try #require(model.files.first { $0.id.hasSuffix("Syntax.swift") })
        model.scroll.scroll(to: target.id)
        try await host.settle()
        let scrollView = try #require(host.scrollViews.max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 })
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: scrollView.contentView.bounds.minY + 1207))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await host.settle()
        let before = scrollView.contentView.bounds.minY
        try host.write(to: output.appending(path: "live-before.png"))

        // A change in a file above the visible one.
        let notes = directory.appending(path: "Sources/DiffKit/Notes.swift")
        let text = try String(contentsOf: notes, encoding: .utf8)
        try (text + String(repeating: "let more = 1\n", count: 6)).write(to: notes, atomically: true, encoding: .utf8)
        try await wait { model.updatedAt != nil }
        try await host.settle()
        print("LIVE file=\(model.scroll.currentFile ?? "-") offset before=\(before) after=\(scrollView.contentView.bounds.minY)")
        try host.write(to: output.appending(path: "live-after.png"))
        try text.write(to: notes, atomically: true, encoding: .utf8)
        try await host.settle(for: .seconds(1))

        model.layout = .split
        try await host.settle()
        try host.write(to: output.appending(path: "live-after-split.png"))

        let screen = Host(DiffScreen(source: source, client: GitHubClient(), repoCache: RepoCache()), dark: false)
        try await screen.settle(for: .seconds(2))
        print("LIVE toolbar items=\(screen.window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])")
        try screen.write(to: output.appending(path: "live-screen.png"))
    }

    /// Renders the review features on a live pull request (`DIFFUI_PR`). Drafts
    /// go to a temporary folder and nothing is sent to GitHub.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIFFUI_REVIEW"] != nil))
    func renderReview() async throws {
        let client = GitHubClient()
        let parts = try #require(environment["DIFFUI_PR"]).split(whereSeparator: { "/#".contains($0) }).map(String.init)
        let pullRequests = try await client.openPullRequests(owner: parts[0])
        let pullRequest = try #require(pullRequests.first { $0.repository.name == parts[1] && $0.number == Int(parts[2]) })
        let root = FileManager.default.temporaryDirectory.appending(path: "hermes-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DiffModel(source: .pullRequest(pullRequest), client: client, repoCache: RepoCache(), draftsRoot: root)
        await model.reload()
        await model.background?.value
        let review = try #require(model.review)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let dark = environment["DIFFUI_DARK"] != nil
        let suffix = dark ? "dark" : "light"
        model.layout = environment["DIFFUI_LAYOUT"] == "split" ? .split : .unified

        let host = Host(DiffContent(model: model).environment(\.diffMetrics, DiffMetrics()), dark: dark)
        try await host.settle()
        func shoot(_ name: String, wait: Duration = .milliseconds(1500)) async throws {
            try await host.settle(for: wait)
            try await host.writeComposite(to: output.appending(path: "review-\(name)-\(suffix).png"))
        }
        func scroll(toThread thread: ReviewThread) async throws {
            for (file, lines) in review.layout.lines {
                guard let line = lines.first(where: { $0.value.threads.contains(thread) })?.key else { continue }
                model.scroll.scroll(to: RowID(file: file, item: .line(line)))
            }
            try await host.settle()
        }

        if let thread = review.threads.first(where: { $0.comments.count > 1 && !$0.isOutdated }) {
            try await scroll(toThread: thread)
            try await shoot("thread")
            review.open(.reply(threadID: thread.id))
            review.composer?.text = "Agreed. **Zone** pricing should stay simple:\n\n- one multiplier\n- no special cases"
            try await shoot("reply-composer")
            review.addComposerToReview()
            try await shoot("reply-pending")
        }
        if let thread = review.threads.first(where: { $0.isResolved && !$0.isOutdated }) {
            try await scroll(toThread: thread)
            try await shoot("resolved")
            review.expandedThreads.insert(thread.id)
            try await shoot("resolved-open")
        }

        let target = try #require(model.files.lazy.compactMap { file -> (FileModel, [DiffLine])? in
            guard file.id.hasSuffix(".ts"), let hunk = file.diff.hunks.first(where: { $0.lines.count { $0.kind == .addition } >= 4 }) else { return nil }
            return (file, hunk.lines.filter { $0.kind == .addition })
        }.first)
        model.scroll.scroll(to: RowID(file: target.0.id, item: .line(target.1[0].numbers)))
        review.startComment(file: target.0.id, from: target.1[1], to: target.1[3])
        review.composer?.text = "Could this be a lookup table?\n\n```ts\nconst zones = new Map<string, Zone>();\n```"
        try await shoot("composer")
        review.addComposerToReview()
        // A range that crosses two hunks, for the explanation.
        if target.0.diff.hunks.count > 1, let near = target.0.diff.hunks.first?.lines.first, let far = target.0.diff.hunks.last?.lines.last {
            review.startComment(file: target.0.id, from: near, to: far)
            model.scroll.scroll(to: RowID(file: target.0.id, item: .line(far.numbers)))
            try await shoot("invalid-range", wait: .milliseconds(600))
            review.dismissNotice()
            model.scroll.scroll(to: RowID(file: target.0.id, item: .line(target.1[0].numbers)))
        }
        try await shoot("pending")

        review.summary = "Two small things, otherwise good."
        let finish = Host(FinishReview(review: review) {}.background(.background), dark: dark, size: CGSize(width: 400, height: 420))
        try await finish.settle()
        try await finish.writeComposite(to: output.appending(path: "review-finish-\(suffix).png"))
        let offDiff = Host(OffDiffList(review: review) {}.background(.background), dark: dark, size: CGSize(width: 480, height: 420))
        try await offDiff.settle(for: .seconds(2))
        try await offDiff.writeComposite(to: output.appending(path: "review-outdated-\(suffix).png"))

        if let name = environment["DIFFUI_DEFINE"] {
            let origin = environment["DIFFUI_DEFINE_FROM"] ?? target.0.diff.path
            model.definitions.lookUp(name: name, from: origin)
            try await shoot("definition-searching", wait: .milliseconds(50))
            try await wait {
                if case .searching = model.definitions.current?.phase { false } else { true }
            }
            try await shoot("definition", wait: .milliseconds(800))
            if case .choices(let locations) = model.definitions.current?.phase {
                model.definitions.open(locations[0], name: name)
                try await shoot("definition-chosen", wait: .milliseconds(1200))
            }
            model.definitions.lookUp(name: "noSuchIdentifierAnywhere", from: origin)
            try await shoot("definition-missing", wait: .milliseconds(1200))
            model.definitions.goBack()
            model.definitions.isOpen = false
        }

        if let markdown = model.files.first(where: { $0.isMarkdown && $0.id.contains(environment["DIFFUI_MARKDOWN"] ?? "") }) {
            model.setRendered(true, for: markdown)
            model.scroll.scroll(to: markdown.id)
            try await shoot("markdown", wait: .seconds(5))
            review.startComment(file: markdown.id, newLines: 1...1)
            if let line = markdown.diff.hunks.first?.lines.first(where: { $0.kind == .addition })?.newNumber {
                review.startComment(file: markdown.id, newLines: line...line)
                review.composer?.text = "From the rendered view."
            }
            try await shoot("markdown-composer", wait: .seconds(2))
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }

    /// Renders the composer and the Finish Review popover with their main buttons disabled and enabled.
    @Test func renderProminentButtons() async throws {
        let pullRequest = PullRequest(
            id: "PR", number: 1, title: "", url: URL(string: "https://github.com/a/b/pull/1")!,
            repository: RepositoryRef(owner: "a", name: "b"), author: nil, isDraft: false, createdAt: .now, updatedAt: .now,
            headRefName: "", baseRefName: "", headOID: "", reviewDecision: nil, additions: 0, deletions: 0,
            changedFileCount: 0, mergeable: .unknown, labels: [], checkState: nil, stack: nil, closingIssueNumbers: []
        )
        let root = FileManager.default.temporaryDirectory.appending(path: "hermes-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let review = ReviewModel(pullRequest: pullRequest, client: GitHubClient(), draftsRoot: root)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            review.open(.reply(threadID: "thread"))
            let buttons = VStack(spacing: 12) {
                CommentComposer(review: review, title: "Reply")
                FinishReview(review: review) {}
            }
            .padding()
            .background(.background)
            // An offscreen window is never the key window. This draws the buttons as they look in one.
            .environment(\.appearsActive, true)
            let host = Host(buttons, dark: dark, size: CGSize(width: 520, height: 640))
            try await host.settle()
            try host.write(to: output.appending(path: "buttons-disabled-\(suffix).png"))
            review.composer?.text = "Text"
            review.summary = "Summary"
            try await host.settle()
            try host.write(to: output.appending(path: "buttons-enabled-\(suffix).png"))
            review.cancelComposer()
            review.confirmDiscard()
            review.summary = ""
        }
    }

    /// Checks that the list stays on the row being read while rows above it come, go, and change height.
    /// Needs a diff (`DIFFUI_DIFF`) with at least three files, each taller than the window.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIFFUI_DIFF"] != nil))
    func theListKeepsItsPlace() async throws {
        let model = DiffModel(
            source: .workingTree(directory: URL(filePath: "/nonexistent"), baseRef: "main"), client: GitHubClient(), repoCache: RepoCache()
        )
        await model.show(text: try String(contentsOfFile: try #require(environment["DIFFUI_DIFF"]), encoding: .utf8))
        await model.background?.value
        let host = Host(DiffContent(model: model), dark: false)
        try await host.settle()
        let scrollView = try #require(host.scrollViews.max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 })
        /// The first code line below the pinned file header.
        func firstLine() -> RowID? {
            model.scroll.visible.first { if case .line = $0.item { true } else { false } }
        }

        let file = model.files[2]
        let target = try #require(file.rows.dropFirst(file.rows.count / 2).first { if case .unified = $0.kind { true } else { false } }).id
        model.scroll.scroll(to: target)
        try await host.settle()
        #expect(firstLine() == target)
        #expect(model.scroll.currentFile == file.id)

        // Rows above go away and come back.
        model.files[0].isCollapsed = true
        try await host.settle()
        #expect(firstLine() == target)
        model.files[0].isCollapsed = false
        try await host.settle()
        #expect(firstLine() == target)

        // A revealed row goes to the middle, clear of the pinned header.
        let revealed = try #require(model.files[4].rows.last { if case .unified = $0.kind { true } else { false } }).id
        model.files[4].isCollapsed = true
        model.reveal(revealed)
        try await host.settle()
        let table = try #require(scrollView.documentView as? NSTableView)
        let row = try #require(tableRows(files: model.files).firstIndex { $0.id == revealed })
        let free = scrollView.contentView.bounds.insetBy(dx: 0, dy: DiffMetrics.headerHeight / 2).offsetBy(dx: 0, dy: DiffMetrics.headerHeight / 2)
        #expect(abs(table.rect(ofRow: row).midY - free.midY) < 2)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try host.write(to: output.appending(path: "revealed.png"))
        model.scroll.scroll(to: target)
        try await host.settle()

        // Scrolled by hand, so no request holds the row. Then every row changes.
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: scrollView.contentView.bounds.minY + 400))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        try await host.settle()
        let read = try #require(firstLine())
        #expect(read != target)
        model.files[1].isCollapsed = true
        try await host.settle()
        #expect(firstLine() == read)
        model.layout = .split
        try await host.settle()
        #expect(firstLine() == read)
        model.layout = .unified
        try await host.settle()
        #expect(firstLine() == read)

        // A narrower window wraps lines above.
        host.window.setContentSize(CGSize(width: 900, height: 900))
        try await host.settle()
        #expect(firstLine() == read)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try host.write(to: output.appending(path: "place.png"))
    }

    /// Opens a diff, then scrolls through all of it, timing each step.
    @Test func measure() async throws {
        let clock = ContinuousClock()
        let text = try String(contentsOfFile: try #require(environment["DIFFUI_DIFF"]), encoding: .utf8)
        // `DIFFUI_AS_PR` measures with the review views in the rows.
        let pullRequest = PullRequest(
            id: "PR", number: 1, title: "", url: URL(string: "https://github.com/a/b/pull/1")!,
            repository: RepositoryRef(owner: "a", name: "b"), author: nil, isDraft: false, createdAt: .now, updatedAt: .now,
            headRefName: "", baseRefName: "", headOID: "", reviewDecision: nil, additions: 0, deletions: 0,
            changedFileCount: 0, mergeable: .unknown, labels: [], checkState: nil, stack: nil, closingIssueNumbers: []
        )
        let model = DiffModel(
            source: environment["DIFFUI_AS_PR"] != nil
                ? .pullRequest(pullRequest) : .workingTree(directory: URL(filePath: "/nonexistent"), baseRef: "main"),
            client: GitHubClient(), repoCache: RepoCache(),
            layout: environment["DIFFUI_LAYOUT"] == "split" ? .split : .unified,
            draftsRoot: FileManager.default.temporaryDirectory.appending(path: "hermes-measure")
        )

        if environment["DIFFUI_EXACT_HEIGHTS"] != nil {
            // AppKit then asks for every row's height up front. It reads this once per process.
            UserDefaults.standard.register(defaults: ["NSTableViewCanEstimateRowHeights": false])
        }
        var host: Host<DiffContent>!
        let open = await clock.measure {
            await model.show(text: text)
            host = Host(DiffContent(model: model), dark: false)
            host.view.layoutSubtreeIfNeeded()
            host.view.displayIfNeeded()
        }
        let highlight = await clock.measure { await model.background?.value }
        let rows = model.files.reduce(0) { $0 + $1.rows.count }
        print("MEASURE files=\(model.files.count) rows=\(rows) open=\(open) highlight=\(highlight)")

        try await host.settle()
        let scrollView = try #require(host.scrollViews.max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 })
        var frames: [Duration] = []
        var offset: CGFloat = 0
        // How far the document height moves while scrolling, and how far that moves the scroll bar's knob.
        func height() -> CGFloat { scrollView.documentView?.frame.height ?? 0 }
        let viewHeight = scrollView.contentSize.height
        let startHeight = height()
        var heightChanges = 0
        var largestChange: CGFloat = 0
        var largestKnobMove: CGFloat = 0
        var lastHeight = startHeight
        // A fast scroll: 120 points per frame. `DIFFUI_PASSES` scrolls down and back up that many times, for a profiler.
        let passes = environment["DIFFUI_PASSES"].flatMap(Int.init) ?? 1
        var step: CGFloat = 120
        var pass = 0
        while pass < passes {
            offset += step
            if offset >= height() - viewHeight || offset <= 0 {
                pass += step > 0 ? 1 : 0
                step = passes > 1 ? -step : step
            }
            defer {
                if height() != lastHeight {
                    heightChanges += 1
                    largestChange = max(largestChange, abs(height() - lastHeight))
                    let knobMove = abs(offset / (height() - viewHeight) - offset / (lastHeight - viewHeight)) * viewHeight
                    largestKnobMove = max(largestKnobMove, knobMove)
                    lastHeight = height()
                }
            }
            frames.append(clock.measure {
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                RunLoop.main.run(until: Date())
                host.view.layoutSubtreeIfNeeded()
                host.view.displayIfNeeded()
            })
        }
        frames.sort()
        let total = frames.reduce(Duration.zero, +)
        print(
            "MEASURE scroll frames=\(frames.count) height=\(Int(scrollView.documentView?.frame.height ?? 0))",
            "mean=\(total / max(frames.count, 1)) p95=\(frames[frames.count * 95 / 100]) max=\(frames.last ?? .zero)",
            "over16ms=\(frames.count { $0 > .milliseconds(16) })"
        )
        print(
            "MEASURE height start=\(Int(startHeight)) end=\(Int(height())) changes=\(heightChanges)",
            "largestChange=\(Int(largestChange)) largestKnobMove=\((largestKnobMove * 10).rounded() / 10)pt"
        )
        try await host.settle(for: .milliseconds(50))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try host.write(to: output.appending(path: "measure-end.png"))

        let jump = try await clock.measure {
            model.scroll.scroll(to: model.files[model.files.count / 2].id)
            try await host.settle(for: .milliseconds(50))
        }
        print("MEASURE jump-to-middle-file=\(jump)")
        try host.write(to: output.appending(path: "measure-jump.png"))
    }
}

/// An offscreen window around a SwiftUI view.
@MainActor
private final class Host<Content: View> {
    let window: NSWindow
    let view: NSHostingView<Content>

    init(_ content: Content, dark: Bool, size: CGSize = CGSize(width: 1400, height: 900)) {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view = NSHostingView(rootView: content)
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
    }

    var scrollViews: [NSScrollView] {
        func find(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(find)
        }
        return find(view)
    }

    /// Lets SwiftUI lay out and lazy content load.
    func settle(for duration: Duration = .milliseconds(400)) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: duration)
        view.layoutSubtreeIfNeeded()
    }

    var webViews: [WKWebView] {
        func find(_ view: NSView) -> [WKWebView] {
            ((view as? WKWebView).map { [$0] } ?? []) + view.subviews.flatMap(find)
        }
        return find(view)
    }

    /// Writes the view with its web views drawn in. `cacheDisplay` leaves them blank.
    func writeComposite(to url: URL) async throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var images: [(NSImage, CGRect)] = []
        for web in webViews where !web.visibleRect.isEmpty {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = web.visibleRect
            guard let image = try? await web.takeSnapshot(configuration: configuration) else { continue }
            images.append((image, web.convert(web.visibleRect, to: view)))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for (image, frame) in images {
            let y = view.isFlipped ? view.bounds.height - frame.maxY : frame.minY
            image.draw(in: CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    func write(to url: URL) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

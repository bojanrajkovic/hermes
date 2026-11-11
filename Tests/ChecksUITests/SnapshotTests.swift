import AppKit
import GitHubKit
import SwiftUI
import Testing
import WebKit
@testable import ChecksUI

/// Renders the views to PNG files for looking at, in light and dark. Not
/// assertions: run with `HERMES_SNAPSHOT_DIR=/some/dir swift test --filter Snapshots`.
/// The `live` ones read GitHub with the `gh` token.
private let snapshotDirectory = ProcessInfo.processInfo.environment["HERMES_SNAPSHOT_DIR"]

@MainActor
func snapshot(
    _ name: String, size: CGSize, settle: Duration = .milliseconds(600),
    interact: (@MainActor (NSView) async -> Void)? = nil, @ViewBuilder _ view: () -> some View
) async throws {
    let directory = URL(fileURLWithPath: try #require(snapshotDirectory))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared

    let content = view()
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height).background(.background))
        window.contentView = host
        window.orderBack(nil)

        try await Task.sleep(for: settle)
        if let interact {
            await interact(host)
            try await Task.sleep(for: settle)
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "\(name)-\(suffix).png"))

        // cacheDisplay leaves a web view blank; it has its own snapshot call.
        @MainActor func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            for subview in view.subviews { if let found = webView(in: subview) { return found } }
            return nil
        }
        if let web = webView(in: host), let image = try? await web.takeSnapshot(configuration: nil),
           let tiff = image.tiffRepresentation, let webPNG = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try webPNG.write(to: directory.appending(path: "\(name)-web-\(suffix).png"))
        }
        window.close()
    }
}

@Suite(.enabled(if: snapshotDirectory != nil), .serialized) @MainActor struct Snapshots {
    let playground = RepositoryRef(owner: "bojanrajkovic", name: "hermes-playground")
    let now = Date.now

    var everyState: [Check] {
        let start = now.addingTimeInterval(-200)
        return [
            run("build", started: start, completed: start.addingTimeInterval(34)),
            run("tests", .completed, .failure, started: start, completed: start.addingTimeInterval(130)),
            run("integration", .inProgress, nil, started: now.addingTimeInterval(-64)),
            run("deploy preview", .queued, nil),
            run("docs", .completed, .skipped),
            run("e2e", .completed, .cancelled, started: start, completed: start.addingTimeInterval(4000)),
            run("PR title", workflow: "pr", started: start, completed: start.addingTimeInterval(7)),
            run("approve deploy", .completed, .actionRequired, workflow: "pr"),
            run("Vercel – hermes-playground with a rather long name", .completed, .neutral, workflow: nil, app: "Vercel"),
            .status(.init(context: "ci/circleci: build", state: .success, targetURL: nil, description: "Your tests passed")),
            .status(.init(context: "codecov/patch", state: .failure, targetURL: nil, description: "62% of diff hit")),
        ]
    }

    @Test func list() async throws {
        let checks = everyState
        try await snapshot("list", size: CGSize(width: 300, height: 620)) {
            CheckListView(groups: CheckList.grouped(checks), selection: .constant(checks[1].id))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CheckListFooter(rollup: CheckList.rollup(checks)) {}
                }
        }
    }

    @Test func summary() async throws {
        let checks = everyState
        try await snapshot("summary", size: CGSize(width: 360, height: 340)) {
            CheckSummaryList(checks: checks, onSelect: { _ in }).padding()
        }
    }

    @Test func steps() async throws {
        let start = now.addingTimeInterval(-90)
        let steps = [
            JobStep(number: 1, name: "Set up job", status: "completed", conclusion: "success", startedAt: start, completedAt: start.addingTimeInterval(2)),
            JobStep(number: 2, name: "Run actions/checkout@v3", status: "completed", conclusion: "success", startedAt: start, completedAt: start.addingTimeInterval(3)),
            JobStep(number: 3, name: "Install dependencies", status: "completed", conclusion: "skipped", startedAt: nil, completedAt: nil),
            JobStep(number: 4, name: "Run tests", status: "in_progress", conclusion: nil, startedAt: now.addingTimeInterval(-42), completedAt: nil),
            JobStep(number: 5, name: "Upload coverage", status: "pending", conclusion: nil, startedAt: nil, completedAt: nil),
        ]
        let check = run("tests", .inProgress, nil, started: start)
        try await snapshot("steps", size: CGSize(width: 560, height: 360)) {
            VStack(spacing: 0) {
                CheckDetailHeader(check: check)
                Divider()
                CheckDetailContent(check: check, content: .steps(steps), retry: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @Test func states() async throws {
        let skipped = run("docs", .completed, .skipped)
        try await snapshot("nolog", size: CGSize(width: 560, height: 320)) {
            CheckDetailContent(check: skipped, content: .noLog, retry: {})
        }
        let status = Check.status(.init(
            context: "codecov/patch", state: .failure, targetURL: URL(string: "https://example.com"), description: "62% of diff hit (target 80%)"
        ))
        try await snapshot("status", size: CGSize(width: 560, height: 320)) {
            VStack(spacing: 0) {
                CheckDetailHeader(check: status)
                Divider()
                CheckDetailContent(check: status, content: .status("62% of diff hit (target 80%)"), retry: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        try await snapshot("failed", size: CGSize(width: 560, height: 320)) {
            CheckDetailContent(check: skipped, content: .failed(ChecksError.message(for: GitHubError.http(status: 502, message: ""))), retry: {})
        }
    }

    @Test func fixtureLogs() async throws {
        for name in ["pg-tests-fail", "pg-build-pass"] {
            let model = await LogViewModel.load(raw: try fixture(name))
            try await snapshot("log-\(name)", size: CGSize(width: 820, height: 560)) { LogView(model: model) }
        }

        let model = await LogViewModel.load(raw: try fixture("pg-tests-fail"))
        model.setAllExpanded(true)
        model.showTimestamps = true
        model.wrapsLines = true
        model.query = "git"
        try await snapshot("log-options", size: CGSize(width: 820, height: 560)) { LogView(model: model) }
    }

    /// A failing log whose first error is far down opens there.
    @Test func farError() async throws {
        let filler = (1...60_000).map { "2026-11-11T02:46:28.1143357Z line \($0)" }.joined(separator: "\n")
        let model = await LogViewModel.load(raw: filler + "\n2026-11-11T02:46:29.1143357Z ##[error]Process completed with exit code 1.\nafter\n")
        try await snapshot("log-far-error", size: CGSize(width: 820, height: 400)) { LogView(model: model) }
    }

    @Test func liveFailingAndPassing() async throws {
        let client = GitHubClient()
        // PR 3: "tests" fails.
        let commit = "aa3e376b7c00cbc6cce94635c30ae16a647ec7ba"
        try await snapshot("screen-failing", size: CGSize(width: 1100, height: 640), settle: .seconds(5)) {
            ChecksScreen(repository: playground, commitOID: commit, client: client)
        }
        // Looked up by name: a re-run gives the check a new ID.
        let build = try #require(try await client.checks(repository: playground, commitOID: commit).first { $0.name == "build" })
        try await snapshot("screen-passing", size: CGSize(width: 1100, height: 640), settle: .seconds(5)) {
            ChecksScreen(repository: playground, commitOID: commit, client: client, initiallySelected: build)
        }
        try await snapshot("summary-live", size: CGSize(width: 360, height: 140), settle: .seconds(4)) {
            ChecksSummary(repository: playground, commitOID: commit, client: client, onSelect: { _ in }).padding()
        }
    }

    /// Clicks a collapsed group's title in the real text view, then searches.
    @Test func interaction() async throws {
        let model = await LogViewModel.load(raw: try fixture("pg-tests-fail"))
        let title = try #require(model.document.lines.firstIndex { $0.kind == .group && $0.text == "format" })
        try await snapshot("log-clicked", size: CGSize(width: 820, height: 560), interact: { host in
            @MainActor func find(_ view: NSView) -> GroupClickTextView? {
                if let textView = view as? GroupClickTextView { return textView }
                for subview in view.subviews { if let found = find(subview) { return found } }
                return nil
            }
            guard let textView = find(host), let layout = textView.layoutManager, let container = textView.textContainer,
                  let row = model.rendered.row(ofLine: title) else {
                Issue.record("no text view or row")
                return
            }
            let glyphs = layout.glyphRange(forCharacterRange: model.rendered.characterRange(ofRow: row), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let point = textView.convert(NSPoint(x: rect.minX + 40, y: rect.midY + textView.textContainerOrigin.y), to: nil)
            let wasOpen = model.expanded.count
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: textView.window!.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            textView.mouseDown(with: event)
            #expect(model.expanded.count != wasOpen)
        }) { LogView(model: model) }

        model.query = "checkout"
        try await snapshot("log-searched", size: CGSize(width: 820, height: 560), interact: { host in
            model.step(by: 1)
            model.step(by: 1)

            // ⌘F puts the cursor in the search field.
            let window = host.window!
            let before = window.firstResponder
            let commandF = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
            )!
            #expect(window.performKeyEquivalent(with: commandF))
            try? await Task.sleep(for: .milliseconds(300))
            print("first responder:", String(describing: before), "->", String(describing: window.firstResponder))
        }) { LogView(model: model) }
        #expect(model.currentMatch != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERMES_SNAPSHOT_COMMIT"] != nil))
    func liveCommit() async throws {
        // HERMES_SNAPSHOT_COMMIT=owner/name@sha[#check-id] renders any commit, after HERMES_SNAPSHOT_SETTLE seconds.
        let spec = try #require(ProcessInfo.processInfo.environment["HERMES_SNAPSHOT_COMMIT"])
        let parts = spec.split(whereSeparator: { "/@#".contains($0) }).map(String.init)
        let selected = parts.count > 3 ? run("x", workflow: nil, id: Int(parts[3]) ?? 0) : nil
        let settle = ProcessInfo.processInfo.environment["HERMES_SNAPSHOT_SETTLE"].flatMap(Int.init) ?? 6
        try await snapshot("screen-commit", size: CGSize(width: 1100, height: 640), settle: .seconds(settle)) {
            ChecksScreen(
                repository: RepositoryRef(owner: parts[0], name: parts[1]), commitOID: parts[2],
                client: GitHubClient(), initiallySelected: selected
            )
        }
    }

    /// Timings for a 60,000-line log, printed for reading.
    @Test func largeLog() async throws {
        let body = try fixture("pg-tests-fail").split(separator: "\n").dropFirst()
        var raw = ""
        while raw.utf8.count < 5_500_000 { raw += body.joined(separator: "\n") + "\n" }
        let clock = ContinuousClock()

        var document = LogDocument()
        print("lines:", raw.split(separator: "\n").count, "bytes:", raw.utf8.count)
        print("parse:", clock.measure { document = LogParser.parse(raw) })
        print("render collapsed:", clock.measure { _ = LogRenderer.render(document, expanded: document.sectionsWithErrors, showTimestamps: false) })
        print("render expanded:", clock.measure { _ = LogRenderer.render(document, expanded: Set(document.sections.indices), showTimestamps: true) })
        print("search:", clock.measure { print("matches:", LogSearch.matches(of: "git", in: document).count) })

        // The main-thread cost: putting the text in a text view and jumping around in it.
        let rendered = LogRenderer.render(document, expanded: Set(document.sections.indices), showTimestamps: false)
        let storage = NSTextStorage(), layout = NSLayoutManager(), container = NSTextContainer()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 560), textContainer: container)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
        scrollView.documentView = textView
        print("set text:", clock.measure { storage.setAttributedString(rendered.text); textView.sizeToFit() })
        for fraction in [0.5, 1.0, 0.25] {
            let range = NSRange(location: Int(Double(storage.length - 1) * fraction), length: 1)
            print("jump to \(fraction):", clock.measure {
                textView.scrollRangeToVisible(range)
                layout.ensureLayout(forBoundingRect: textView.visibleRect, in: container)
                textView.displayIfNeeded()
            }, "height:", textView.frame.height)
        }
        let target = document.sections.count / 2
        let closed = LogRenderer.render(document, expanded: rendered.expanded.subtracting([target]), showTimestamps: false)
        let lines = document.sections[target].header..<document.sections[target].body.upperBound
        print("close one group:", clock.measure {
            storage.replaceCharacters(
                in: rendered.characterRange(ofLines: lines),
                with: closed.text.attributedSubstring(from: closed.characterRange(ofLines: lines))
            )
            layout.ensureLayout(forBoundingRect: textView.visibleRect, in: container)
        }, "same text:", storage.string == closed.text.string)
        let matches = LogSearch.matches(of: "git", in: document)
        print("tint matches:", clock.measure {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            for match in matches.prefix(5000) {
                guard let range = closed.characterRange(of: match) else { continue }
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor, forCharacterRange: range)
            }
        })
        print("set text again:", clock.measure { storage.setAttributedString(rendered.text) })

        let start = clock.now
        let model = await LogViewModel.load(raw: raw)
        model.setAllExpanded(true)
        print("load:", clock.now - start)
        try await snapshot("log-large", size: CGSize(width: 820, height: 560), settle: .seconds(2)) { LogView(model: model) }
    }
}

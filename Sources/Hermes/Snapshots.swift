import AppKit
import GitHubKit
import HermesUI
import SwiftUI
import WebKit

/// Renders the app's screens to PNG files with live GitHub data, so layout
/// can be checked without a person at the screen.
///
/// Run the built executable with `HERMES_SNAPSHOT_DIR=<directory>`. Optional:
/// `HERMES_SNAPSHOT_SCENES` (comma-separated scene name prefixes) and
/// `HERMES_SNAPSHOT_ORG` (the organization the second account's scenes use; without it they are skipped).
/// Reads from GitHub only. Uses its own settings, not the app's.
@MainActor
enum Snapshots {
    static func run(into directory: URL) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await render(into: directory)
            } catch {
                print("snapshot failed: \(error)")
            }
            exit(0)
        }
        application.run()
    }

    private static let size = NSSize(width: 1360, height: 860)

    private static func render(into directory: URL) async throws {
        let environment = ProcessInfo.processInfo.environment
        let wanted = environment["HERMES_SNAPSHOT_SCENES"]?.split(separator: ",").map(String.init)
        let organization = environment["HERMES_SNAPSHOT_ORG"]

        /// - Parameter act: Runs once the view is on screen, for what a user would do next.
        func scene(
            _ name: String, size: NSSize = size, settle: Duration = .seconds(3), _ view: some View, model: AppModel,
            act: (NSWindow) -> Void = { _ in }
        ) async throws {
            guard wanted?.contains(where: name.hasPrefix) ?? true else { return }
            for dark in [false, true] {
                let url = directory.appending(path: "\(name)-\(dark ? "dark" : "light").png")
                try await snapshot(view.environment(model), size: size, dark: dark, settle: settle, act: act, to: url)
                print("wrote \(url.path)")
            }
        }

        let defaults = UserDefaults(suiteName: "hermes-snapshots")!
        defaults.removePersistentDomain(forName: "hermes-snapshots")
        let model = AppModel(defaults: defaults)
        await model.start()
        guard let viewer = model.viewer else {
            if case .failed(let problem) = model.startup {
                try await scene("startup-problem", StartupProblemView(problem: problem) {}, model: model)
            }
            return
        }

        try await scene("startup-problem", StartupProblemView(problem: .ghNotInstalled) {}, model: model)
        try await scene("profile", size: NSSize(width: 300, height: 320), ProfileCard(viewer: viewer), model: model)
        try await scene("settings", size: NSSize(width: 500, height: 320), SettingsView(), model: model)

        // The personal account.
        model.show(.filter(.needsReview))
        model.normalizeScope()
        try await scene("personal-inbox", MainView(), model: model)

        // A stack: its header, switcher, and conversation.
        let stacked = model.pullRequests.first { $0.stack?.position == 2 && $0.repository.name == "airway" }
            ?? model.pullRequests.first { $0.stack != nil }
        if let stacked {
            model.navigate(to: .pullRequest(stacked.key), tab: .conversation)
            try await scene("pull-request-conversation", settle: .seconds(8), MainView(), model: model)
            model.show(.filter(.yours))
            model.navigate(to: .pullRequest(stacked.key), tab: .files)
            try await scene("pull-request-files", MainView(), model: model)
        }

        // The palette, empty and with queries.
        model.normalizeScope()
        for (name, query) in [("empty", ""), ("repository", "airway"), ("reference", "airway#95"), ("title", "fix")] {
            try await scene("palette-\(name)", CommandPalette(initialQuery: query).background(MainView()), model: model)
        }

        // The palette's keyboard: a press of the down arrow moves the highlight to the second row.
        try await scene("palette-keys", CommandPalette(initialQuery: "re").background(MainView()), model: model) { window in
            guard let field = textFields(in: window.contentView).first else { return print("palette-keys: no text field") }
            window.makeFirstResponder(field)
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
                charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125
            ) { window.sendEvent(event) }
        }

        // A merged pull request and a closed issue, loaded by number the way `repo#123` does it.
        if let merged = environment["HERMES_SNAPSHOT_MERGED"].flatMap(reference) {
            await model.open(merged)
            print("opened \(merged): \(model.resolveError ?? "ok")")
            try await scene("fetched-pull-request", settle: .seconds(6), MainView(), model: model) { _ in
                model.pullRequestTab = .conversation
            }
        }
        if let closed = environment["HERMES_SNAPSHOT_CLOSED"].flatMap(reference) {
            await model.open(closed)
            print("opened \(closed): \(model.resolveError ?? "ok")")
            try await scene("fetched-issue", settle: .seconds(6), MainView(), model: model)
        }

        // An organization: a repository with many issues, and repositories with many pull requests.
        guard let organization, let account = viewer.accounts.first(where: { $0.login == organization }) else { return }
        model.destination = nil
        model.select(account)
        while !model.hasLoaded { try await Task.sleep(for: .milliseconds(200)) }

        let busiest = model.sections.max { $0.openIssueCount < $1.openIssueCount }
        model.normalizeScope()
        try await scene("org-inbox", MainView(), model: model)
        guard let busiest else { return }

        model.show(.repository(busiest.ref), list: .issues)
        try await scene("org-issues", settle: .seconds(6), MainView(), model: model)
        print("\(model.issueList(of: busiest.ref).items.count) issues loaded of \(busiest.openIssueCount)")

        model.show(.filter(.all))
        try await scene("org-inbox-all", MainView(), model: model)

        // An issue with labels and, when there is one, a linked pull request.
        let issues = model.issueList(of: busiest.ref).items
        if let issue = issues.first(where: { !$0.linkedPullRequests.isEmpty && !$0.labels.isEmpty }) ?? issues.first {
            model.show(.repository(busiest.ref), list: .issues)
            model.navigate(to: .issue(ItemKey(repository: busiest.ref, number: issue.number)))
            try await scene("issue-detail", settle: .seconds(8), MainView(), model: model)
            if let last = issues.last {
                try await scene("issue-scroll", MainView(), model: model) { _ in
                    model.navigate(to: .issue(ItemKey(repository: busiest.ref, number: last.number)))
                }
            }
        }
    }

    /// Lays `view` out in a window that is never shown, waits for it to load,
    /// and writes the window, title bar included, to a PNG.
    private static func snapshot(
        _ view: some View, size: NSSize, dark: Bool, settle: Duration, act: (NSWindow) -> Void, to url: URL
    ) async throws {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        act(window)
        try await Task.sleep(for: settle)
        window.layoutIfNeeded()

        guard let target = window.contentView?.superview ?? window.contentView,
              let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: bitmap)

        // Web views draw in another process, so `cacheDisplay` leaves them blank.
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            for webView in webViews(in: target) where !webView.visibleRect.isEmpty {
                let configuration = WKSnapshotConfiguration()
                configuration.rect = webView.visibleRect
                guard let image = try? await webView.takeSnapshot(configuration: configuration) else { continue }
                var frame = webView.convert(webView.visibleRect, to: target)
                if target.isFlipped { frame.origin.y = target.bounds.height - frame.maxY }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }

    /// Parses `owner/name#123`.
    private static func reference(_ text: String) -> ItemKey? {
        guard let match = text.wholeMatch(of: /([^\/]+)\/([^#]+)#(\d+)/), let number = Int(match.3) else { return nil }
        return ItemKey(repository: RepositoryRef(owner: String(match.1), name: String(match.2)), number: number)
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        return ((view as? NSTextField)?.isEditable == true ? [view as! NSTextField] : []) + view.subviews.flatMap(textFields)
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
}

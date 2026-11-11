import AppKit
import GhosttyTerminal
import GitHubKit
import RepoKit
import SwiftUI
import Testing
@testable import SessionsUI

/// Tests that start real processes in real terminals, and render the views to
/// PNG files for a person to look at. They run only when `HERMES_LIVE_DIR`
/// names a directory for the output:
///
///     HERMES_LIVE_DIR=/tmp/hermes-live swift test --filter SessionsUITests
///
/// `HERMES_LIVE_CLAUDE=1` adds the tests that start `claude` itself, one of
/// which registers a short-lived Remote Control session on the user's account.
let liveDirectory = ProcessInfo.processInfo.environment["HERMES_LIVE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
let liveClaude = liveDirectory != nil && ProcessInfo.processInfo.environment["HERMES_LIVE_CLAUDE"] == "1"

@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        try #require(ContinuousClock.now < deadline, "timed out waiting until \(what)")
        try await Task.sleep(for: .milliseconds(50))
    }
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// A SwiftUI view in an offscreen window.
@MainActor
struct Stage {
    let window: NSWindow

    init(width: CGFloat, height: CGFloat, dark: Bool = false) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    func show(_ view: some View) {
        // A sheet draws on its window's background, which a bitmap does not have.
        window.contentView = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.layoutIfNeeded()
    }

    func clear() {
        window.contentView = NSView()
    }

    /// Writes the window's content to `<liveDirectory>/<name>.png`. A terminal
    /// draws with Metal, which `cacheDisplay` misses, so its last frame is
    /// drawn over its place.
    func snapshot(_ name: String, terminal: TerminalView? = nil) throws {
        let directory = try #require(liveDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)

        if let terminal, terminal.window === window, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            var frame = terminal.convert(terminal.bounds, to: content)
            if content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
            for layer in [terminal.layer].compactMap({ $0 }) + (terminal.layer?.sublayers ?? []) {
                guard let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { continue }
                let image = CIImage(ioSurface: unsafeDowncast(contents as AnyObject, to: IOSurface.self))
                if let cgImage = CIContext().createCGImage(image, from: image.extent) {
                    context.cgContext.draw(cgImage, in: frame)
                }
            }
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "\(name).png"))
    }
}

@MainActor
func makeSession(script: String, directory: URL? = nil, origin: SessionOrigin = pullRequest) throws -> ClaudeSession {
    try ClaudeSession(
        origin: origin, title: origin.defaultSessionName, environment: .local(remoteControl: true),
        workingDirectory: directory, branch: origin.branchName, baseRef: "origin/main",
        commandLine: "sh", script: script, processDirectory: directory, checkout: nil
    )
}

/// Everything on the terminal's screen and scrollback, as text.
@MainActor
func screenText(of session: ClaudeSession) -> String {
    guard let surface = session.terminalState.surface else { return "" }
    _ = surface.performBindingAction("select_all")
    defer { _ = surface.performBindingAction("clear_selection") }
    return surface.readSelection() ?? ""
}

@MainActor
@Suite(.enabled(if: liveDirectory != nil), .serialized)
struct LiveTerminalTests {
    @Test func processOutlivesItsViewAndTheSameTerminalComesBack() async throws {
        let out = FileManager.default.temporaryDirectory.appending(path: "hermes-ticks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        func ticks() -> Int { (try? String(contentsOf: out, encoding: .utf8))?.split(separator: "\n").count ?? 0 }

        // Prints faster than a pty buffer can hold for long: if nothing
        // drained the terminal while it is off screen, the loop would stall.
        let session = try makeSession(script: """
            #!/bin/sh
            i=0
            while [ $i -lt 100000 ]; do
              echo "tick $i with some padding to fill the pty buffer quickly ................................................"
              echo $i >> \(shellQuoted(out.path))
              i=$((i+1))
              sleep 0.01
            done
            """)

        // The process starts before any SwiftUI view shows the session.
        try await waitUntil("the process runs while parked") { ticks() > 5 }
        let terminal = session.terminalView
        let pid = try #require(session.foregroundPid)
        #expect(isAlive(pid))

        let stage = Stage(width: 900, height: 560)
        stage.show(SessionTerminalView(session: session))
        try await waitUntil("the terminal is on stage") { terminal.window === stage.window }
        try await Task.sleep(for: .seconds(1))
        #expect(screenText(of: session).contains("tick"))
        try stage.snapshot("terminal-running-light", terminal: terminal)

        // Navigate away: the SwiftUI view is torn down.
        stage.clear()
        try await waitUntil("the terminal is parked") { terminal.window != nil && terminal.window !== stage.window }
        let before = ticks()
        try await Task.sleep(for: .seconds(3))
        let after = ticks()
        #expect(after > before + 100, "the process stalled while off screen: \(before) -> \(after)")
        #expect(session.state == .running)

        // Come back: the same view, the same process, the earlier output.
        stage.show(SessionTerminalView(session: session))
        try await waitUntil("the terminal is back on stage") { session.terminalView.window === stage.window }
        #expect(session.terminalView === terminal)
        #expect(session.foregroundPid == pid)
        #expect(screenText(of: session).contains("tick 3 "))

        session.terminate()
        try await waitUntil("the process is gone") { !isAlive(pid) }
        #expect(session.state == .exited)
    }

    @Test func exitIsDetectedAndRestartRunsAgain() async throws {
        let out = FileManager.default.temporaryDirectory.appending(path: "hermes-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        func runs() -> Int { (try? String(contentsOf: out, encoding: .utf8))?.split(separator: "\n").count ?? 0 }

        let session = try makeSession(script: """
            #!/bin/sh
            echo "run in $PWD"
            echo run >> \(shellQuoted(out.path))
            sleep 1
            """, directory: FileManager.default.temporaryDirectory)
        #expect(session.state == .running)
        try await waitUntil("the process exits") { session.state == .exited }
        #expect(runs() == 1)

        let stage = Stage(width: 900, height: 360, dark: true)
        stage.show(SessionTerminalView(session: session))
        try await Task.sleep(for: .milliseconds(500))
        try stage.snapshot("terminal-exited-dark", terminal: session.terminalView)

        let old = session.terminalView
        session.restart()
        #expect(session.state == .running)
        #expect(session.terminalView !== old)
        try await waitUntil("the new terminal is on stage") { session.terminalView.window === stage.window }
        try await waitUntil("the restarted process exits") { session.state == .exited }
        #expect(runs() == 2)

        // A session whose close failed is terminated but still listed, so it must restart.
        session.terminate()
        session.restart()
        try await waitUntil("the terminated session runs again") { runs() == 3 }
        session.terminate()
        session.deleteScript()
    }
}

@MainActor
@Suite(.enabled(if: liveDirectory != nil), .serialized)
struct SnapshotTests {
    func settings() throws -> SessionSettings {
        let defaults = try #require(UserDefaults(suiteName: "hermes-sessions-snapshots"))
        defaults.removePersistentDomain(forName: "hermes-sessions-snapshots")
        let settings = SessionSettings(defaults: defaults)
        settings.cloudEnvironments = [
            CloudEnvironment(id: "ccpool_01HZX4T9QK", name: "Build farm"),
            CloudEnvironment(id: "ccpool_01J7M2PV8R", name: "GPU pool"),
        ]
        return settings
    }

    @Test(arguments: [false, true])
    func settingsView(dark: Bool) async throws {
        let stage = Stage(width: 560, height: 520, dark: dark)
        stage.show(SessionSettingsView(settings: try settings()))
        try await Task.sleep(for: .milliseconds(400))
        try stage.snapshot("settings-\(dark ? "dark" : "light")")
    }

    /// Uses the checkout of Hermes itself, which is under ~/Projects. Planning only reads it.
    @Test(arguments: [("new-light", "retry-budgets", false, false), ("new-dark", "retry-budgets", true, false),
                      ("main-copy", "main", false, false), ("cloud", "retry-budgets", false, true)])
    func launchSheetForAPullRequest(name: String, branch: String, dark: Bool, cloud: Bool) async throws {
        let origin = SessionOrigin.pullRequest(
            repository: RepositoryRef(owner: "bojanrajkovic", name: "hermes"), number: 94,
            title: "Add retry budgets to the upstream client", headRefName: branch, baseRefName: "main",
            url: URL(string: "https://github.com/bojanrajkovic/hermes/pull/94")!
        )
        let model = SessionLaunchModel(origin: origin, store: SessionStore(settings: try settings()))
        if cloud { model.environmentChoice = .cloud("ccpool_01HZX4T9QK") }
        let stage = Stage(width: 560, height: 760, dark: dark)
        stage.show(SessionLaunchSheet(model: model) { _ in })
        // The checkout search runs git in every repository under ~/Projects.
        try await waitUntil("the checkout search ends", timeout: .seconds(60)) { model.workspace != .searching }
        try await Task.sleep(for: .milliseconds(500))
        try stage.snapshot("launch-pr-\(name)")
    }

    @Test func launchSheetWithoutACheckout() async throws {
        let settings = try settings()
        settings.searchRoots = []
        let origin = SessionOrigin.issue(
            repository: RepositoryRef(owner: "hermes-test", name: "not-cloned-anywhere"), number: 51,
            title: "Weight description uses the wrong locale in Swift",
            url: URL(string: "https://github.com/hermes-test/not-cloned-anywhere/issues/51")!
        )
        let stage = Stage(width: 560, height: 720)
        stage.show(SessionLaunchSheet(origin: origin, store: SessionStore(settings: settings)) { _ in })
        try await Task.sleep(for: .seconds(2))
        try stage.snapshot("launch-issue-no-checkout")
    }
}

@MainActor
@Suite(.enabled(if: liveClaude), .serialized)
struct LiveClaudeTests {
    /// Clones the playground into a scratch root and returns settings that search it.
    func playground() async throws -> (settings: SessionSettings, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "hermes-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gh = try #require(await Shell.find("gh"))
        let clone = try await Shell.run(gh, ["repo", "clone", "bojanrajkovic/hermes-playground", root.appending(path: "hermes-playground").path])
        try #require(clone.status == 0, "\(clone.stderr)")

        let defaults = try #require(UserDefaults(suiteName: "hermes-sessions-live"))
        defaults.removePersistentDomain(forName: "hermes-sessions-live")
        let settings = SessionSettings(defaults: defaults)
        settings.searchRoots = [root]
        return (settings, root)
    }

    let playgroundRepository = RepositoryRef(owner: "bojanrajkovic", name: "hermes-playground")

    /// The whole local path: find the checkout, make the worktree, start
    /// `claude` in it with Remote Control, see its TUI, close, remove.
    @Test func pullRequestSessionRunsClaudeInAWorktree() async throws {
        let (settings, root) = try await playground()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(settings: settings)
        let origin = SessionOrigin.pullRequest(
            repository: playgroundRepository, number: 2, title: "Price quotes by destination zone",
            headRefName: "feature/zone-pricing", baseRefName: "main",
            url: URL(string: "https://github.com/bojanrajkovic/hermes-playground/pull/2")!
        )

        // No prompt: the session must not start working on the pull request.
        let session = try await store.launch(origin, environment: .local(remoteControl: true), name: "hermes-live-test", prompt: "")
        let worktree = try #require(session.workingDirectory)
        // A failed run must not leave the worktree behind for the next one.
        defer { try? FileManager.default.removeItem(at: worktree) }
        #expect(worktree.path.hasSuffix("worktrees/bojanrajkovic/hermes-playground/feature-zone-pricing"))
        #expect(session.branch == "feature/zone-pricing")
        #expect(session.baseRef == "origin/main")
        #expect(try await WorkingTree(directory: worktree).head().branch == "feature/zone-pricing")
        #expect(store.sessions(for: origin).map(\.id) == [session.id])
        #expect(store.session(onBranch: "feature/zone-pricing", in: playgroundRepository) === session)
        // The main working copy is still on its own branch.
        #expect(try await WorkingTree(directory: root.appending(path: "hermes-playground")).head().branch == "main")

        let stage = Stage(width: 1000, height: 640, dark: true)
        stage.show(SessionTerminalView(session: session))
        try await waitUntil("claude draws", timeout: .seconds(40)) { !screenText(of: session).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        try await Task.sleep(for: .seconds(4))
        // A new folder asks for trust first, with "No, exit" selected.
        // Choose "Yes", so the session itself and Remote Control start.
        if screenText(of: session).contains("Yes, I trust this folder") {
            try stage.snapshot("claude-trust-dark", terminal: session.terminalView)
            session.terminalState.sendKey(.arrowDown)
            try await Task.sleep(for: .milliseconds(300))
            session.terminalState.sendKey(.enter)
            try await Task.sleep(for: .seconds(12))
        }
        let text = screenText(of: session)
        print("--- claude screen ---\n\(text)\n--- title: \(session.terminalTitle) ---")
        try stage.snapshot("claude-running-dark", terminal: session.terminalView)
        #expect(session.state == .running)
        let pid = try #require(session.foregroundPid)
        #expect(isAlive(pid))

        // An untracked file is uncommitted work: plain removal must refuse.
        try Data("scratch".utf8).write(to: worktree.appending(path: "hermes-live-untracked.txt"))
        #expect(store.canRemoveWorktree(of: session))
        await #expect(throws: SessionCloseError.self) { try await store.close(session, worktree: .remove) }
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(store.sessions.count == 1)
        try await waitUntil("claude is gone") { !isAlive(pid) }

        try await store.close(session, worktree: .removeDiscardingChanges)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(store.sessions.isEmpty)
    }

    /// An issue session gets a new branch off the default branch, and a
    /// second launch reuses the worktree.
    @Test func issueSessionGetsANewBranchAndReusesItsWorktree() async throws {
        let (settings, root) = try await playground()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(settings: settings)
        let origin = SessionOrigin.issue(
            repository: playgroundRepository, number: 50, title: "Add a changelog",
            url: URL(string: "https://github.com/bojanrajkovic/hermes-playground/issues/50")!
        )

        let first = try await store.launch(origin, environment: .local(remoteControl: false), prompt: "")
        #expect(first.branch == "issue-50-add-a-changelog")
        #expect(first.baseRef == "origin/main")
        let worktree = try #require(first.workingDirectory)
        #expect(try await WorkingTree(directory: worktree).head().branch == "issue-50-add-a-changelog")

        let second = try await store.launch(origin, environment: .local(remoteControl: false), prompt: "")
        #expect(second.workingDirectory == worktree)
        #expect(!store.canRemoveWorktree(of: first), "another session shares the worktree")

        try await store.close(second)
        try await store.close(first, worktree: .remove)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))

        // The branch outlives the worktree; a later session picks it up again.
        let third = try await store.launch(origin, environment: .local(remoteControl: false), prompt: "")
        #expect(third.workingDirectory == worktree)
        try await store.close(third, worktree: .remove)
    }

    /// Clones into the real Application Support folder, so it only runs when
    /// no clone is there, and removes what it made.
    @Test func cloneLandsWhereTheFinderLooks() async throws {
        let repo = RepoID(owner: "bojanrajkovic", name: "hermes-playground")
        let destination = Workspace.cloneDestination(for: repo)
        try #require(!FileManager.default.fileExists(atPath: destination.path), "a clone already exists at \(destination.path)")
        defer { try? FileManager.default.removeItem(at: destination) }

        let defaults = try #require(UserDefaults(suiteName: "hermes-sessions-live"))
        defaults.removePersistentDomain(forName: "hermes-sessions-live")
        let settings = SessionSettings(defaults: defaults)
        settings.searchRoots = []
        let store = SessionStore(settings: settings)
        let origin = SessionOrigin.issue(
            repository: playgroundRepository, number: 50, title: "Add a changelog",
            url: URL(string: "https://github.com/bojanrajkovic/hermes-playground/issues/50")!
        )

        await #expect(throws: WorkspaceError.noCheckout(repo)) { try await store.plan(for: origin) }
        try await store.clone(for: origin)
        let plan = try await store.plan(for: origin)
        #expect(plan.checkout.directory.standardizedFileURL.path == destination.standardizedFileURL.path)
        #expect(!plan.exists)
    }

    @Test func forkBranchFailsWithAReadableError() async throws {
        let (settings, root) = try await playground()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = SessionOrigin.pullRequest(
            repository: playgroundRepository, number: 9999, title: "From a fork", headRefName: "someone/not-on-origin", baseRefName: "main",
            url: URL(string: "https://github.com/bojanrajkovic/hermes-playground/pull/9999")!
        )
        await #expect(throws: WorkspaceError.branchNotOnRemote(branch: "someone/not-on-origin", remote: "origin")) {
            try await SessionStore(settings: settings).launch(origin, environment: .local(remoteControl: false), prompt: "")
        }
    }
}

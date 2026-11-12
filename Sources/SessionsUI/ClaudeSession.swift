import AppKit
import GhosttyTerminal
import Observation
import os
import RepoKit

/// One Claude Code session: `claude` in an embedded terminal, or a session
/// handed to the Claude desktop app.
///
/// A terminal session owns its terminal view, so the process keeps running
/// while no SwiftUI view shows it. A session does not survive quitting the app.
@Observable
@MainActor
public final class ClaudeSession: Identifiable {
    public enum State: Hashable, Sendable {
        case running, exited
        /// Handed to the Claude desktop app. Hermes runs nothing for it, so it never counts as running.
        case inClaudeApp

        public var label: String {
            switch self {
            case .running: "Running"
            case .exited: "Exited"
            case .inClaudeApp: "In Claude App"
            }
        }

        /// An SF Symbol name for the state.
        public var symbol: String {
            switch self {
            case .running: "play.circle.fill"
            case .exited: "stop.circle"
            case .inClaudeApp: "arrow.up.forward.app"
            }
        }
    }

    /// How the session runs.
    enum Runner {
        case terminal(SessionTerminal)
        /// Opened in the Claude desktop app with this link.
        case claudeApp(URL)
    }

    public nonisolated let id = UUID()
    public let origin: SessionOrigin
    public let title: String
    public let environment: SessionEnvironment
    /// The worktree the session runs in. Nil for a cloud session.
    public let workingDirectory: URL?
    /// The branch the session works on, used to find the PR it opens.
    public let branch: String?
    /// The ref the session's local diff is compared with.
    public let baseRef: String?
    /// The command the session runs, as a line the user can paste into a shell.
    public let commandLine: String
    public private(set) var state: State
    let runner: Runner

    @ObservationIgnored weak var store: SessionStore?
    @ObservationIgnored let checkout: Checkout?

    /// The terminal, for a session that runs in one.
    var terminal: SessionTerminal? {
        if case .terminal(let terminal) = runner { terminal } else { nil }
    }

    /// The title the running program set on the terminal.
    var terminalTitle: String? { terminal?.state.title }
    /// The process ID of the program in the foreground of the terminal.
    var foregroundPid: pid_t? { terminal?.view.foregroundPid }

    /// - Parameters:
    ///   - script: A shell script that runs the session's command in a terminal,
    ///     or nil for a session opened in the Claude app with `claudeAppURL`.
    ///   - processDirectory: The directory the script starts in.
    init(
        origin: SessionOrigin,
        title: String,
        environment: SessionEnvironment,
        workingDirectory: URL?,
        branch: String?,
        baseRef: String?,
        commandLine: String,
        runner: Runner,
        checkout: Checkout?
    ) {
        self.origin = origin
        self.title = title
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.branch = branch
        self.baseRef = baseRef
        self.commandLine = commandLine
        self.runner = runner
        self.checkout = checkout
        state = if case .claudeApp = runner { .inClaudeApp } else { .running }
        terminal?.onExit = { [weak self] in self?.state = .exited }
    }

    /// Ends the current process, if any, and runs the command again in a fresh
    /// terminal. Opens the Claude app again for a session that runs there.
    public func restart() {
        switch runner {
        case .terminal(let terminal):
            terminal.restart()
            state = .running
        case .claudeApp(let url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Ends the process. A terminal session can still be restarted.
    func terminate() {
        guard let terminal else { return }
        terminal.tearDown()
        state = .exited
    }

    /// Deletes the launch script. The session cannot be restarted afterwards.
    func deleteScript() {
        terminal?.deleteScript()
    }
}

/// The embedded terminal of a session and the launch script it runs.
///
/// The session ends when the script's process exits. Hermes watches that
/// process itself: libghostty's close report did not always arrive for a
/// terminal parked offscreen, which left sessions marked running.
@Observable
@MainActor
final class SessionTerminal {
    /// The view showing the terminal. `restart()` replaces it.
    private(set) var view: TerminalView
    @ObservationIgnored private(set) var state: TerminalViewState
    /// Called once when the script's process exits or the terminal closes.
    @ObservationIgnored var onExit: (() -> Void)?
    @ObservationIgnored private let script: URL
    @ObservationIgnored private let pidFile: URL
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var watcher: Task<Void, Never>?

    /// - Parameters:
    ///   - script: The shell script that runs the session's command, without its `#!` line.
    ///   - id: Names the script file.
    ///   - directory: The directory the script starts in.
    init(script body: String, id: UUID, directory: URL?) throws {
        // A script file rather than the command itself: the terminal's
        // `command` setting is one config line, and a prompt can span several.
        script = FileManager.default.temporaryDirectory.appending(path: "hermes-session-\(id.uuidString).sh")
        pidFile = script.appendingPathExtension("pid")
        self.directory = directory
        // The script records its process ID first, so Hermes can see it exit.
        let recorded = "#!/bin/sh\necho $$ > \(shellQuoted(pidFile.path))\n" + body
        try Data(recorded.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        (view, state) = Self.makeTerminal(script: script, directory: directory)
        watch()
    }

    func restart() {
        tearDown()
        (view, state) = Self.makeTerminal(script: script, directory: directory)
        watch()
    }

    func tearDown() {
        watcher?.cancel()
        state.onClose = nil
        // Dropping the controller frees the surface, which hangs up the pty.
        view.controller = nil
        view.removeFromSuperview()
    }

    func deleteScript() {
        try? FileManager.default.removeItem(at: script)
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Reports the exit once, from whichever comes first: the terminal's close
    /// report, or the script's process ending.
    private func watch() {
        try? FileManager.default.removeItem(at: pidFile)
        state.onClose = { [weak self] _ in self?.exited() }
        let pidFile = pidFile
        watcher = Task { [weak self] in
            guard let pid = await Self.recordedPID(in: pidFile) else { return }
            await Self.waitForExit(of: pid)
            guard !Task.isCancelled else { return }
            self?.exited()
        }
    }

    private func exited() {
        watcher?.cancel()
        state.onClose = nil
        onExit?()
    }

    /// The process ID the script wrote, once it has. Nil if it never does within 10 seconds.
    private nonisolated static func recordedPID(in file: URL) async -> pid_t? {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Returns when the process exits, or at once if it already has.
    private nonisolated static func waitForExit(of pid: pid_t) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish = {
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                source.cancel()
                continuation.resume()
            }
            source.setEventHandler(handler: finish)
            source.resume()
            // A process that exited before the source started sends no event.
            if kill(pid, 0) != 0 { finish() }
        }
    }

    private static func makeTerminal(script: URL, directory: URL?) -> (TerminalView, TerminalViewState) {
        // The command goes in the controller's config. As a surface option,
        // libghostty keeps the surface open after exit until a key is pressed.
        let controller = TerminalController {
            $0.withCustom("command", script.path)
            // Ghostty treats Option as Alt on US layouts by default, so Option-Shift-Hyphen typed no em dash.
            $0.withCustom("macos-option-as-alt", "false")
        }
        let state = TerminalViewState(controller: controller)
        let view = TerminalView(frame: TerminalParking.frame)
        view.delegate = state
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: directory?.path)
        // The surface, and with it the process, is created once the view is in a window.
        TerminalParking.park(view)
        return (view, state)
    }
}

/// An offscreen window that holds terminal views no SwiftUI view is showing.
///
/// libghostty only creates a surface for a view that is in a window, and only
/// drains a surface's output while it stays in one. A detached view's process
/// would block on its next write.
@MainActor
enum TerminalParking {
    static let frame = NSRect(x: 0, y: 0, width: 900, height: 600)

    private static let window: NSWindow = {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }()

    /// Moves `view` offscreen at its current size and stops it drawing.
    static func park(_ view: TerminalView) {
        view.autoresizingMask = []
        window.contentView?.addSubview(view)
        view.setSurfaceVisible(false)
    }
}

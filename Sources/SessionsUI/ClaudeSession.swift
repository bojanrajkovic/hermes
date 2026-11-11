import AppKit
import GhosttyTerminal
import Observation
import RepoKit

/// One Claude Code session running in an embedded terminal.
///
/// The session owns its terminal view, so the process keeps running while no
/// SwiftUI view shows it. A session does not survive quitting the app.
@Observable
@MainActor
public final class ClaudeSession: Identifiable {
    public enum State: Hashable, Sendable { case running, exited }

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
    public private(set) var state: State = .running

    /// The view showing the terminal. `restart()` replaces it.
    private(set) var terminalView: TerminalView
    @ObservationIgnored private(set) var terminalState: TerminalViewState
    @ObservationIgnored weak var store: SessionStore?
    @ObservationIgnored let checkout: Checkout?
    @ObservationIgnored private let script: URL
    @ObservationIgnored private let processDirectory: URL?

    /// The title the running program set on the terminal.
    var terminalTitle: String { terminalState.title }
    /// The process ID of the program in the foreground of the terminal.
    var foregroundPid: pid_t? { terminalView.foregroundPid }

    /// - Parameters:
    ///   - script: A shell script that runs the session's command. It is
    ///     written to a temporary file and run by the terminal.
    ///   - processDirectory: The directory the script starts in.
    init(
        origin: SessionOrigin,
        title: String,
        environment: SessionEnvironment,
        workingDirectory: URL?,
        branch: String?,
        baseRef: String?,
        commandLine: String,
        script: String,
        processDirectory: URL?,
        checkout: Checkout?
    ) throws {
        self.origin = origin
        self.title = title
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.branch = branch
        self.baseRef = baseRef
        self.commandLine = commandLine
        self.processDirectory = processDirectory
        self.checkout = checkout

        // A script file rather than the command itself: the terminal's
        // `command` setting is one config line, and a prompt can span several.
        self.script = FileManager.default.temporaryDirectory.appending(path: "hermes-session-\(id.uuidString).sh")
        try Data(script.utf8).write(to: self.script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.script.path)

        (terminalView, terminalState) = Self.makeTerminal(script: self.script, directory: processDirectory)
        observeExit()
    }

    /// Ends the current process, if any, and runs the command again in a fresh terminal.
    public func restart() {
        tearDownTerminal()
        (terminalView, terminalState) = Self.makeTerminal(script: script, directory: processDirectory)
        state = .running
        observeExit()
    }

    /// Ends the process. The session can still be restarted.
    func terminate() {
        tearDownTerminal()
        state = .exited
    }

    /// Deletes the launch script. The session cannot be restarted afterwards.
    func deleteScript() {
        try? FileManager.default.removeItem(at: script)
    }

    private func tearDownTerminal() {
        terminalState.onClose = nil
        // Dropping the controller frees the surface, which hangs up the pty.
        terminalView.controller = nil
        terminalView.removeFromSuperview()
    }

    private func observeExit() {
        terminalState.onClose = { [weak self] _ in self?.state = .exited }
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

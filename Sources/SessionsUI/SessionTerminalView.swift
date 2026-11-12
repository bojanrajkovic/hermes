import AppKit
import GhosttyTerminal
import HermesUI
import SwiftUI

/// The terminal of one session, under a header with its origin, environment,
/// branch, and state.
public struct SessionTerminalView: View {
    private let session: ClaudeSession

    @State private var isConfirmingClose = false
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingRestart = false
    @State private var closeError: String?
    @State private var copied = false

    public init(session: ClaudeSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let terminal = session.terminal {
                TerminalHost(terminal: terminal.view)
                    .accessibilityLabel("Terminal for \(session.title)")
                if session.state == .exited {
                    Divider()
                    exitedBar
                }
            } else {
                Divider()
                claudeAppBar
            }
        }
        .confirmationDialog("Close “\(session.title)”?", isPresented: $isConfirmingClose) {
            if session.store?.canRemoveWorktree(of: session) == true {
                Button("Close and Keep Worktree") { close(.keep) }
                Button("Close and Remove Worktree") { close(.remove) }
            } else {
                Button("Close Session") { close(.keep) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(closeMessage)
        }
        .confirmationDialog("Restart “\(session.title)”?", isPresented: $isConfirmingRestart) {
            Button("Restart") { session.restart() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends the running Claude Code process and runs the command again, as a new conversation.")
        }
        .alert("The worktree has uncommitted changes", isPresented: $isConfirmingDiscard) {
            Button("Delete Changes and Remove", role: .destructive) { close(.removeDiscardingChanges) }
            Button("Keep Worktree", role: .cancel) { close(.keep) }
        } message: {
            Text("Removing \(session.workingDirectory?.abbreviatedPath ?? "the worktree") deletes its uncommitted and untracked files. This can't be undone.")
        }
        .alert("The session couldn't be closed", isPresented: Binding(get: { closeError != nil }, set: { if !$0 { closeError = nil } })) {
            Button("OK") {}
        } message: {
            Text(closeError ?? "")
        }
    }

    private var closeMessage: String {
        let process = session.state == .running ? "This ends the running Claude Code process. " : ""
        guard let directory = session.workingDirectory else { return process }
        return process + "The worktree is at \(directory.abbreviatedPath). Its branch is kept either way."
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: session.origin.symbolName)
                .foregroundStyle(.secondary)
                .accessibilityLabel(session.origin.kindLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 10) {
                    Text("\(session.origin.repository.description)#\(session.origin.number)")
                    environmentLabel
                    if let branch = session.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .help("Branch \(branch)")
                    }
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            SessionStateBadge(state: session.state)
            actions
        }
        .padding(.horizontal, SessionMetrics.barPaddingHorizontal)
        .padding(.vertical, SessionMetrics.barPaddingVertical)
        .background(.bar)
    }

    @ViewBuilder private var environmentLabel: some View {
        switch session.environment {
        case let .local(remoteControl):
            Label(remoteControl ? "This Mac · Remote Control" : "This Mac", systemImage: "laptopcomputer")
        case let .cloud(environment):
            Label(environment.name, systemImage: "cloud")
                .help(environment.id)
        }
    }

    private var actions: some View {
        ControlGroup {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.commandLine, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label("Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy the command this session runs")

            if let directory = session.workingDirectory {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                } label: {
                    Label("Reveal Worktree in Finder", systemImage: "folder")
                }
                .help("Reveal the worktree in Finder")
            }

            if session.terminal != nil {
                Button {
                    if session.state == .running { isConfirmingRestart = true } else { session.restart() }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .help("End the process and run the command again")
            }

            Button {
                isConfirmingClose = true
            } label: {
                Label("Close Session", systemImage: "xmark")
            }
            .help("Close the session")
            .disabled(session.store == nil)
        }
        .labelStyle(.iconOnly)
        .fixedSize()
    }

    /// In place of the terminal for a session opened in the Claude app.
    private var claudeAppBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Opened in the Claude app. Hermes shows the worktree's diff.")
            Spacer(minLength: 8)
            Button("Open in Claude App") { session.restart() }
        }
        .padding(.horizontal, SessionMetrics.barPaddingHorizontal)
        .padding(.vertical, SessionMetrics.barPaddingVertical)
        .background(.bar)
    }

    private var exitedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("The process exited.")
            Spacer(minLength: 8)
            Button("Restart") { session.restart() }
        }
        .padding(.horizontal, SessionMetrics.barPaddingHorizontal)
        .padding(.vertical, SessionMetrics.barPaddingVertical)
        .background(.bar)
    }

    private func close(_ worktree: WorktreeDisposition) {
        guard let store = session.store else { return }
        Task {
            do {
                try await store.close(session, worktree: worktree)
            } catch SessionCloseError.uncommittedChanges {
                isConfirmingDiscard = true
            } catch {
                closeError = error.localizedDescription
            }
        }
    }
}

/// Running or exited, as a symbol and a word.
struct SessionStateBadge: View {
    let state: ClaudeSession.State

    var body: some View {
        Label {
            Text(state.label)
        } icon: {
            Image(systemName: state == .running ? "circle.fill" : state.symbol)
                .foregroundStyle(state == .running ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .imageScale(.small)
        }
        .font(Theme.Fonts.badge)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.badgePaddingHorizontal)
        .padding(.vertical, Theme.badgePaddingVertical)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.badgeCornerRadius))
        .fixedSize()
    }
}

/// Shows a session's terminal view. The view belongs to the session: this
/// host borrows it while on screen and parks it offscreen when it goes away,
/// so the process and scrollback outlive the SwiftUI view.
struct TerminalHost: NSViewRepresentable {
    let terminal: TerminalView

    func makeNSView(context _: Context) -> Container {
        let container = Container()
        container.show(terminal)
        return container
    }

    func updateNSView(_ container: Container, context _: Context) {
        container.show(terminal)
    }

    static func dismantleNSView(_ container: Container, coordinator _: ()) {
        container.parkTerminals()
    }

    final class Container: NSView {
        func show(_ terminal: TerminalView) {
            guard terminal.superview !== self else { return }
            parkTerminals()
            terminal.frame = bounds
            terminal.autoresizingMask = [.width, .height]
            addSubview(terminal)
            terminal.setSurfaceVisible(true)
            // Hop the run loop: this runs inside a SwiftUI update, where the
            // first responder must not change.
            DispatchQueue.main.async { [weak terminal] in
                guard let terminal, let window = terminal.window else { return }
                window.makeFirstResponder(terminal)
            }
        }

        /// Parks terminals this container still shows. One that already
        /// moved to another container, or was torn down, is left alone.
        func parkTerminals() {
            for case let terminal as TerminalView in subviews {
                if terminal.controller == nil { terminal.removeFromSuperview() } else { TerminalParking.park(terminal) }
            }
        }
    }
}

import AppKit
import HermesUI
import SwiftUI

/// Where a session runs: this Mac, with or without Remote Control, or a cloud environment.
public struct SessionEnvironmentLabel: View {
    private let environment: SessionEnvironment

    public init(_ environment: SessionEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        switch environment {
        case let .local(remoteControl):
            Label(remoteControl ? "This Mac · Remote Control" : "This Mac", systemImage: "laptopcomputer")
        case let .cloud(environment):
            Label(environment.name, systemImage: "cloud")
                .help(environment.id)
        }
    }
}

/// A session's buttons: copy its command, reveal its worktree, restart it or
/// open it in the Claude app, and close it. Owns the dialogs those buttons raise.
public struct SessionActions: View {
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
            } else {
                Button {
                    session.restart()
                } label: {
                    Label("Open in Claude App", systemImage: "arrow.up.forward.app")
                }
                .help("Open the session in the Claude app")
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

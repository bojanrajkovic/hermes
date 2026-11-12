import AppKit
import SwiftUI

struct RootView: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        Group {
            switch model.startup {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Signing in with the GitHub CLI…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let problem):
                StartupProblemView(problem: problem) { Task { await model.start() } }
            case .ready(let viewer):
                MainView()
                    .sheet(isPresented: Binding(get: { !model.store.hasFinishedSetup }, set: { _ in })) {
                        SetupSheet(viewer: viewer) { model.store.hasFinishedSetup = true }
                            .interactiveDismissDisabled()
                    }
            }
        }
        // Signs in once for the app. Each window then picks its account and loads it.
        .task { await model.start() }
    }
}

/// Explains why the app cannot reach GitHub and what to run to fix it.
struct StartupProblemView: View {
    let problem: StartupProblem
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(explanation)
        } actions: {
            VStack(spacing: 12) {
                ForEach(commands, id: \.self) { CommandLine(command: $0) }
                Button("Try Again", action: retry)
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
            }
        }
    }

    private var title: String {
        switch problem {
        case .ghNotInstalled: "GitHub CLI Not Found"
        case .ghNotLoggedIn: "Not Logged In to GitHub"
        case .other: "Could Not Reach GitHub"
        }
    }

    private var symbol: String {
        switch problem {
        case .ghNotInstalled: "terminal"
        case .ghNotLoggedIn: "person.crop.circle.badge.exclamationmark"
        case .other: "wifi.exclamationmark"
        }
    }

    private var explanation: String {
        switch problem {
        case .ghNotInstalled:
            "Hermes signs in with the GitHub CLI. Install it and log in from Terminal, then try again."
        case .ghNotLoggedIn(let message):
            "Hermes reads your token from the GitHub CLI. Log in from Terminal, then try again."
                + (message.isEmpty ? "" : "\n\ngh said: \(message)")
        case .other(let message):
            message
        }
    }

    private var commands: [String] {
        switch problem {
        case .ghNotInstalled: ["brew install gh", "gh auth login"]
        case .ghNotLoggedIn: ["gh auth login"]
        case .other: []
        }
    }
}

/// A shell command with a button that copies it.
private struct CommandLine: View {
    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy the command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

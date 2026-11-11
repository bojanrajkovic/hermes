import AppKit
import HermesUI
import SwiftUI

enum SessionMetrics {
    static let sheetWidth: CGFloat = 560
    static let promptMinHeight: CGFloat = 84
    static let commandMaxHeight: CGFloat = 96
    static let barPaddingHorizontal: CGFloat = 12
    static let barPaddingVertical: CGFloat = 8
    static let codeCornerRadius: CGFloat = 6
}

/// The launch sheet's state: the choices, and where the session would run.
@Observable
@MainActor
final class SessionLaunchModel {
    enum WorkspaceStatus: Equatable {
        case searching
        case ready(WorkspacePlan)
        case noCheckout
        case failed(String)
    }

    enum EnvironmentChoice: Hashable {
        case local
        case cloud(String)
        case manage
    }

    let origin: SessionOrigin
    let store: SessionStore

    var environmentChoice: EnvironmentChoice = .local
    var remoteControl = true
    var permissionMode: PermissionMode = .default
    var name: String
    var prompt: String

    private(set) var workspace: WorkspaceStatus = .searching
    private(set) var cloudDirectory: URL?
    private(set) var isWorking = false
    private(set) var isCloning = false
    private(set) var copied = false
    var error: String?

    init(origin: SessionOrigin, store: SessionStore) {
        self.origin = origin
        self.store = store
        name = origin.defaultSessionName
        prompt = origin.defaultPrompt
    }

    var environment: SessionEnvironment {
        if case let .cloud(id) = environmentChoice, let saved = store.settings.cloudEnvironments.first(where: { $0.id == id }) {
            return .cloud(saved)
        }
        return .local(remoteControl: remoteControl)
    }

    var isLocal: Bool {
        if case .local = environment { true } else { false }
    }

    /// The directory the command will `cd` to. For a local session without a
    /// checkout yet, this is where the worktree lands after cloning.
    var directory: URL? {
        guard isLocal else { return cloudDirectory }
        if case let .ready(plan) = workspace { return plan.directory }
        return Workspace.worktreeDirectory(repo: origin.repoID, branch: origin.branchName)
    }

    var configuration: LaunchConfiguration {
        LaunchConfiguration(environment: environment, permissionMode: permissionMode, name: name, prompt: prompt, directory: directory)
    }

    var canLaunch: Bool {
        guard !isWorking, !isCloning, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !isLocal { return true }
        if case .ready = workspace { return true }
        return false
    }

    func loadWorkspace() async {
        workspace = .searching
        cloudDirectory = await store.cloudDirectory(for: origin)
        do {
            workspace = .ready(try await store.plan(for: origin))
        } catch WorkspaceError.noCheckout {
            workspace = .noCheckout
        } catch {
            workspace = .failed(error.localizedDescription)
        }
    }

    func clone() async {
        isCloning = true
        error = nil
        defer { isCloning = false }
        do {
            try await store.clone(for: origin)
            await loadWorkspace()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// - Parameter inClaudeApp: Open the Claude desktop app on this session's folder and prompt,
    ///   in place of running `claude` in the embedded terminal.
    func launch(inClaudeApp: Bool = false) async -> ClaudeSession? {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            return try await store.launch(
                origin, environment: environment, permissionMode: permissionMode, name: name, prompt: prompt, inClaudeApp: inClaudeApp
            )
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Copies the command. For a local session the worktree is made first, so
    /// the copied `cd` works in the user's own terminal.
    func copyCommand() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            if isLocal, case let .ready(plan) = workspace, !plan.exists {
                _ = try await Workspace.create(plan, origin: origin)
                await loadWorkspace()
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(configuration.commandLine(), forType: .string)
            copied = true
            // Not awaited: the sheet must not stay busy while the checkmark shows.
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A sheet that picks the environment and starts a session for `origin`.
public struct SessionLaunchSheet: View {
    @State private var model: SessionLaunchModel
    private let onLaunch: (ClaudeSession) -> Void
    @State private var launchTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    public init(origin: SessionOrigin, store: SessionStore, onLaunch: @escaping (ClaudeSession) -> Void) {
        self.init(model: SessionLaunchModel(origin: origin, store: store), onLaunch: onLaunch)
    }

    init(model: SessionLaunchModel, onLaunch: @escaping (ClaudeSession) -> Void) {
        _model = State(initialValue: model)
        self.onLaunch = onLaunch
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    environmentPicker
                    if model.isLocal {
                        Toggle(isOn: $model.remoteControl) {
                            Text("Remote Control")
                            Text("Reach the session from claude.ai and the Claude mobile app.")
                        }
                        Picker("Permission mode", selection: $model.permissionMode) {
                            ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    TextField("Session name", text: $model.name)
                }
                Section("Prompt") {
                    TextEditor(text: $model.prompt)
                        .font(Theme.Fonts.body)
                        .frame(minHeight: SessionMetrics.promptMinHeight)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Initial prompt")
                }
                if model.isLocal {
                    Section("Working directory") { workspaceRow }
                }
                Section("Command") { commandRow }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .frame(width: SessionMetrics.sheetWidth)
        // Runs again when the folders change in Settings while the sheet is open.
        .task(id: model.store.settings.searchRoots) { await model.loadWorkspace() }
        // Cancel, Esc, or any other way out stops a launch still preparing its worktree.
        .onDisappear { launchTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Start a Claude Code Session")
                    .font(.headline)
                Label {
                    Text("\(model.origin.reference) · \(model.origin.title)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: model.origin.symbolName)
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(model.origin.kindLabel) \(model.origin.reference), \(model.origin.title)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var environmentPicker: some View {
        Picker("Environment", selection: Binding(
            // A cloud environment removed in Settings falls back to This Mac.
            get: { model.isLocal ? .local : model.environmentChoice },
            set: { choice in
                // "Manage…" is an action, not a choice: the selection stays put.
                if choice == .manage { openSettings() } else { model.environmentChoice = choice }
            }
        )) {
            Label("This Mac", systemImage: "laptopcomputer").tag(SessionLaunchModel.EnvironmentChoice.local)
            ForEach(model.store.settings.cloudEnvironments) { environment in
                Label(environment.name, systemImage: "cloud").tag(SessionLaunchModel.EnvironmentChoice.cloud(environment.id))
            }
            Divider()
            Text("Manage…").tag(SessionLaunchModel.EnvironmentChoice.manage)
        }
    }

    @ViewBuilder private var workspaceRow: some View {
        switch model.workspace {
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for a checkout of \(model.origin.repository.description)…")
                    .foregroundStyle(.secondary)
            }
        case let .ready(plan):
            LabeledContent {
                Text(plan.exists ? "Existing worktree" : "New worktree")
                    .foregroundStyle(.secondary)
            } label: {
                Label(plan.branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Worktree of \(plan.checkout.directory.abbreviatedPath)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .noCheckout:
            LabeledContent {
                Button("Clone") { Task { await model.clone() } }
                    .disabled(model.isCloning)
            } label: {
                Label("No checkout of \(model.origin.repository.description) found", systemImage: "questionmark.folder")
                if model.isCloning {
                    Text("Cloning…")
                } else {
                    Text("Clone it to \(Workspace.cloneDestination(for: model.origin.repoID).abbreviatedPath)")
                        .lineLimit(2)
                }
            }
        case let .failed(message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Try Again") { Task { await model.loadWorkspace() } }
            }
        }
    }

    private var commandRow: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView {
                Text(model.configuration.commandLine())
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: SessionMetrics.commandMaxHeight)
            .accessibilityLabel("Command line")
            .accessibilityValue(model.configuration.commandLine())

            Button {
                Task { await model.copyCommand() }
            } label: {
                Label(model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(model.isWorking || (model.isLocal && !model.canLaunch))
            .help("Copy the command to run it in your own terminal")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if model.isWorking {
                ProgressView().controlSize(.small)
                Text("Preparing the worktree…")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Open in Claude") {
                launchTask = Task {
                    guard let session = await model.launch(inClaudeApp: true) else { return }
                    onLaunch(session)
                    dismiss()
                }
            }
            .disabled(!model.canLaunch)
            .help("Open the Claude app with this folder and prompt. Pick the environment there, including Remote Control.")
            Button("Start Session") {
                launchTask = Task {
                    guard let session = await model.launch() else { return }
                    onLaunch(session)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canLaunch)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

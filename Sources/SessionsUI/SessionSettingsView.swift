import HermesUI
import RepoKit
import SwiftUI

/// Settings for sessions: saved cloud environments and where checkouts live.
public struct SessionSettingsView: View {
    @Bindable private var settings: SessionSettings

    @State private var newName = ""
    @State private var newID = ""
    @State private var isChoosingFolder = false

    public init(settings: SessionSettings = .shared) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section {
                if settings.cloudEnvironments.isEmpty {
                    Text("No cloud environments saved.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.cloudEnvironments) { $environment in
                    HStack(spacing: 8) {
                        Image(systemName: "cloud")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Name", text: $environment.name)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Name of \(environment.id)")
                        Spacer(minLength: 8)
                        Text(environment.id)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        removeButton("Remove \(environment.name)") {
                            settings.cloudEnvironments.removeAll { $0.id == environment.id }
                        }
                    }
                }
                addEnvironmentRow
            } header: {
                Text("Cloud Environments")
            } footer: {
                Text("A session on a cloud environment starts with claude --environment and the saved ID.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.searchRoots.isEmpty {
                    Text("No folders. Sessions will offer to clone every repository.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.searchRoots, id: \.self) { root in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(root.abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        removeButton("Remove \(root.abbreviatedPath)") {
                            settings.searchRoots.removeAll { $0 == root }
                        }
                    }
                }
                Button("Add Folder…") { isChoosingFolder = true }
            } header: {
                Text("Checkout Folders")
            } footer: {
                Text("""
                    Local sessions run in a worktree of your own clone, found one or two levels inside these folders. \
                    Repositories found nowhere can be cloned to \(Workspace.checkoutsRoot.abbreviatedPath).
                    """)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            let folder = URL(fileURLWithPath: url.path, isDirectory: true)
            if !settings.searchRoots.contains(folder) { settings.searchRoots.append(folder) }
        }
    }

    private var addEnvironmentRow: some View {
        let id = newID.trimmingCharacters(in: .whitespaces)
        let problem = settings.problem(addingEnvironment: id, name: newName)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("New environment name", text: $newName, prompt: Text("Name"))
                TextField("New environment ID", text: $newID, prompt: Text("ccpool_… or env_…"))
                    .font(.callout.monospaced())
                Button("Add", action: add)
                    .disabled(problem != nil)
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit { if problem == nil { add() } }
            // Shown once the user has typed an ID, so an empty form isn't an error.
            Label(problem ?? "", systemImage: "exclamationmark.triangle")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .opacity(problem != nil && !id.isEmpty ? 1 : 0)
                .accessibilityHidden(problem == nil || id.isEmpty)
        }
    }

    private func add() {
        let environment = CloudEnvironment(
            id: newID.trimmingCharacters(in: .whitespaces), name: newName.trimmingCharacters(in: .whitespaces)
        )
        settings.cloudEnvironments.append(environment)
        newName = ""
        newID = ""
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

import AppKit
import DiffUI
import GitHubKit
import HermesUI
import SessionsUI
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        // A developer tool: renders the app's screens to PNG files and exits.
        if let directory = ProcessInfo.processInfo.environment["HERMES_SNAPSHOT_DIR"] {
            Snapshots.run(into: URL(fileURLWithPath: directory, isDirectory: true))
        } else {
            HermesApp.main()
        }
    }
}

/// Owns the app's state, so it can ask before a quit ends running sessions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = WindowModel()

    /// Asks before quitting while Claude sessions run: they do not survive it.
    /// Closing the window also quits the app, and comes through here too.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model.sessions.sessions.count { $0.state == .running }
        guard running > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = running == 1
            ? "Quit Hermes and end 1 running Claude session?"
            : "Quit Hermes and end \(running) running Claude sessions?"
        alert.informativeText = "Sessions do not survive quitting. Their worktrees stay on disk."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct HermesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // AppKit reads this once, before the first table exists. Without it a table averages the
        // heights of rows it has not shown, and the diff's scroll bar moves as real heights arrive.
        UserDefaults.standard.register(defaults: ["NSTableViewCanEstimateRowHeights": false])
    }

    var body: some Scene {
        let model = delegate.model
        Window("Hermes", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: Theme.windowMinWidth, minHeight: Theme.windowMinHeight)
                .onOpenURL { url in
                    guard let link = DeepLink(url: url) else {
                        model.resolveError = "Hermes can't open \(url.absoluteString)."
                        return
                    }
                    Task { await model.open(link) }
                }
        }
        // A link opens in the one window instead of a new one.
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: Theme.windowDefaultWidth, height: Theme.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            HermesCommands(model: model)
            DiffCommands()
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// The menu bar: every action in the window has an entry here with its shortcut.
struct HermesCommands: Commands {
    @Bindable var model: WindowModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Start Claude Session…") { model.launching = model.launchableOrigin }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.launchableOrigin == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(PullRequestTab.allCases) { tab in
                Button(tab.title) { model.pullRequestTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(tab.rawValue + 1)")), modifiers: .command)
                    .disabled(!model.isShowingPullRequest || (tab == .sessions && !model.openPullRequestHasSessions))
            }
            Divider()
            Toggle("Show All Bot Pull Requests", isOn: $model.showingAllBots)
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Refresh") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
        }

        CommandMenu("Go") {
            Button("Command Palette…") { model.isPaletteShown.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.viewer == nil)
            Divider()
            Button("Down the Stack") { model.moveInStack(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canMoveDownStack)
            Button("Up the Stack") { model.moveInStack(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canMoveUpStack)
            Divider()
            Button("Open on GitHub") {
                if let url = model.destinationURL { NSWorkspace.shared.open(url) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model.destinationURL == nil)
        }

        CommandMenu("Account") {
            ForEach(model.viewer?.accounts ?? []) { account in
                Toggle(
                    account.name ?? account.login,
                    isOn: Binding(get: { model.account == account }, set: { _ in model.select(account) })
                )
            }
        }
    }
}

extension WindowModel {
    var isShowingPullRequest: Bool {
        if case .pullRequest = destination { true } else { false }
    }

    var openPullRequestHasSessions: Bool {
        guard case .pullRequest(let key) = destination else { return false }
        return !sessions(startedFrom: key, isPullRequest: true).isEmpty
    }
}

struct SettingsView: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Picker("Refresh lists every", selection: $model.refreshInterval) {
                        Text("30 seconds").tag(TimeInterval(30))
                        Text("1 minute").tag(TimeInterval(60))
                        Text("2 minutes").tag(TimeInterval(120))
                        Text("5 minutes").tag(TimeInterval(300))
                    }
                    Toggle(isOn: $model.showingAllBots) {
                        Text("Show all bot pull requests")
                        Text("When off, a bot's pull request shows only if its checks fail or it has merge conflicts.")
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Sessions", systemImage: "terminal") {
                SessionSettingsView()
            }
        }
        .frame(width: 500)
        .frame(minHeight: 260)
    }
}

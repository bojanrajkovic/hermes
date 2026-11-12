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

/// Owns the app's state, so it can ask before a quit ends running sessions,
/// and sends each link to a window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()

    /// Asks before quitting while Claude sessions run: they do not survive it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = store.sessions.sessions.count { $0.state == .running }
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

    /// Closing the last window quits, as it did with one window. The quit still asks about running sessions.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A link opens in the frontmost window, or in a new one when it asks for one with `?window=new`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { store.open(url) }
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
        let store = delegate.store
        // Each window's value is what it shows. macOS saves it, so windows come back after a relaunch.
        WindowGroup("Hermes", for: WindowState.self) { $state in
            WindowRoot(store: store, state: $state)
                .frame(minWidth: Theme.windowMinWidth, minHeight: Theme.windowMinHeight)
        } defaultValue: {
            WindowState()
        }
        // Links go through the app delegate, which picks the window. Without this a window group makes a window per link.
        .handlesExternalEvents(matching: [])
        .defaultSize(width: Theme.windowDefaultWidth, height: Theme.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            HermesCommands(store: store)
            DiffCommands()
        }

        Settings {
            SettingsView().environment(store)
        }
    }
}

/// One window: its own `WindowModel`, made from the state the window was opened or restored with.
struct WindowRoot: View {
    @Binding var state: WindowState
    @State private var model: WindowModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState

    init(store: AppStore, state: Binding<WindowState>) {
        _state = state
        _model = State(initialValue: WindowModel(store: store))
    }

    var body: some View {
        RootView()
            .environment(model)
            .focusedSceneValue(model)
            .task {
                model.store.openWindow = { openWindow(value: $0) }
                model.store.frontmost = model.store.frontmost ?? model
                model.store.windowIsUp()
                if let url = state.url, let link = DeepLink(url: url) { model.pendingLink = link }
                await model.start(login: state.login)
            }
            .onChange(of: activeState, initial: true) {
                if activeState == .key { model.store.frontmost = model }
            }
            // Kept current, so a restored window shows its account and what it showed.
            .onChange(of: WindowState(id: state.id, login: model.account?.login, url: model.placeURL)) { _, new in
                state = new
            }
    }
}

/// The menu bar: every action in the window has an entry here with its shortcut.
/// Window commands act on the focused window.
struct HermesCommands: Commands {
    let store: AppStore
    @FocusedValue(WindowModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(value: WindowState(login: model?.account?.login)) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Link in New Window…") { model?.isOpenLinkShown = true }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(model?.viewer == nil)
            Divider()
            Button("Start Claude Session…") { model?.launching = model?.launchableOrigin }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model?.launchableOrigin == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(PullRequestTab.allCases) { tab in
                Button(tab.title) { model?.pullRequestTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(tab.rawValue + 1)")), modifiers: .command)
                    .disabled(model?.isShowingPullRequest != true || (tab == .sessions && model?.openPullRequestHasSessions != true))
            }
            Divider()
            Toggle("Show All Bot Pull Requests", isOn: Binding { store.showingAllBots } set: { store.showingAllBots = $0 })
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Refresh") { Task { await model?.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model == nil)
            Divider()
        }

        CommandMenu("Go") {
            Button("Command Palette…") { model?.isPaletteShown.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model?.viewer == nil)
            Divider()
            Button("Down the Stack") { model?.moveInStack(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model?.canMoveDownStack != true)
            Button("Up the Stack") { model?.moveInStack(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model?.canMoveUpStack != true)
            Divider()
            Button("Open on GitHub") {
                if let url = model?.destinationURL { NSWorkspace.shared.open(url) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model?.destinationURL == nil)
        }

        CommandMenu("Account") {
            ForEach(model?.viewer?.accounts ?? []) { account in
                Toggle(
                    account.name ?? account.login,
                    isOn: Binding(get: { model?.account == account }, set: { _ in model?.select(account) })
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
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = store
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

import GitHubKit
import RepoKit
import SwiftUI

/// What a ``DiffScreen`` shows.
public enum DiffSource: Hashable, Sendable {
    /// A pull request on GitHub. Supports review comments.
    case pullRequest(PullRequest)
    /// Uncommitted and committed work in a local worktree, compared with the
    /// merge base of `baseRef`. Reloads as files change.
    case workingTree(directory: URL, baseRef: String)
    /// One branch of a local stack, compared with its parent branch.
    /// Reloads as the branch or its parent gains commits.
    case localBranch(checkout: Checkout, branch: LocalStack.Branch)
}

/// The diff viewer for one source: a file navigator beside every changed file in one scrolling list.
///
/// The screen loads the diff when it appears and keeps it current while it is
/// on screen. It adds a layout picker to the window's toolbar. Its keyboard
/// commands come from ``DiffCommands``, which the app adds to its scene.
public struct DiffScreen: View {
    private let source: DiffSource
    private let client: GitHubClient
    private let repoCache: RepoCache
    /// Where a link asked the diff to go. The screen takes it and sets it back to `nil`.
    @Binding private var target: DeepLink.PullRequestTarget?

    @State private var model: DiffModel?
    @AppStorage(DiffDefaults.layoutKey) private var layout = DiffLayout.unified
    @AppStorage(DiffDefaults.fontSizeKey) private var fontSize = DiffDefaults.fontSize

    public init(
        source: DiffSource, client: GitHubClient, repoCache: RepoCache, target: Binding<DeepLink.PullRequestTarget?> = .constant(nil)
    ) {
        _target = target
        self.source = source
        self.client = client
        self.repoCache = repoCache
    }

    public var body: some View {
        Group {
            // A model for another source is on its way out; don't show its diff under this one's name.
            if let model, model.source.key == source.key {
                DiffContent(model: model)
            } else {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.diffMetrics, DiffMetrics(fontSize: fontSize))
        .focusedSceneValue(\.diffModel, model)
        .toolbar {
            ToolbarItem {
                Picker("Layout", selection: $layout) {
                    Label("Unified", systemImage: "rectangle.grid.1x2").tag(DiffLayout.unified)
                    Label("Split", systemImage: "rectangle.split.2x1").tag(DiffLayout.split)
                }
                .pickerStyle(.segmented)
                .help("Show changes in one column or side by side")
            }
            if let review = model?.review {
                ToolbarItem { OffDiffButton(review: review) }
            }
        }
        .onChange(of: layout) { model?.layout = layout }
        .onChange(of: target) { takeTarget() }
        // The task ends when the screen goes off screen, which stops the
        // polling. Coming back reuses the model, so the diff reloads in place.
        .task(id: source.key) {
            if model?.source.key != source.key {
                model = DiffModel(source: source, client: client, repoCache: repoCache, layout: layout)
            }
            takeTarget()
            await model?.run()
        }
    }
}

extension DiffScreen {
    private func takeTarget() {
        guard let target, let model else { return }
        model.pendingTarget = target
        self.target = nil
    }
}

/// Menu commands for the diff in the focused window: file navigation, viewed
/// marks, layout, and code size. Add it to the app's scene with `.commands`.
public struct DiffCommands: Commands {
    @FocusedValue(\.diffModel) private var model
    @AppStorage(DiffDefaults.layoutKey) private var layout = DiffLayout.unified
    @AppStorage(DiffDefaults.fontSizeKey) private var fontSize = DiffDefaults.fontSize

    public init() {}

    public var body: some Commands {
        CommandMenu("Diff") {
            Button("Next File") { model?.selectFile(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.control, .command])
                .disabled(model == nil)
            Button("Previous File") { model?.selectFile(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.control, .command])
                .disabled(model == nil)
            Button(model?.currentFile?.isViewed == true ? "Mark File as Unviewed" : "Mark File as Viewed") {
                model?.toggleCurrentFileViewed()
            }
            .keyboardShortcut("v", modifiers: [.control, .command])
            .disabled(model == nil)

            Divider()

            Button(layout == .unified ? "Show Side by Side" : "Show Unified") {
                layout = layout == .unified ? .split : .unified
            }
            .keyboardShortcut("l", modifiers: [.control, .command])

            Divider()

            Button("Bigger Code") { fontSize = min(fontSize + 1, DiffDefaults.fontSizeRange.upperBound) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Code") { fontSize = max(fontSize - 1, DiffDefaults.fontSizeRange.lowerBound) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Default Code Size") { fontSize = DiffDefaults.fontSize }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

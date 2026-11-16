import GitHubKit
import HermesUI
import SwiftUI

/// The CI checks of one commit: a list of checks grouped by workflow, and the
/// selected check's log, steps, or summary beside it.
///
/// The list reloads every ten seconds while a check is queued or running, and
/// for the first two minutes while the commit has no checks yet.
public struct ChecksScreen: View {
    private let repository: RepositoryRef
    private let commitOID: String
    private let client: GitHubClient
    private let initiallySelected: Check.ID?
    private let changes: WebhookChanges

    @State private var model = ChecksModel()
    @State private var refreshCount = 0

    /// - Parameters:
    ///   - initiallySelected: The check to show first, such as the one
    ///     clicked in a ``ChecksSummary``. Passing a different check later
    ///     selects it. With `nil`, the first failed check is selected.
    ///   - changes: What webhook deliveries have said about the commit's checks. When its
    ///     count rises, the screen applies the latest change, or reloads the checks when it
    ///     can't, ahead of its own polling.
    public init(
        repository: RepositoryRef, commitOID: String, client: GitHubClient, initiallySelected: Check? = nil, changes: WebhookChanges = WebhookChanges()
    ) {
        self.repository = repository
        self.commitOID = commitOID
        self.client = client
        self.initiallySelected = initiallySelected?.id
        self.changes = changes
    }

    public var body: some View {
        HSplitView {
            ChecksLoadingView(model: model, retry: { refreshCount += 1 }) {
                CheckListView(groups: CheckList.grouped(model.checks), selection: $model.selection, rerun: rerun)
            }
            // Under every state, so the list can be refreshed when it is empty or failed to load.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CheckListFooter(
                    rollup: model.isLoaded ? CheckList.rollup(model.checks) : "", refreshError: model.refreshError,
                    rerunFailed: rerunFailed, isRerunning: model.isRerunning
                ) { refreshCount += 1 }
            }
            .frame(minWidth: Metrics.listMinWidth, idealWidth: Metrics.listIdealWidth, maxWidth: Metrics.listMaxWidth)

            Group {
                if let check = model.selectedCheck {
                    CheckDetailView(
                        check: check, repository: repository, client: client, isRerunning: model.isRerunning,
                        rerun: check.jobID.flatMap { id in check.canRerun ? { rerun(.job(id)) } : nil }
                    )
                } else {
                    ContentUnavailableView(
                        "No Check Selected", systemImage: "checklist",
                        description: Text("Select a check to see its log.")
                    )
                }
            }
            .frame(minWidth: Metrics.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: LoadKey(repository: repository, commitOID: commitOID, refreshCount: refreshCount)) {
            await model.run(
                repository: repository, commitOID: commitOID, client: client, preferredSelection: initiallySelected
            )
        }
        .applying(changes, commitOID: commitOID, to: model) { refreshCount += 1 }
        .onChange(of: initiallySelected) { _, selected in
            if let selected { model.selection = selected }
        }
        .alert(
            "Couldn't Re-run the Jobs",
            isPresented: Binding { model.rerunError != nil } set: { if !$0 { model.rerunError = nil } }
        ) {
            Button("OK") { model.rerunError = nil }
        } message: {
            Text(model.rerunError ?? "")
        }
    }

    /// Runs the failed jobs of every workflow run again. `nil` when no job can run again.
    private var rerunFailed: (() -> Void)? {
        let runs = CheckList.rerunnableRuns(model.checks)
        return runs.isEmpty ? nil : { rerun(.failedJobs(runs: runs)) }
    }

    private func rerun(_ request: ChecksModel.Rerun) {
        Task {
            guard await model.rerun(request, repository: repository, client: client) else { return }
            // GitHub queues the new attempt a moment after it answers. The reload then follows it.
            try? await Task.sleep(for: ChecksModel.rerunSettle)
            refreshCount += 1
        }
    }
}

/// A compact list of a commit's checks for an overview page: a one-line
/// rollup, then one line per check with failed checks first. It does not
/// scroll. Calls `onSelect` when a check is clicked, so the host can switch to
/// a ``ChecksScreen`` created with that check as `initiallySelected`.
public struct ChecksSummary: View {
    private let repository: RepositoryRef
    private let commitOID: String
    private let client: GitHubClient
    private let onSelect: (Check) -> Void
    private let changes: WebhookChanges

    @State private var model = ChecksModel()
    @State private var refreshCount = 0

    /// - Parameter changes: As for ``ChecksScreen``.
    public init(
        repository: RepositoryRef, commitOID: String, client: GitHubClient, changes: WebhookChanges = WebhookChanges(), onSelect: @escaping (Check) -> Void
    ) {
        self.repository = repository
        self.commitOID = commitOID
        self.client = client
        self.changes = changes
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ChecksLoadingView(model: model, isCompact: true, retry: { refreshCount += 1 }) {
                CheckSummaryList(checks: model.checks, onSelect: onSelect)
            }
            if let refreshError = model.refreshError {
                RefreshErrorLabel(message: refreshError)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .task(id: LoadKey(repository: repository, commitOID: commitOID, refreshCount: refreshCount)) {
            await model.run(repository: repository, commitOID: commitOID, client: client)
        }
        .applying(changes, commitOID: commitOID, to: model) { refreshCount += 1 }
    }
}

private struct LoadKey: Hashable {
    let repository: RepositoryRef
    let commitOID: String
    let refreshCount: Int
}

/// How many deliveries have changed one commit's checks.
private struct CheckChanges: Equatable {
    let commitOID: String
    let count: Int
}

extension View {
    /// Applies the latest of `changes` to `model` when their count rises, and calls `reload`
    /// when the checks have to load: the change can't be applied, or a check is now queued
    /// or running and nothing is reloading the list.
    ///
    /// A new workflow run sends one check run per job, and none can be applied until a load
    /// knows the run. Such a burst calls `reload` at once and once more after, not once per
    /// delivery, so the load it started is not started over by each.
    fileprivate func applying(
        _ changes: WebhookChanges, commitOID: String, to model: ChecksModel, reload: @escaping @MainActor () -> Void
    ) -> some View {
        onChange(of: CheckChanges(commitOID: commitOID, count: changes.count)) { seen, now in
            // Another commit's count is not a change to this one.
            guard seen.commitOID == now.commitOID else { return }
            if let change = changes.only(since: seen.count), model.apply(change), !model.needsPolling { return }
            model.changeLoads.load(reload)
        }
    }
}

/// Shows `content` once the checks have loaded and there are some; otherwise
/// a loading, error, or empty state.
private struct ChecksLoadingView<Content: View>: View {
    let model: ChecksModel
    var isCompact = false
    let retry: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        if let message = model.errorMessage {
            if isCompact {
                HStack(spacing: Metrics.rowSpacing) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Retry", action: retry).controlSize(.small)
                }
                .font(Theme.Fonts.meta)
            } else {
                ContentUnavailableView {
                    Label("Couldn't Load Checks", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry", action: retry)
                }
            }
        } else if !model.isLoaded {
            if isCompact {
                HStack(spacing: Metrics.rowSpacing) {
                    ProgressView().controlSize(.small)
                    Text("Loading checks…").font(Theme.Fonts.meta).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Loading checks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if model.checks.isEmpty {
            if isCompact {
                Label("No checks ran on this commit", systemImage: "checklist")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "No Checks", systemImage: "checklist",
                    description: Text("Nothing has reported a check on this commit.")
                )
            }
        } else {
            content
        }
    }
}

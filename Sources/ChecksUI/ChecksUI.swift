import GitHubKit
import HermesUI
import StateKit
import SwiftUI

/// The CI checks of one commit: a list of checks grouped by workflow, and the
/// selected check's log, steps, or summary beside it.
///
/// The store reloads the list every ten seconds while a check is queued or running or a
/// workflow run waits for approval, and for the first two minutes while the commit has no
/// checks yet.
public struct ChecksScreen: View {
    private let commit: CommitKey
    private let store: GitHubStore
    private let initiallySelected: Check.ID?

    @State private var model = ChecksModel()

    /// - Parameter initiallySelected: The check to show first, such as the one clicked in a
    ///   ``ChecksSummary``. Passing a different check later selects it. With `nil`, the first
    ///   failed check is selected.
    public init(repository: RepositoryRef, commitOID: String, store: GitHubStore, initiallySelected: Check.ID? = nil) {
        commit = CommitKey(repository: repository, oid: commitOID)
        self.store = store
        self.initiallySelected = initiallySelected
    }

    public var body: some View {
        let state = store.checks[commit]
        let checks = state?.checks ?? []
        HSplitView {
            ChecksLoadingView(state: state, retry: reload) {
                CheckListView(groups: CheckList.grouped(checks), selection: $model.selection, rerun: rerun)
            }
            // Under every state, so the list can be refreshed when it is empty or failed to load.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CheckListFooter(
                    rollup: state?.isLoaded == true ? CheckList.rollup(checks) : "", refreshError: state?.refreshError,
                    rerunFailed: rerunFailed(checks), isRerunning: model.isRerunning, refresh: reload
                )
            }
            // Outside the loading view, so it shows when the waiting runs are all the commit has.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let runs = state?.awaitingApproval, !runs.isEmpty {
                    AwaitingApprovalRow(runs: runs) { try await approve(runs, on: commit, in: store) }
                        .padding(.horizontal, Metrics.barHorizontalPadding)
                        .padding(.vertical, Metrics.barVerticalPadding)
                        .background(.bar)
                        .overlay(alignment: .bottom) { Divider() }
                }
            }
            .frame(minWidth: Metrics.listMinWidth, idealWidth: Metrics.listIdealWidth, maxWidth: Metrics.listMaxWidth)

            Group {
                if let check = model.selectedCheck(in: checks) {
                    CheckDetailView(
                        check: check, repository: commit.repository, client: store.client, isRerunning: model.isRerunning,
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
        .showing(.checks(commit), in: store)
        // A new commit starts from the check asked for, or from the first failed one.
        .onChange(of: commit.oid, initial: true) { model.selection = initiallySelected }
        .onChange(of: checks, initial: true) {
            if model.selectedCheck(in: checks) == nil { model.selection = CheckList.defaultSelection(checks) }
        }
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

    private func reload() {
        Task { await store.loadChecks(commit) }
    }

    /// Runs the failed jobs of every workflow run again. `nil` when no job can run again.
    private func rerunFailed(_ checks: [Check]) -> (() -> Void)? {
        let runs = CheckList.rerunnableRuns(checks)
        return runs.isEmpty ? nil : { rerun(.failedJobs(runs: runs)) }
    }

    private func rerun(_ request: ChecksModel.Rerun) {
        Task {
            guard await model.rerun(request, repository: commit.repository, client: store.client) else { return }
            // GitHub queues the new attempt a moment after it answers. The reload then follows it.
            try? await Task.sleep(for: ChecksModel.rerunSettle)
            await store.loadChecks(commit)
        }
    }
}

/// A compact list of a commit's checks for an overview page: a one-line
/// rollup, then one line per check with failed checks first. It does not
/// scroll. Calls `onSelect` when a check is clicked, so the host can switch to
/// a ``ChecksScreen`` created with that check as `initiallySelected`.
public struct ChecksSummary: View {
    private let commit: CommitKey
    private let store: GitHubStore
    private let onSelect: (Check) -> Void

    public init(repository: RepositoryRef, commitOID: String, store: GitHubStore, onSelect: @escaping (Check) -> Void) {
        commit = CommitKey(repository: repository, oid: commitOID)
        self.store = store
        self.onSelect = onSelect
    }

    public var body: some View {
        let state = store.checks[commit]
        VStack(alignment: .leading, spacing: 2) {
            if let runs = state?.awaitingApproval, !runs.isEmpty {
                AwaitingApprovalRow(runs: runs) { try await approve(runs, on: commit, in: store) }
                    .padding(.bottom, 2)
            }
            ChecksLoadingView(state: state, isCompact: true, retry: { Task { await store.loadChecks(commit) } }) {
                CheckSummaryList(checks: state?.checks ?? [], onSelect: onSelect)
            }
            if let refreshError = state?.refreshError {
                RefreshErrorLabel(message: refreshError)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .showing(.checks(commit), in: store)
    }
}

/// Approves workflow runs that wait for a maintainer, then reloads the commit's checks so the
/// runs' jobs show. The reload runs after a refusal too, so the list shows what still waits.
///
/// - Throws: The first refusal, unless the reload finds no run still waiting. GitHub can
///   approve a commit's other waiting runs along with the first, and then refuses the rest.
@MainActor
private func approve(_ runs: [CheckRun.Workflow], on commit: CommitKey, in store: GitHubStore) async throws {
    var refusal: (any Error)?
    for run in runs {
        do {
            try await store.client.approveWorkflowRun(repository: commit.repository, runID: run.runID)
        } catch {
            refusal = refusal ?? error
        }
    }

    // GitHub queues the jobs a moment after it answers.
    try? await Task.sleep(for: ChecksModel.rerunSettle)
    await store.loadChecks(commit)
    if let refusal, store.checks[commit]?.awaitingApproval.isEmpty != true { throw refusal }
}

/// Shows `content` once the checks have loaded and there are some; otherwise
/// a loading, error, or empty state.
private struct ChecksLoadingView<Content: View>: View {
    let state: CommitChecks?
    var isCompact = false
    let retry: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        if let message = state?.errorMessage {
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
        } else if state?.isLoaded != true {
            if isCompact {
                HStack(spacing: Metrics.rowSpacing) {
                    ProgressView().controlSize(.small)
                    Text("Loading checks…").font(Theme.Fonts.meta).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Loading checks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if state?.checks.isEmpty ?? true {
            if state?.awaitingApproval.isEmpty == false {
                // The approval row above says why nothing has reported yet. The full screen
                // still fills its pane, so the row and footer stay at its edges.
                if !isCompact { Color.clear }
            } else if isCompact {
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

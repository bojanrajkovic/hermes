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

    @State private var model = ChecksModel()
    @State private var refreshCount = 0

    /// - Parameter initiallySelected: The check to show first, such as the one
    ///   clicked in a ``ChecksSummary``. Passing a different check later
    ///   selects it. With `nil`, the first failed check is selected.
    public init(repository: RepositoryRef, commitOID: String, client: GitHubClient, initiallySelected: Check? = nil) {
        self.repository = repository
        self.commitOID = commitOID
        self.client = client
        self.initiallySelected = initiallySelected?.id
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

    @State private var model = ChecksModel()
    @State private var refreshCount = 0

    public init(repository: RepositoryRef, commitOID: String, client: GitHubClient, onSelect: @escaping (Check) -> Void) {
        self.repository = repository
        self.commitOID = commitOID
        self.client = client
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
    }
}

private struct LoadKey: Hashable {
    let repository: RepositoryRef
    let commitOID: String
    let refreshCount: Int
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

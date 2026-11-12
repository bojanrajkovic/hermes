import Foundation
import GitHubKit
import Observation

/// The checks of one commit, kept fresh while any of them is still running.
@Observable @MainActor
final class ChecksModel {
    private(set) var checks: [Check] = []
    /// False until the first load for the current commit succeeds.
    private(set) var isLoaded = false
    /// Why the first load failed. A failed refresh keeps the checks it had.
    private(set) var errorMessage: String?
    /// Why the latest refresh failed. Nil once a load succeeds, so the checks
    /// shown are current whenever this is nil.
    private(set) var refreshError: String?
    var selection: Check.ID?
    /// A rerun request is on its way to GitHub.
    private(set) var isRerunning = false
    /// Why GitHub refused the last rerun.
    var rerunError: String?

    /// What to run again.
    enum Rerun: Equatable {
        /// One job, with the jobs that depend on it.
        case job(Int)
        /// The failed and cancelled jobs of these workflow runs.
        case failedJobs(runs: [Int])
    }

    @ObservationIgnored private var loadedCommit: String?

    nonisolated static let refreshInterval = Duration.seconds(10)
    /// How long after a rerun request the list reloads, so the queued attempt is in it.
    nonisolated static let rerunSettle = Duration.seconds(3)

    /// How long an empty list keeps reloading. GitHub creates a commit's
    /// checks a few seconds after the push, so an empty list right after one
    /// is not final. A commit nothing reports on stays empty, so this ends.
    nonisolated static let emptyListPolling = Duration.seconds(120)

    var selectedCheck: Check? { checks.first { $0.id == selection } }

    /// Whether to reload: a check is queued or running, or the list is still
    /// empty `elapsed` after loading started.
    nonisolated static func keepsPolling(_ checks: [Check], elapsed: Duration) -> Bool {
        checks.contains(where: \.state.isPending) || (checks.isEmpty && elapsed < emptyListPolling)
    }

    /// How long to wait before loading again after `error`, or after a
    /// successful load when it is nil. A used-up rate limit rejects every
    /// request until it resets, so wait for that.
    nonisolated static func reloadDelay(after error: (any Error)?, now: Date) -> Duration {
        guard case GitHubError.rateLimited(let resetAt)? = error else { return refreshInterval }
        return max(refreshInterval, .seconds(resetAt.timeIntervalSince(now)))
    }

    /// Loads the commit's checks, then reloads every ten seconds while
    /// `keepsPolling` says to. Returns after that or when the task is cancelled.
    func run(repository: RepositoryRef, commitOID: String, client: GitHubClient, preferredSelection: Check.ID? = nil) async {
        if loadedCommit != commitOID {
            loadedCommit = commitOID
            (checks, isLoaded, selection, refreshError) = ([], false, preferredSelection, nil)
        }
        errorMessage = nil
        let start = ContinuousClock.now

        while !Task.isCancelled {
            var delay = Self.refreshInterval
            do {
                let loaded = try await client.checks(repository: repository, commitOID: commitOID)
                // A response that arrives after cancellation belongs to a commit no longer shown.
                guard !Task.isCancelled else { return }
                checks = loaded
                isLoaded = true
                (errorMessage, refreshError) = (nil, nil)
                if selectedCheck == nil { selection = CheckList.defaultSelection(checks) }
                guard Self.keepsPolling(checks, elapsed: .now - start) else { return }
            } catch is CancellationError {
                return
            } catch {
                // A cancelled request throws URLError, not CancellationError.
                guard !Task.isCancelled else { return }
                guard isLoaded else {
                    errorMessage = ChecksError.message(for: error)
                    return
                }
                refreshError = ChecksError.message(for: error)
                delay = Self.reloadDelay(after: error, now: .now)
            }
            try? await Task.sleep(for: delay)
        }
    }
}

extension ChecksModel {
    /// Asks GitHub to run jobs again.
    ///
    /// - Returns: Whether GitHub took every request. On failure `rerunError` says why.
    func rerun(_ rerun: Rerun, repository: RepositoryRef, client: GitHubClient) async -> Bool {
        isRerunning = true
        defer { isRerunning = false }
        do {
            switch rerun {
            case .job(let id): try await client.rerunJob(repository: repository, jobID: id)
            case .failedJobs(let runs):
                for run in runs { try await client.rerunFailedJobs(repository: repository, runID: run) }
            }
            rerunError = nil
            return true
        } catch {
            rerunError = ChecksError.message(for: error)
            return false
        }
    }
}

enum ChecksError {
    /// What to tell the user when a request fails.
    static func message(for error: any Error) -> String {
        switch error {
        case GitHubError.ghNotInstalled:
            "The gh command line tool is not installed."
        case GitHubError.ghNotLoggedIn:
            "gh is not signed in. Run “gh auth login” in a terminal."
        case GitHubError.rateLimited(let resetAt):
            "GitHub's rate limit is used up. It resets at \(resetAt.formatted(date: .omitted, time: .shortened))."
        case GitHubError.http(let status, let message):
            message.isEmpty ? "GitHub answered with HTTP \(status)." : "GitHub answered with HTTP \(status): \(message)"
        case GitHubError.graphQL(let errors):
            errors.first?.message ?? "GitHub could not answer the request."
        case GitHubError.logsUnavailable:
            "GitHub has no log for this job. It was skipped, has not started, or the log has expired."
        default:
            error.localizedDescription
        }
    }
}

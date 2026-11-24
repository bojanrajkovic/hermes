import Foundation
import GitHubKit

/// One commit of one repository. Checks belong to a commit, so a pull request's checks are its
/// head commit's, and a push shows the new commit's checks without a reload.
public struct CommitKey: Hashable, Sendable, Codable {
    public let repository: RepositoryRef
    public let oid: String

    public init(repository: RepositoryRef, oid: String) {
        self.repository = repository
        self.oid = oid
    }
}

/// A commit's checks and how their loads went.
public struct CommitChecks: Sendable {
    public internal(set) var checks: [Check] = []
    /// Workflow runs that wait for a maintainer's approval before they run.
    public internal(set) var awaitingApproval: [CheckRun.Workflow] = []
    /// False until the first load succeeds.
    public internal(set) var isLoaded = false
    /// Why the first load failed. A failed refresh keeps the checks it had.
    public internal(set) var errorMessage: String?
    /// Why the latest refresh failed. Nil once a load succeeds.
    public internal(set) var refreshError: String?
}

/// The store's cache keeps loaded checks, not errors.
extension CommitChecks: Codable {
    private enum CodingKeys: String, CodingKey { case checks, isLoaded }
}

/// How often a commit's checks reload while one is queued or running.
let checksInterval = Duration.seconds(10)
/// How long an empty list keeps reloading. GitHub creates a commit's checks a few seconds
/// after the push, so an empty list right after one is not final. A commit nothing reports
/// on stays empty, so this ends.
let emptyChecksPolling = Duration.seconds(120)

/// Whether to reload: a check is queued or running, a workflow run waits for approval, which
/// can come from github.com, or the list is still empty `elapsed` after a screen started
/// showing it.
func keepsPolling(_ held: CommitChecks, elapsed: Duration) -> Bool {
    held.checks.contains(where: \.isPending) || !held.awaitingApproval.isEmpty
        || (held.checks.isEmpty && elapsed < emptyChecksPolling)
}

/// How long to wait before loading again after `error`. A used-up rate limit rejects every
/// request until it resets, so wait for that.
func checksReloadDelay(after error: any Error, now: Date) -> Duration {
    guard case GitHubError.rateLimited(let resetAt) = error else { return checksInterval }
    return max(checksInterval, .seconds(resetAt.timeIntervalSince(now)))
}

extension GitHubStore {
    /// Loads a shown commit's checks.
    ///
    /// The first poll after a screen starts showing the commit loads, so a list that settled
    /// while no screen showed it is current again. After that a poll loads while
    /// `keepsPolling` says to, and retries a failed refresh once its wait has passed. A
    /// failed first load waits for Retry.
    func pollChecks(_ commit: CommitKey) async {
        guard let shownAt = checksShownAt[commit] else { return await loadChecks(commit) }
        if let wait = checksWaitUntil[commit], Date.now < wait { return }
        if let held = checks[commit] {
            if held.errorMessage != nil { return }
            let elapsed = Duration.seconds(Date.now.timeIntervalSince(shownAt))
            if held.isLoaded, held.refreshError == nil, !keepsPolling(held, elapsed: elapsed) { return }
        }
        await fetchChecks(commit)
    }

    /// Loads a commit's checks now, and starts again the 2 minutes an empty list keeps
    /// loading. For a screen's first poll, Retry, Refresh, a rerun, and webhook bursts.
    public func loadChecks(_ commit: CommitKey) async {
        checksShownAt[commit] = .now
        checksWaitUntil[commit] = nil
        await fetchChecks(commit)
    }

    /// Asks GitHub for a commit's checks. A change applied while GitHub answers is newer
    /// than the answer, so the checks load once more. A load that a later one overtakes
    /// drops its answer.
    private func fetchChecks(_ commit: CommitKey) async {
        checkLoads[commit, default: 0] += 1
        let load = checkLoads[commit] ?? 0
        while true {
            let before = checkWrites[commit, default: 0]
            do {
                let loaded = try await client.checks(repository: commit.repository, commitOID: commit.oid)
                guard load == checkLoads[commit] else { return }
                guard checkWrites[commit, default: 0] == before else { continue }
                checks[commit] = CommitChecks(checks: loaded.checks, awaitingApproval: loaded.awaitingApproval, isLoaded: true)
                checksWaitUntil[commit] = nil
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                guard load == checkLoads[commit] else { return }
                let delay = checksReloadDelay(after: error, now: .now)
                checksWaitUntil[commit] = Date.now.addingTimeInterval(TimeInterval(delay.components.seconds))
                if checks[commit]?.isLoaded == true {
                    checks[commit]?.refreshError = describe(error)
                } else {
                    checks[commit] = CommitChecks(errorMessage: describe(error))
                }
            }
            return
        }
    }

    /// Forgets when screens started showing a commit, once none does. The next screen's
    /// first poll then loads.
    func stoppedShowing(_ commit: CommitKey) {
        checksShownAt[commit] = nil
    }

    /// Applies what a webhook says changed to a commit's checks.
    ///
    /// - Returns: False when nothing is loaded yet or the change can't be applied, so the
    ///   checks have to load instead.
    public func applyToChecks(_ change: WebhookChange, for commit: CommitKey) -> Bool {
        guard let held = checks[commit], held.isLoaded, let changed = Check.applying(change, to: held.checks) else { return false }
        checks[commit]?.checks = changed
        checkWrites[commit, default: 0] += 1
        return true
    }
}

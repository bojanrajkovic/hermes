import Foundation
import GitHubKit
import Observation

/// One checks screen's own state: the selected check and reruns. The checks themselves are
/// the store's, which keeps them fresh while any screen shows the commit.
@Observable @MainActor
final class ChecksModel {
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

    /// Loads the checks for the deliveries that can't be applied, twice for a burst of them.
    let changeLoads = BurstLoader()

    /// How long after a rerun request the list reloads, so the queued attempt is in it.
    nonisolated static let rerunSettle = Duration.seconds(3)

    /// The selected check among `checks`.
    func selectedCheck(in checks: [Check]) -> Check? {
        checks.first { $0.id == selection }
    }

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

import Foundation
import GitHubKit
import Observation

/// One step of a GitHub Actions job.
struct JobStep: Sendable, Equatable, Identifiable, Decodable {
    let number: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?

    var id: Int { number }

    var state: CheckState {
        CheckState(
            status: CheckRun.Status(rawValue: status.uppercased()) ?? .queued,
            conclusion: conclusion.flatMap { CheckRun.Conclusion(rawValue: $0.uppercased()) }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case number, name, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

/// A GitHub Actions job, as `GET /repos/{owner}/{repo}/actions/jobs/{job_id}` returns it.
struct ActionsJob: Sendable, Equatable, Decodable {
    let status: String
    let steps: [JobStep]?

    var isCompleted: Bool { status == "completed" }
}

/// What a check run reported about itself, from `GET /repos/{owner}/{repo}/check-runs/{id}`.
struct CheckRunOutput: Sendable, Equatable, Decodable {
    let title: String?
    let summary: String?
    let text: String?

    /// The summary and text as one Markdown document. Nil when both are empty.
    var markdown: String? {
        let parts = [summary, text].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

private struct CheckRunResponse: Decodable, Sendable {
    let output: CheckRunOutput
}

/// What the detail pane shows for the selected check.
@Observable @MainActor
final class CheckDetailModel {
    enum Content {
        case loading
        /// The job is queued or running: its steps so far.
        case steps([JobStep])
        case log(LogViewModel)
        /// A check with no log: what it reported, if anything.
        case summary(CheckRunOutput?)
        /// The legacy status's description.
        case status(String?)
        case noLog
        case failed(String)
    }

    private(set) var content = Content.loading

    var stepRefreshInterval = Duration.seconds(5)
    var logRetryInterval = Duration.seconds(2)
    static let logTriesAfterWatching = 5

    /// Loads what there is to show for `check`. For a job that has not
    /// finished, shows its steps and refreshes them until it has, then loads the log.
    func run(check: Check, repository: RepositoryRef, client: GitHubClient) async {
        content = .loading
        let loaded = await load(check: check, repository: repository, client: client)
        // A cancelled load must not replace what the next check's load shows.
        if !Task.isCancelled { content = loaded }
    }

    private func load(check: Check, repository: RepositoryRef, client: GitHubClient) async -> Content {
        do {
            switch check {
            case .status(let status):
                return .status(status.description)
            case .run(let run):
                guard let jobID = check.jobID else {
                    let path = "/repos/\(repository.owner)/\(repository.name)/check-runs/\(run.databaseID)"
                    return .summary(try? await client.get(path, as: CheckRunResponse.self).output)
                }
                let wasWatched = check.state.isPending
                if wasWatched { try await followSteps(jobID: jobID, repository: repository, client: client) }
                guard check.state != .skipped else { return .noLog }
                // GitHub can take a few seconds to publish the log of a job that just finished.
                let tries = wasWatched ? Self.logTriesAfterWatching : 1
                return .log(await LogViewModel.load(raw: try await jobLogs(jobID, repository: repository, client: client, tries: tries)))
            }
        } catch GitHubError.logsUnavailable {
            return .noLog
        } catch {
            return .failed(ChecksError.message(for: error))
        }
    }

    /// The job's log, asking up to `tries` times while GitHub has none.
    private func jobLogs(_ jobID: Int, repository: RepositoryRef, client: GitHubClient, tries: Int) async throws -> String {
        for _ in 1..<tries {
            do {
                return try await client.jobLogs(repository: repository, jobID: jobID)
            } catch GitHubError.logsUnavailable {
                try await Task.sleep(for: logRetryInterval)
            }
        }
        return try await client.jobLogs(repository: repository, jobID: jobID)
    }

    /// Returns once the job has completed. Throws only when the first request
    /// fails: after that a failed refresh keeps the steps it had and tries
    /// again, as the list does with its checks.
    private func followSteps(jobID: Int, repository: RepositoryRef, client: GitHubClient) async throws {
        var hasShownSteps = false
        while true {
            do {
                let job = try await client.get(
                    "/repos/\(repository.owner)/\(repository.name)/actions/jobs/\(jobID)", as: ActionsJob.self
                )
                if job.isCompleted || Task.isCancelled { return }
                content = .steps(job.steps ?? [])
                hasShownSteps = true
            } catch {
                guard hasShownSteps, !Task.isCancelled else { throw error }
            }
            try await Task.sleep(for: stepRefreshInterval)
        }
    }
}

import Foundation
import Testing
import GitHubKit

/// Read-only calls against github.com with the token from `gh`. Run with
/// `HERMES_LIVE=1 swift test --filter GitHubKitTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERMES_LIVE"] == "1"))
struct LiveTests {
    private let client = GitHubClient()

    @Test func readsAnAccountsPullRequestsIssuesAndChecks() async throws {
        let viewer = try await client.viewer()
        #expect(viewer.accounts.first?.login == viewer.login)

        let repositories = try await client.repositories(owner: viewer.login)
        #expect(!repositories.isEmpty)

        let pullRequests = try await client.openPullRequests(owner: viewer.login)
        guard let pullRequest = pullRequests.first else { return }

        let detail = try await client.pullRequestDetail(repository: pullRequest.repository, number: pullRequest.number)
        #expect(detail.id == pullRequest.id)

        let revision = try await client.pullRequestRevision(repository: pullRequest.repository, number: pullRequest.number)
        #expect(revision.headOID.count == 40)

        let diff = try await client.pullRequestDiff(repository: pullRequest.repository, number: pullRequest.number)
        #expect(diff.hasPrefix("diff --git"))

        let checks = try await client.checks(repository: pullRequest.repository, commitOID: pullRequest.headOID)
        let job = checks.lazy.compactMap { check -> CheckRun? in
            // A skipped job never ran, so it has no log.
            if case .run(let run) = check, run.workflow != nil, run.conclusion == .success { run } else { nil }
        }.first
        if let job {
            let log = try await client.jobLogs(repository: pullRequest.repository, jobID: job.databaseID)
            #expect(log.first?.isNumber == true, "A log line starts with its timestamp")
        }

        await #expect(throws: GitHubError.logsUnavailable) {
            try await client.jobLogs(repository: pullRequest.repository, jobID: 1)
        }

        let issues = try await client.issues(repository: pullRequest.repository, pageSize: 2)
        #expect(issues.items.count <= 2)
        if let issue = issues.items.first {
            _ = try await client.issueDetail(repository: pullRequest.repository, number: issue.number)
        }
        if issues.hasNextPage {
            let next = try await client.issues(repository: pullRequest.repository, pageSize: 2, after: issues.endCursor)
            #expect(Set(next.items.map(\.id)).isDisjoint(with: issues.items.map(\.id)))
        }
    }

    @Test func aDiffOverGitHubsFileLimitIsTooLarge() async throws {
        // 836 changed files; GitHub renders at most 300.
        await #expect(throws: GitHubError.diffTooLarge) {
            try await client.pullRequestDiff(repository: RepositoryRef(owner: "rust-lang", name: "rust"), number: 149_543)
        }
    }

    @Test func anOrganizationsPullRequestsAreAllInItsRepositories() async throws {
        let pullRequests = try await client.openPullRequests(owner: "vapor")
        #expect(pullRequests.count > 50, "More than one page")
        #expect(pullRequests.allSatisfy { $0.repository.owner == "vapor" })
        #expect(Set(pullRequests.map(\.id)).count == pullRequests.count)
    }

    @Test func aMissingRepositoryIsAGraphQLNotFoundError() async throws {
        let missing = RepositoryRef(owner: "github", name: "this-repository-does-not-exist-hermes")
        await #expect {
            try await client.pullRequestRevision(repository: missing, number: 1)
        } throws: { error in
            guard case GitHubError.graphQL(let errors) = error else { return false }
            return errors.contains { $0.type == "NOT_FOUND" }
        }
    }
}

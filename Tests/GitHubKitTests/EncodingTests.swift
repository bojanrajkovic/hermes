import Foundation
import Testing
@testable import GitHubKit

/// The store's cache encodes models in the GraphQL shape their decoders read. Encoding and then
/// decoding a value must give back the same value.
@Suite struct EncodingTests {
    /// Encodes and decodes with the store cache's coders.
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func capturedPullRequestsRoundTrip() throws {
        let pullRequests = try graphQLFixture("pull_requests", as: SearchData<PullRequest>.self).search.nodes
        #expect(try roundTrip(pullRequests) == pullRequests)
    }

    @Test func aPullRequestKeepsWhatGitHubsRollupCantSay() throws {
        let user = User(login: "bojan", avatarURL: URL(string: "https://example.com/b.png")!, isBot: true)
        let pullRequest = PullRequest(
            id: "PR_1", number: 1, title: "Title", url: URL(string: "https://github.com/a/b/pull/1")!,
            repository: RepositoryRef(owner: "a", name: "b"), author: user, isDraft: true, createdAt: .now,
            updatedAt: .now, headRefName: "head", baseRefName: "main", headOID: "abc", reviewDecision: .approved,
            additions: 1, deletions: 2, changedFileCount: 3, mergeable: .conflicting,
            labels: [GitHubLabel(name: "bug", color: "ff0000")], checkState: .optionalFailed,
            stack: StackEntry(stackID: "S_1", stackNumber: 4, size: 2, baseRefName: "main", position: 2),
            closingIssueNumbers: [7], autoMergeMethod: .squash,
            requestedReviewers: [.user(login: "ann"), .team(organization: "acme", slug: "core")],
            viewerReviewedCommit: "def", state: .merged, isCrossRepository: true
        )
        #expect(try roundTrip(pullRequest) == pullRequest)
    }

    @Test func capturedRepositoriesRoundTrip() throws {
        let repositories = try graphQLFixture("repositories", as: RepositoryOwnerFixture.self).repositoryOwner.repositories.nodes
        #expect(try roundTrip(repositories) == repositories)
    }

    @Test func capturedPullRequestDetailsRoundTrip() throws {
        for name in ["pull_request_detail", "pull_request_detail_outdated"] {
            let detail = try graphQLFixture(name, as: RepositoryData<PullRequestField<PullRequestDetail>>.self).repository.pullRequest
            #expect(try roundTrip(detail) == detail)
        }
    }

    @Test func requestedTeamsAndUsersRoundTrip() throws {
        let reviewers: [RequestedReviewer] = [
            .team(name: "Core", slug: "core"),
            .user(User(login: "ann", avatarURL: URL(string: "https://example.com/a.png")!, isBot: false)),
        ]
        #expect(try roundTrip(reviewers) == reviewers)
    }

    @Test func checkRunsAndStatusesRoundTrip() throws {
        var checks = try #require(
            try graphQLFixture("checks", as: RepositoryData<ChecksField>.self).repository.object?.statusCheckRollup?.contexts.nodes
        )
        checks.append(.status(StatusContext(context: "ci/build", state: .pending, targetURL: nil, description: "Running")))
        checks.append(.run(CheckRun(
            databaseID: 9, name: "lint", status: .queued, conclusion: nil, startedAt: nil, completedAt: nil,
            detailsURL: nil, appName: nil, workflow: nil
        )))
        #expect(try roundTrip(checks) == checks)
    }
}

import Foundation
import Testing
@testable import GitHubKit

/// Loads a response captured from the GitHub API.
func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func graphQLFixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    try GitHubClient.decodeGraphQL(type, from: fixture(name), rateLimitReset: .distantFuture)
}

@Suite struct DecodingTests {
    @Test func viewerPutsThePersonalAccountFirstThenOrganizationsByLogin() throws {
        let profile = ViewerProfile(
            user: try GitHubClient.decode(RESTUser.self, from: fixture("viewer")),
            organizations: try graphQLFixture("organizations", as: OrganizationsData.self)
        )

        #expect(profile.login == "bojanrajkovic")
        #expect(profile.profileURL.absoluteString == "https://github.com/bojanrajkovic")
        #expect(profile.location == "Boston MSA")
        #expect(profile.organizations.count == 1)
        #expect(profile.accounts.first?.kind == .personal)
        #expect(profile.accounts.map(\.login) == ["bojanrajkovic", "Freenode-Csharp"])
    }

    @Test func pullRequestsDecodeStackAuthorAndRollup() throws {
        let pullRequests = try graphQLFixture("pull_requests", as: SearchData<PullRequest>.self).search.nodes
        #expect(pullRequests.map(\.number) == [96, 95, 94, 91, 27])

        let top = try #require(pullRequests.first)
        #expect(top.id == "PR_kwDOVkPx6c8AAAABOQYQvg")
        #expect(top.repository == RepositoryRef(owner: "bojanrajkovic", name: "airway"))
        #expect(top.author == User(
            login: "bojanrajkovic",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/110747?v=4")!,
            isBot: false
        ))
        #expect(top.headRefName == "query-results")
        #expect(top.baseRefName == "query-links")
        #expect(top.headOID == "dcd01fd72064f966f24dd1197cf5a273b8b132f8")
        #expect(top.createdAt == Date(timeIntervalSince1970: 1_794_358_445))
        #expect(top.reviewDecision == nil)
        #expect(top.additions == 224)
        #expect(top.deletions == 1)
        #expect(top.changedFileCount == 6)
        #expect(top.mergeable == .mergeable)
        #expect(top.checkState == .success)
        #expect(top.stack == StackEntry(
            stackID: "PRS_kwDOVkPx6c4AMxgs", stackNumber: 97, size: 3, baseRefName: "main", position: 3
        ))
        #expect(top.closingIssueNumbers == [6])

        let releaseBot = pullRequests[3]
        #expect(releaseBot.author?.isBot == true)
        #expect(releaseBot.stack == nil)
        #expect(!releaseBot.labels.isEmpty)

        #expect(pullRequests[4].checkState == .failure)
    }

    @Test func repositoriesDecodeOpenCounts() throws {
        let repositories = try graphQLFixture("repositories", as: OwnerData.self).repositoryOwner.repositories.nodes

        #expect(repositories.count == 4)
        #expect(repositories[0].ref == RepositoryRef(owner: "bojanrajkovic", name: "hermes"))
        #expect(repositories[0].isPrivate)
        #expect(repositories[0].openIssueCount == 0)
        #expect(repositories.contains { $0.openIssueCount > 0 || $0.openPullRequestCount > 0 })
    }

    @Test func issuesDecodePageAndLinkedPullRequests() throws {
        let page = try graphQLFixture("issues", as: RepositoryData<IssuesField>.self).repository.issues

        #expect(page.totalCount == 59)
        #expect(page.pageInfo?.hasNextPage == true)
        #expect(page.pageInfo?.endCursor != nil)

        let issue = try #require(page.nodes.first { $0.number == 6 })
        #expect(issue.state == .open)
        #expect(issue.url.absoluteString == "https://github.com/bojanrajkovic/airway/issues/6")
        #expect(issue.linkedPullRequests == [
            LinkedPullRequest(
                number: 96, title: "feat(contract): define query results and the agent row cap",
                state: .open, headRefName: "query-results"
            ),
        ])
    }

    @Test func issueDetailDecodesBodyAndComments() throws {
        let detail = try graphQLFixture("issue_detail", as: RepositoryData<IssueField>.self).repository.issue

        #expect(detail.body.count == 3276)
        #expect(detail.comments.isEmpty)
    }

    @Test func pullRequestDetailDecodesReviewsCommitsAndThreads() throws {
        let detail = try graphQLFixture(
            "pull_request_detail", as: RepositoryData<PullRequestField<PullRequestDetail>>.self
        ).repository.pullRequest

        #expect(detail.id == "PR_kwDOVkPx6c8AAAABOQYNoQ")
        #expect(detail.body.count == 1924)
        #expect(detail.commits.count == 9)
        #expect(detail.commits.allSatisfy { $0.oid.count == 40 && !$0.headline.isEmpty })
        #expect(detail.requestedReviewers.isEmpty)

        let review = try #require(detail.reviews.first)
        #expect(review.state == .commented)
        #expect(review.author?.login == "bojanrajkovic")
        #expect(review.submittedAt != nil)

        let thread = try #require(detail.reviewThreads.first)
        #expect(thread.path == "packages/contract/src/query/spec.ts")
        #expect(thread.line == 28)
        #expect(thread.diffSide == .right)
        #expect(thread.startDiffSide == nil)
        #expect(thread.isResolved)
        #expect(!thread.isOutdated)
        #expect(thread.comments.count == 1)
        #expect(thread.comments[0].author?.login == "bojanrajkovic")
    }

    @Test func outdatedThreadsHaveNoLine() throws {
        let detail = try graphQLFixture(
            "pull_request_detail_outdated", as: RepositoryData<PullRequestField<PullRequestDetail>>.self
        ).repository.pullRequest

        #expect(detail.reviewThreads.count == 3)
        #expect(detail.reviewThreads.allSatisfy { $0.isOutdated && $0.line == nil })
    }

    @Test func checkRunsDecodeTheirWorkflow() throws {
        let checks = try #require(
            try graphQLFixture("checks", as: RepositoryData<ChecksField>.self)
                .repository.object?.statusCheckRollup?.contexts.nodes
        )

        #expect(checks.count == 2)
        guard case .run(let run) = checks[0] else {
            Issue.record("Expected a check run")
            return
        }
        #expect(run.databaseID == 130_274_795_380)
        #expect(run.name == "Lint and test")
        #expect(run.status == .completed)
        #expect(run.conclusion == .success)
        #expect(run.appName == "GitHub Actions")
        #expect(run.workflow == CheckRun.Workflow(name: "CI", runID: 42_944_768_580))
        #expect(run.startedAt != nil)
        #expect(checks[0].id == "run-130274795380")
        #expect(checks[0].outcome == .passed)
    }

    // No repository at hand reports legacy statuses, so this response is written by hand.
    @Test func statusContextsAndThirdPartyRunsDecode() throws {
        let json = """
            [
              {"__typename": "StatusContext", "context": "ci/build", "state": "ERROR",
               "targetUrl": "https://ci.example.com/1", "description": "Build errored"},
              {"__typename": "CheckRun", "databaseId": 7, "name": "lint", "status": "QUEUED", "conclusion": null,
               "startedAt": null, "completedAt": null, "detailsUrl": null,
               "checkSuite": {"app": {"name": "Linter"}, "workflowRun": null}}
            ]
            """
        let checks = try GitHubClient.decode([Check].self, from: Data(json.utf8))

        #expect(checks[0] == .status(StatusContext(
            context: "ci/build", state: .error,
            targetURL: URL(string: "https://ci.example.com/1"), description: "Build errored"
        )))
        #expect(checks[0].outcome == .failed)
        #expect(checks[0].id == "status-ci/build")

        guard case .run(let run) = checks[1] else {
            Issue.record("Expected a check run")
            return
        }
        #expect(run.workflow == nil)
        #expect(checks[1].outcome == .pending)
    }

    @Test(arguments: [
        (CheckRun.Conclusion.success, Check.Outcome.passed),
        (.neutral, .skipped),
        (.skipped, .skipped),
        (.failure, .failed),
        (.cancelled, .failed),
        (.timedOut, .failed),
        (.actionRequired, .failed),
    ])
    func completedRunOutcome(conclusion: CheckRun.Conclusion, outcome: Check.Outcome) {
        let run = CheckRun(
            databaseID: 1, name: "job", status: .completed, conclusion: conclusion, startedAt: nil,
            completedAt: nil, detailsURL: nil, appName: nil, workflow: nil
        )
        #expect(Check.run(run).outcome == outcome)
    }
}

@Suite struct ResponseTests {
    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com/x")!, statusCode: status, httpVersion: nil, headerFields: headers
        )!
    }

    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func successIsNotAnError() {
        #expect(GitHubClient.error(for: response(200), body: Data(), now: now) == nil)
        #expect(GitHubClient.error(for: response(204), body: Data(), now: now) == nil)
    }

    @Test func httpErrorCarriesGitHubsMessage() {
        let body = Data(#"{"message": "Not Found", "status": "404"}"#.utf8)
        #expect(GitHubClient.error(for: response(404), body: body, now: now) == .http(status: 404, message: "Not Found"))
        #expect(GitHubClient.error(for: response(502), body: Data("<html>".utf8), now: now) == .http(status: 502, message: ""))
    }

    @Test func primaryRateLimitReportsTheResetTime() {
        let limited = response(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "5000"])
        #expect(
            GitHubClient.error(for: limited, body: Data(), now: now)
                == .rateLimited(resetAt: Date(timeIntervalSince1970: 5_000))
        )
    }

    @Test func secondaryRateLimitReportsRetryAfter() {
        let limited = response(429, ["retry-after": "30"])
        #expect(
            GitHubClient.error(for: limited, body: Data(), now: now)
                == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_030))
        )
    }

    @Test func forbiddenWithQuotaLeftIsAPlainHTTPError() {
        let forbidden = response(403, ["x-ratelimit-remaining": "4000", "x-ratelimit-reset": "5000"])
        #expect(GitHubClient.error(for: forbidden, body: Data(), now: now) == .http(status: 403, message: ""))
    }

    @Test func graphQLErrorsWinOverPartialData() {
        let body = Data("""
            {"data": {"repository": null},
             "errors": [{"type": "NOT_FOUND", "path": ["repository"], "message": "Could not resolve to a Repository"}]}
            """.utf8)
        #expect(throws: GitHubError.graphQL([
            GraphQLError(message: "Could not resolve to a Repository", type: "NOT_FOUND"),
        ])) {
            try GitHubClient.decodeGraphQL(RepositoryData<IssueField>.self, from: body, rateLimitReset: now)
        }
    }

    @Test func graphQLRateLimitErrorBecomesRateLimited() {
        let body = Data(#"{"errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}"#.utf8)
        #expect(throws: GitHubError.rateLimited(resetAt: now)) {
            try GitHubClient.decodeGraphQL(SearchData<PullRequest>.self, from: body, rateLimitReset: now)
        }
    }

    @Test func unexpectedShapeIsADecodingError() {
        #expect {
            try GitHubClient.decodeGraphQL(SearchData<PullRequest>.self, from: Data(#"{"data": {}}"#.utf8), rateLimitReset: now)
        } throws: { error in
            if case GitHubError.decoding = error { true } else { false }
        }
    }
}

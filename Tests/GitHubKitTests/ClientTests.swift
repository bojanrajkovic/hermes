import Foundation
import os
import Testing
@testable import GitHubKit

/// Answers every request of a `URLSession` from `respond`, and records the requests.
final class StubProtocol: URLProtocol {
    struct Response: Sendable {
        var status = 200
        var body = ""
    }

    struct Recorded: Sendable {
        let method: String
        let path: String
        let authorization: String?
        let body: String
        let cachePolicy: URLRequest.CachePolicy
    }

    static let respond = OSAllocatedUnfairLock<@Sendable (Recorded) -> Response>(initialState: { _ in Response() })
    static let requests = OSAllocatedUnfairLock<[Recorded]>(initialState: [])

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLSession hands a protocol the body as a stream.
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let recorded = Recorded(
            method: request.httpMethod ?? "GET",
            path: request.url!.path,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: String(decoding: body, as: UTF8.self),
            cachePolicy: request.cachePolicy
        )
        Self.requests.withLock { $0.append(recorded) }

        let response = Self.respond.withLock { $0 }(recorded)
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Counts how often the client asks for a token, and hands out `token-1`, `token-2`, ...
actor TokenCounter {
    private(set) var reads = 0

    func next() async -> String {
        reads += 1
        // Long enough for concurrent callers to pile up behind the first read.
        try? await Task.sleep(for: .milliseconds(50))
        return "token-\(reads)"
    }
}

// Serialized: the tests share `StubProtocol`'s static state.
@Suite(.serialized) struct ClientTests {
    private let repository = RepositoryRef(owner: "o", name: "r")

    private func client(
        tokens: TokenCounter = TokenCounter(), respond: @escaping @Sendable (StubProtocol.Recorded) -> StubProtocol.Response
    ) -> GitHubClient {
        StubProtocol.requests.withLock { $0 = [] }
        StubProtocol.respond.withLock { $0 = respond }
        return GitHubClient(session: StubProtocol.session(), token: { await tokens.next() })
    }

    private func checksPage(run id: Int, endCursor: String?) -> String {
        let next = endCursor.map { #""\#($0)""# } ?? "null"
        return """
            {"data": {"repository": {"object": {"statusCheckRollup": {"contexts": {
              "pageInfo": {"hasNextPage": \(endCursor != nil), "endCursor": \(next)},
              "nodes": [{"__typename": "CheckRun", "databaseId": \(id), "name": "job", "status": "QUEUED",
                         "checkSuite": {"app": null, "workflowRun": null}}]
            }}}}}}
            """
    }

    @Test func paginationFollowsTheCursorToTheLastPage() async throws {
        let client = client { [checksPage] request in
            if request.body.contains(#""after":"c1""#) { return .init(body: checksPage(2, "c2")) }
            if request.body.contains(#""after":"c2""#) { return .init(body: checksPage(3, nil)) }
            return .init(body: checksPage(1, "c1"))
        }

        let checks = try await client.checks(repository: repository, commitOID: "abc")

        #expect(checks.map(\.id) == ["run-1", "run-2", "run-3"])
        #expect(StubProtocol.requests.withLock { $0.count } == 3)
    }

    /// Answers the two queries of `openPullRequests`: a search that finds
    /// `PR_0` to `PR_24` over two pages, and the fields of the IDs asked for.
    private func pullRequestList() throws -> @Sendable (StubProtocol.Recorded) -> StubProtocol.Response {
        let json = try JSONSerialization.jsonObject(with: fixture("pull_requests")) as? [String: [String: [String: Any]]]
        let template = try #require((json?["data"]?["search"]?["nodes"] as? [[String: Any]])?.first)
        let nodeTemplate = String(decoding: try JSONSerialization.data(withJSONObject: template), as: UTF8.self)
            .replacingOccurrences(of: template["id"] as! String, with: "ID")

        return { request in
            func searchPage(_ range: ClosedRange<Int>, endCursor: String?) -> StubProtocol.Response {
                let nodes = range.map { #"{"id": "PR_\#($0)"}"# }.joined(separator: ",")
                let next = endCursor.map { #""\#($0)""# } ?? "null"
                return .init(body: """
                    {"data": {"search": {"pageInfo": {"hasNextPage": \(endCursor != nil), "endCursor": \(next)}, "nodes": [\(nodes)]}}}
                    """)
            }
            guard request.body.contains("nodes(ids:") else {
                // The second page repeats PR_12, as when the results shift between requests.
                return request.body.contains(#""after":"c1""#) ? searchPage(12...24, endCursor: nil) : searchPage(0...12, endCursor: "c1")
            }
            // The first request finishes last.
            if request.body.contains(#""PR_0""#) { Thread.sleep(forTimeInterval: 0.1) }
            let nodes = request.body.matches(of: /"(PR_\d+)"/)
                .map { nodeTemplate.replacingOccurrences(of: "ID", with: $0.1) }
            return .init(body: #"{"data": {"nodes": [\#(nodes.joined(separator: ","))]}}"#)
        }
    }

    @Test func pullRequestsLoadByIDInSearchOrderWithoutRepeats() async throws {
        let client = client(respond: try pullRequestList())

        let pullRequests = try await client.openPullRequests(owner: "o")

        #expect(pullRequests.map(\.id) == (0...24).map { "PR_\($0)" })
        #expect(pullRequests.first?.title == "feat(contract): define query results and the agent row cap")
        // Two search pages, then 25 pull requests 10 to a request.
        #expect(StubProtocol.requests.withLock { $0.count } == 5)
    }

    @Test func pullRequestListRetriesAGatewayTimeout() async throws {
        let respond = try pullRequestList()
        let failed = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        // Every request fails once: 2 search pages and 3 loads by ID.
        let client = client { request in
            failed.withLock { $0.insert(request.body).inserted } ? .init(status: 502, body: "<html>") : respond(request)
        }

        let pullRequests = try await client.openPullRequests(owner: "o")

        #expect(pullRequests.count == 25)
        #expect(StubProtocol.requests.withLock { $0.count } == 10)
    }

    @Test func pullRequestDetailLoadsEveryPageOfCommentsReviewsAndThreads() async throws {
        @Sendable func comment(_ id: String) -> String {
            #"{"id": "\#(id)", "author": null, "body": "", "createdAt": "2026-01-01T00:00:00Z"}"#
        }
        @Sendable func thread(_ id: String) -> String {
            """
            {"id": "\(id)", "path": "a.swift", "line": 1, "startLine": null, "diffSide": "RIGHT", "startDiffSide": null,
             "isResolved": false, "isOutdated": false, "comments": {"nodes": []}}
            """
        }
        @Sendable func connection(_ nodes: [String], endCursor: String? = nil) -> String {
            let next = endCursor.map { #""\#($0)""# } ?? "null"
            return """
                {"pageInfo": {"hasNextPage": \(endCursor != nil), "endCursor": \(next)}, "nodes": [\(nodes.joined(separator: ","))]}
                """
        }
        @Sendable func page(_ connection: String) -> StubProtocol.Response {
            .init(body: #"{"data": {"repository": {"pullRequest": {"page": \#(connection)}}}}"#)
        }
        let firstPage = """
            {"data": {"repository": {"pullRequest": {
              "id": "PR_1", "body": "",
              "comments": \(connection([comment("c1")], endCursor: "comments-1")),
              "reviews": \(connection([])),
              "reviewRequests": {"nodes": []}, "commits": {"nodes": []},
              "reviewThreads": \(connection([thread("t1")], endCursor: "threads-1"))
            }}}}
            """
        let client = client { request in
            if request.body.contains(#""after":"comments-1""#) { return page(connection([comment("c2")], endCursor: "comments-2")) }
            if request.body.contains(#""after":"comments-2""#) { return page(connection([comment("c3")])) }
            if request.body.contains(#""after":"threads-1""#) { return page(connection([thread("t2")])) }
            return .init(body: firstPage)
        }

        let detail = try await client.pullRequestDetail(repository: repository, number: 1)

        #expect(detail.comments.map(\.id) == ["c1", "c2", "c3"])
        #expect(detail.reviewThreads.map(\.id) == ["t1", "t2"])
        let bodies = StubProtocol.requests.withLock { $0.map(\.body) }
        #expect(bodies.count == 4)
        #expect(bodies.filter { $0.contains("page: comments(") }.count == 2)
        #expect(bodies.filter { $0.contains("page: reviewThreads(") }.count == 1)
    }

    private let submission = ReviewSubmission(
        pullRequestID: "PR_1", commitOID: "abc", event: .comment, body: "Summary",
        threads: [
            .init(path: "a.swift", end: .init(line: 1, side: .right), body: "One"),
            .init(path: "b.swift", end: .init(line: 2, side: .right), body: "Two"),
        ],
        replies: [.init(threadID: "PRRT_1", body: "Done.")]
    )

    /// Answers the requests of `submitReview`. `pending` is the ID of the
    /// viewer's pending review. `rejected` is the body of a thread GitHub
    /// answers with a null thread.
    private func reviewResponder(
        pending: String?, rejected: String? = nil
    ) -> @Sendable (StubProtocol.Recorded) -> StubProtocol.Response {
        { request in
            func result(_ json: String) -> StubProtocol.Response { .init(body: #"{"data": {"result": \#(json)}}"#) }
            switch Self.mutation(request) {
            case "addPullRequestReviewThread":
                if let rejected, request.body.contains(#""body":"\#(rejected)""#) { return result(#"{"thread": null}"#) }
                let id = request.body.contains(#""body":"One""#) ? "PRRC_one" : "PRRC_two"
                return result(#"{"thread": {"comments": {"nodes": [{"id": "\#(id)"}]}}}"#)
            case "addPullRequestReviewThreadReply":
                return result(#"{"comment": {"id": "PRRC_reply"}}"#)
            case "addPullRequestReview", "submitPullRequestReview":
                return result(#"{"pullRequestReview": {"id": "PRR_done", "url": "https://github.com/o/r/pull/1"}}"#)
            case nil:
                let nodes = pending.map { #"{"id": "\#($0)"}"# } ?? ""
                return .init(body: #"{"data": {"node": {"reviews": {"nodes": [\#(nodes)]}}}}"#)
            default:
                return result(#"{"clientMutationId": null}"#)
            }
        }
    }

    /// The mutation a request runs. Nil for a query.
    private static func mutation(_ request: StubProtocol.Recorded) -> String? {
        request.body.firstMatch(of: /result: (\w+)\(/).map { String($0.1) }
    }

    private var mutations: [String?] { StubProtocol.requests.withLock { $0.map(Self.mutation) } }

    @Test func aReviewWithoutAPendingOneIsCreated() async throws {
        let client = client(respond: reviewResponder(pending: nil))

        let review = try await client.submitReview(submission)

        #expect(review.id == "PRR_done")
        #expect(mutations == [nil, "addPullRequestReview", "addPullRequestReviewThreadReply", "submitPullRequestReview"])
    }

    @Test func aPendingReviewGetsTheThreadsAndRepliesAndIsSubmitted() async throws {
        let client = client(respond: reviewResponder(pending: "PRR_web"))

        let review = try await client.submitReview(submission)

        #expect(review.id == "PRR_done")
        #expect(mutations == [
            nil, "addPullRequestReviewThread", "addPullRequestReviewThread", "addPullRequestReviewThreadReply",
            "submitPullRequestReview",
        ])
        let bodies = StubProtocol.requests.withLock { $0.map(\.body) }
        #expect(bodies.dropFirst().allSatisfy { $0.contains(#""pullRequestReviewId":"PRR_web""#) })
    }

    @Test func aFailedAdditionToAPendingReviewDeletesItsCommentsAndKeepsTheReview() async throws {
        let client = client(respond: reviewResponder(pending: "PRR_web", rejected: "Two"))

        await #expect(throws: GitHubError.graphQL([.init(message: "b.swift, line 2 is not part of the diff.", type: nil)])) {
            try await client.submitReview(submission)
        }
        #expect(mutations == [
            nil, "addPullRequestReviewThread", "addPullRequestReviewThread", "deletePullRequestReviewComment",
        ])
        #expect(StubProtocol.requests.withLock { $0.last?.body.contains(#""id":"PRRC_one""#) } == true)
    }

    @Test func aGatewayTimeoutThatPersistsIsThrown() async throws {
        let client = client { _ in .init(status: 502) }

        await #expect(throws: GitHubError.http(status: 502, message: "")) {
            try await client.openPullRequests(owner: "o")
        }
        #expect(StubProtocol.requests.withLock { $0.count } == 3)
    }

    @Test func concurrentCallsReadTheTokenOnce() async throws {
        let tokens = TokenCounter()
        let client = client(tokens: tokens) { _ in .init(body: "{}") }

        async let first = client.get("/a")
        async let second = client.get("/b")
        async let third = client.get("/c")
        _ = try await (first, second, third)

        #expect(await tokens.reads == 1)
        #expect(StubProtocol.requests.withLock { $0.map(\.authorization) } == Array(repeating: "Bearer token-1", count: 3))
    }

    @Test func aRejectedTokenIsReadAgain() async throws {
        let client = client { request in
            request.authorization == "Bearer token-1" ? .init(status: 401, body: #"{"message": "Bad credentials"}"#) : .init()
        }

        await #expect(throws: GitHubError.http(status: 401, message: "Bad credentials")) {
            try await client.get("/user")
        }
        _ = try await client.get("/user")

        #expect(StubProtocol.requests.withLock { $0.map(\.authorization) } == ["Bearer token-1", "Bearer token-2"])
    }

    @Test func aFailedTokenReadIsNotKept() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        StubProtocol.respond.withLock { $0 = { _ in .init() } }
        let client = GitHubClient(session: StubProtocol.session()) {
            if attempts.withLock({ $0 += 1; return $0 }) == 1 { throw GitHubError.ghNotLoggedIn(message: "") }
            return "token"
        }

        await #expect(throws: GitHubError.ghNotLoggedIn(message: "")) { try await client.get("/user") }
        _ = try await client.get("/user")
    }

    @Test func aCancelledRequestThrowsCancellationError() async throws {
        let client = client { _ in .init() }

        // The token read takes 50 ms, so the request starts after the cancellation.
        let task = Task { try await client.get("/user") }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func restReadsSkipTheCache() async throws {
        let client = client { _ in .init() }

        _ = try await client.get("/repos/o/r/actions/jobs/7")
        #expect(StubProtocol.requests.withLock { $0.map(\.cachePolicy) } == [.reloadIgnoringLocalCacheData])
    }

    @Test func aRefusedDiffIsTooLarge() async throws {
        let client = client { _ in .init(status: 406, body: #"{"message": "Sorry, the diff exceeded the maximum number of files (300)"}"#) }

        await #expect(throws: GitHubError.diffTooLarge) {
            try await client.pullRequestDiff(repository: repository, number: 1)
        }
        #expect(StubProtocol.requests.withLock { $0.map(\.path) } == ["/repos/o/r/pulls/1"])
    }

    @Test(arguments: [404, 410]) func aMissingJobLogIsUnavailable(status: Int) async throws {
        let client = client { _ in .init(status: status) }

        await #expect(throws: GitHubError.logsUnavailable) {
            try await client.jobLogs(repository: repository, jobID: 7)
        }
    }

    @Test func rerunsPostToTheJobAndTheRun() async throws {
        let client = client { _ in .init(status: 201) }

        try await client.rerunJob(repository: repository, jobID: 7)
        try await client.rerunFailedJobs(repository: repository, runID: 9)
        let sent = StubProtocol.requests.withLock { $0.map { "\($0.method) \($0.path)" } }
        #expect(sent == [
            "POST /repos/\(repository.owner)/\(repository.name)/actions/jobs/7/rerun",
            "POST /repos/\(repository.owner)/\(repository.name)/actions/runs/9/rerun-failed-jobs",
        ])
    }

    @Test func aRefusedRerunSaysWhy() async throws {
        let client = client { _ in .init(status: 403, body: #"{"message":"Resource not accessible by integration"}"#) }

        await #expect(throws: GitHubError.http(status: 403, message: "Resource not accessible by integration")) {
            try await client.rerunJob(repository: repository, jobID: 7)
        }
    }

    @Test func jobLogsDropTheByteOrderMark() async throws {
        let client = client { _ in .init(body: "\u{FEFF}2026-01-01T00:00:00Z line") }

        #expect(try await client.jobLogs(repository: repository, jobID: 7) == "2026-01-01T00:00:00Z line")
    }
}

@Suite struct SubprocessTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func outputLargerThanAPipeBufferOnBothStreamsDoesNotStall() async throws {
        let script = "head -c 300000 /dev/zero | tr '\\0' e >&2; head -c 300000 /dev/zero | tr '\\0' o; exit 3"
        let result = try await GitHubAuth.run(shell, ["-c", script])

        #expect(result.status == 3)
        #expect(result.stdout.count == 300_000)
        #expect(result.stderr.count == 300_000)
    }

    @Test func aProgramThatHangsIsKilledAtTheTimeout() async throws {
        let start = ContinuousClock.now
        let result = try await GitHubAuth.run(shell, ["-c", "trap '' TERM; exec sleep 30"], timeout: 0.3)

        #expect(result.status == SIGKILL)
        #expect(ContinuousClock.now - start < .seconds(10))
    }
}

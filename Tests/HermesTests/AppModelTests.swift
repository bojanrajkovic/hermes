import Foundation
import GitHubKit
import Testing
@testable import Hermes

/// Answers each request with the next queued GraphQL `data` object, after its delay.
private final class StubProtocol: URLProtocol {
    private static let queue = NSLock()
    nonisolated(unsafe) private static var answers: [(delay: TimeInterval, data: String)] = []

    static func enqueue(_ data: String, delay: TimeInterval = 0) {
        queue.withLock { answers.append((delay, data)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let answer = Self.queue.withLock({ Self.answers.isEmpty ? nil : Self.answers.removeFirst() }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        Thread.sleep(forTimeInterval: answer.delay)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":\#(answer.data)}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func item(_ fields: String) -> String {
    #"{"repository":{"issueOrPullRequest":\#(fields)}}"#
}

private func pullRequestJSON(_ number: Int, state: String = "OPEN", head: String = "aaa") -> String {
    """
    {"__typename":"PullRequest","id":"PR_\(number)","number":\(number),"title":"A pull request",
     "url":"https://github.com/bojan/airway/pull/\(number)","state":"\(state)","isDraft":false,
     "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","headRefName":"branch","baseRefName":"main",
     "headRefOid":"\(head)","additions":1,"deletions":1,"changedFiles":1,"mergeable":"MERGEABLE",
     "repository":{"name":"airway","owner":{"login":"bojan"}},"labels":{"nodes":[]},"commits":{"nodes":[]},
     "closingIssuesReferences":{"nodes":[]}}
    """
}

private func issueJSON(_ number: Int, state: String = "OPEN") -> String {
    """
    {"__typename":"Issue","id":"I_\(number)","number":\(number),"title":"An issue",
     "url":"https://github.com/bojan/airway/issues/\(number)","state":"\(state)",
     "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","labels":{"nodes":[]},
     "comments":{"totalCount":0},"assignees":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[]}}
    """
}

private func issuesPage(_ numbers: [Int]) -> String {
    let nodes = numbers.map { issueJSON($0) }.joined(separator: ",")
    return #"{"repository":{"issues":{"totalCount":\#(numbers.count),"pageInfo":{"hasNextPage":false,"endCursor":"c"},"nodes":[\#(nodes)]}}}"#
}

/// One suite, run in order, because the stub's queue of answers is shared.
@Suite(.serialized) @MainActor struct AppModelTests {
    private let model: AppModel

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        model = AppModel(
            client: GitHubClient(session: URLSession(configuration: configuration), token: { "token" }),
            defaults: UserDefaults(suiteName: "AppModelTests-\(UUID().uuidString)")!
        )
    }

    private func key(_ number: Int) -> ItemKey { ItemKey(repository: airway, number: number) }

    @Test func refetchReplacesAPullRequestLoadedByNumber() async {
        StubProtocol.enqueue(item(pullRequestJSON(7)))
        StubProtocol.enqueue(item(pullRequestJSON(7, state: "MERGED", head: "bbb")))

        await model.open(key(7))
        #expect(model.pullRequest(key(7))?.headOID == "aaa")

        await model.refetch(key(7))
        #expect(model.pullRequest(key(7))?.headOID == "bbb")
        #expect(model.closedState(of: key(7)) == .merged)
    }

    @Test func openIssueStaysReadableAfterItLeavesTheReloadedList() async {
        StubProtocol.enqueue(issuesPage([1, 2]))
        StubProtocol.enqueue(issuesPage([2]))
        StubProtocol.enqueue(item(issueJSON(1, state: "CLOSED")))

        await model.loadMoreIssues(of: airway)
        model.navigate(to: .issue(key(1)))
        await model.reloadIssues(of: airway)

        #expect(model.issueList(of: airway).items.map(\.number) == [2])
        #expect(model.issue(key(1)) != nil)
        for _ in 0..<100 where model.issue(key(1))?.state != .closed { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.issue(key(1))?.state == .closed)
    }

    @Test func slowOpenByNumberDoesNotOverrideLaterNavigation() async {
        StubProtocol.enqueue(item(pullRequestJSON(7)), delay: 0.2)

        let opening = Task { await model.open(key(7)) }
        for _ in 0..<100 where model.resolving == nil { try? await Task.sleep(for: .milliseconds(1)) }
        model.navigate(to: .issue(key(1)))
        #expect(model.resolving == nil)

        await opening.value
        #expect(model.destination == .issue(key(1)))
        #expect(model.pullRequest(key(7)) == nil)
    }
}

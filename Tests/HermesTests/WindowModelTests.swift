import Foundation
import GitHubKit
import TestSupport
import Testing
@testable import Hermes

@MainActor struct WindowModelTests {
    private let stub = StubHTTP()
    private let model: WindowModel

    init() {
        model = WindowModel(client: stub.client, defaults: UserDefaults(suiteName: "WindowModelTests-\(UUID().uuidString)")!)
    }

    private func key(_ number: Int) -> ItemKey { ItemKey(repository: airway, number: number) }

    @Test func refetchReplacesAPullRequestLoadedByNumber() async {
        stub.enqueue(item(pullRequestJSON(7)))
        stub.enqueue(item(pullRequestJSON(7, state: "MERGED", head: "bbb")))

        await model.open(key(7))
        #expect(model.pullRequest(key(7))?.headOID == "aaa")

        await model.refetch(key(7))
        #expect(model.pullRequest(key(7))?.headOID == "bbb")
        #expect(model.closedState(of: key(7)) == .merged)
    }

    @Test func openIssueStaysReadableAfterItLeavesTheReloadedList() async {
        stub.enqueue(issuesPage([1, 2]))
        stub.enqueue(issuesPage([2]))
        stub.enqueue(item(issueJSON(1, state: "CLOSED")))

        await model.loadMoreIssues(of: airway)
        model.navigate(to: .issue(key(1)))
        await model.reloadIssues(of: airway)

        #expect(model.listedIssues(of: airway).map(\.number) == [2])
        #expect(model.issue(key(1)) != nil)
        for _ in 0..<100 where model.issue(key(1))?.state != .closed { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.issue(key(1))?.state == .closed)
    }

    @Test func windowsOnOneAccountShareItsDataAndKeepTheirOwnPlace() async {
        stub.enqueue(item(pullRequestJSON(7)))
        let other = WindowModel(store: model.store)

        await model.open(key(7))
        // The other window sees the loaded pull request without loading it again, and stays where it was.
        #expect(other.github === model.github)
        #expect(other.pullRequest(key(7))?.number == 7)
        #expect(model.destination == .pullRequest(key(7)))
        #expect(other.destination == nil)
        #expect(model.placeURL == URL(string: "hermes://bojan/airway/pull/7"))
        #expect(other.placeURL == nil)
    }

    @Test func slowOpenByNumberDoesNotOverrideLaterNavigation() async {
        stub.enqueue(item(pullRequestJSON(7)), delay: 0.2)

        let opening = Task { await model.open(key(7)) }
        for _ in 0..<100 where model.resolving == nil { try? await Task.sleep(for: .milliseconds(1)) }
        model.navigate(to: .issue(key(1)))
        #expect(model.resolving == nil)

        await opening.value
        #expect(model.destination == .issue(key(1)))
        #expect(model.pullRequest(key(7)) == nil)
    }
}

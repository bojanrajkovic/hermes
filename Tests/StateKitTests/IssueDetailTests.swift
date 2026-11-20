import Foundation
import GitHubKit
import TestSupport
import Testing
@testable import StateKit

/// An issue's comment count has one home, its record, which the list's page and the detail both write.
@MainActor
struct IssueDetailTests {
    private let stub = StubHTTP()
    private let store: GitHubStore
    private let key = ItemKey(repository: airway, number: 1)

    init() {
        store = GitHubStore(client: stub.client)
    }

    private func detail(comments: Int) -> String {
        #"{"repository":{"issue":{"body":"Body","comments":{"totalCount":\#(comments),"nodes":[]}}}}"#
    }

    @Test func theDetailUpdatesTheRecordsCommentCount() async {
        store.store(.issue(issue(1, title: "An issue")), for: key)
        stub.enqueue(detail(comments: 3))

        await store.loadIssueDetailIfStale(key)

        #expect(store.issue(key)?.commentCount == 3)
        #expect(store.issueDetails[key]?.body == "Body")
    }

    @Test func theDetailLoadsAgainOnlyWhenTheIssueChanged() async {
        store.store(.issue(issue(1, title: "An issue")), for: key)
        stub.enqueue(detail(comments: 0))
        await store.loadIssueDetailIfStale(key)

        // Nothing is queued, so a second load would fail and leave an error.
        await store.loadIssueDetailIfStale(key)
        #expect(store.issueDetailErrors[key] == nil)
    }
}

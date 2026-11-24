import Foundation
import GitHubKit
import TestSupport
import Testing
@testable import StateKit

/// A comment sent outside a review shows in the loaded conversation once, whichever of the
/// answer, a webhook, or a reload brings it first.
@MainActor
struct CommentTests {
    private let stub = StubHTTP()
    private let store: GitHubStore
    private let key = ItemKey(repository: airway, number: 1)

    init() {
        store = GitHubStore(client: stub.client)
    }

    private let added = #"{"addComment":{"commentEdge":{"node":{"id":"IC_9","databaseId":9,"author":null,"body":"Looks good","createdAt":"2026-11-23T12:00:00Z"}}}}"#

    private func comment(_ id: String) -> GitHubKit.Comment {
        GitHubKit.Comment(id: id, databaseID: 1, author: nil, body: "Earlier", createdAt: .now)
    }

    @Test func aPullRequestCommentJoinsTheConversation() async throws {
        store.details[key] = PullRequestDetail(
            id: "PR_1", body: "", comments: [comment("IC_1")], reviews: [], requestedReviewers: [], commits: [], reviewThreads: []
        )
        stub.enqueue(added)

        try await store.addComment("Looks good", subjectID: "PR_1", to: key)

        #expect(store.details[key]?.comments.map(\.id) == ["IC_1", "IC_9"])
        #expect(store.details[key]?.comments.last?.body == "Looks good")
    }

    @Test func anIssueCommentJoinsTheConversationAndTheCount() async throws {
        store.store(.issue(issue(1, title: "An issue")), for: key)
        store.issueDetails[key] = IssueDetail(body: "Body", comments: [comment("IC_1")])
        let count = store.issue(key)?.commentCount ?? 0
        stub.enqueue(added)

        try await store.addComment("Looks good", subjectID: "I_1", to: key)

        #expect(store.issueDetails[key]?.comments.map(\.id) == ["IC_1", "IC_9"])
        #expect(store.issue(key)?.commentCount == count + 1)
    }

    @Test func anIssueCommentAlreadyLoadedIsNotAddedOrCountedAgain() async throws {
        store.store(.issue(issue(1, title: "An issue")), for: key)
        store.issueDetails[key] = IssueDetail(body: "Body", comments: [comment("IC_9")])
        let count = store.issue(key)?.commentCount ?? 0
        stub.enqueue(added)

        try await store.addComment("Looks good", subjectID: "I_1", to: key)

        #expect(store.issueDetails[key]?.comments.map(\.id) == ["IC_9"])
        #expect(store.issue(key)?.commentCount == count)
    }

    @Test func aRefusedCommentChangesNothing() async {
        store.issueDetails[key] = IssueDetail(body: "Body", comments: [])
        stub.enqueue(#"null, "errors":[{"message":"Unable to create comment because issue is locked."}]"#)

        await #expect(throws: GitHubError.self) {
            try await store.addComment("Looks good", subjectID: "I_1", to: key)
        }
        #expect(store.issueDetails[key]?.comments.isEmpty == true)
    }
}

import Foundation
import Testing
@testable import GitHubKit

// Testing has a Comment too.
private typealias Comment = GitHubKit.Comment

private func comment(_ databaseID: Int, _ body: String = "A comment") -> Comment {
    Comment(id: "PRRC_\(databaseID)", databaseID: databaseID, author: nil, body: body, createdAt: .distantPast)
}

private func thread(_ id: String, resolved: Bool = false, _ comments: [Comment]) -> ReviewThread {
    ReviewThread(
        id: id, path: "docs/README.md", line: 26, startLine: nil, diffSide: .right, startDiffSide: nil,
        isResolved: resolved, isOutdated: false, comments: comments
    )
}

/// A `pull_request_review_comment` delivery about pull request 7 of `acme/site`.
private func commentDelivery(action: String, replyingTo parent: Int?) -> Data {
    let comment: [String: Any] = [
        "id": 12, "node_id": "PRRC_12", "in_reply_to_id": parent ?? NSNull(), "user": NSNull(),
        "body": "A line comment", "created_at": "2026-11-15T22:13:02Z", "path": "docs/README.md", "line": 26,
    ]
    let delivery: [String: Any] = [
        "action": action, "comment": comment, "pull_request": ["number": 7],
        "repository": ["name": "site", "owner": ["login": "acme"]],
    ]
    return (try? JSONSerialization.data(withJSONObject: delivery)) ?? Data()
}

struct WebhookThreadTests {
    // MARK: Reading

    @Test func aRealReplyNamesTheCommentItAnswers() throws {
        let event = try #require(WebhookEvent(payload: try fixture("webhook_review_comment_reply")))
        guard case .reply(let comment, let parent)? = event.change else {
            Issue.record("no reply read")
            return
        }

        #expect(event.pullRequest == 53)
        #expect(parent == 4_580_468_011)
        #expect((comment.id, comment.databaseID, comment.body) == ("PRRC_kwDOVqHLzs8AAAABEQRlhA", 4_580_468_100, "Capture test: reply."))
        #expect(comment.author?.login == "bojanrajkovic")
    }

    @Test func aRealResolvedThreadIsNamedByItsGraphQLID() throws {
        let event = try #require(WebhookEvent(payload: try fixture("webhook_review_thread_resolved")))

        #expect(event.pullRequest == 53)
        #expect(event.change == .threadResolved(id: "PRRT_kwDOVqHLzs63uant", resolved: true))
    }

    @Test func aLineCommentThePayloadCannotPlaceLoadsTheThreads() {
        // A new thread's ID is not in the payload.
        #expect(WebhookEvent(payload: commentDelivery(action: "created", replyingTo: nil))?.change == .threads)
        // An edited or deleted comment could be any comment of any thread, loaded or not.
        #expect(WebhookEvent(payload: commentDelivery(action: "edited", replyingTo: 11))?.change == .threads)
        #expect(WebhookEvent(payload: commentDelivery(action: "deleted", replyingTo: 11))?.change == .threads)
    }

    // MARK: Applying

    private let threads = [thread("T1", [comment(10), comment(11)]), thread("T2", [comment(20)])]

    @Test func aReplyJoinsTheThreadThatHoldsTheCommentItAnswers() {
        let changed = ReviewThread.applying(.reply(comment(12, "A reply"), to: 10), to: threads)

        #expect(changed?.map(\.id) == ["T1", "T2"])
        #expect(changed?[0].comments.map(\.databaseID) == [10, 11, 12])
        #expect(changed?[1] == threads[1])
    }

    @Test func aReplyAlreadyInItsThreadIsNotAddedTwice() {
        #expect(ReviewThread.applying(.reply(comment(11), to: 10), to: threads) == threads)
    }

    @Test func aReplyToACommentThatIsNotLoadedLoadsTheThreads() {
        #expect(ReviewThread.applying(.reply(comment(12), to: 99), to: threads) == nil)
        #expect(ReviewThread.applying(.reply(comment(12), to: 10), to: []) == nil)
    }

    @Test func resolvingAndReopeningChangeOnlyTheNamedThread() {
        let resolved = ReviewThread.applying(.threadResolved(id: "T2", resolved: true), to: threads)
        #expect(resolved?.map(\.isResolved) == [false, true])
        #expect(resolved?[1].comments == threads[1].comments)

        let reopened = resolved.flatMap { ReviewThread.applying(.threadResolved(id: "T2", resolved: false), to: $0) }
        #expect(reopened == threads)
    }

    @Test func aChangeToAThreadThatIsNotLoadedLoadsTheThreads() {
        #expect(ReviewThread.applying(.threadResolved(id: "T9", resolved: true), to: threads) == nil)
    }

    @Test func aChangeThatIsNotAboutOneThreadLoadsTheThreads() {
        #expect(ReviewThread.applying(.threads, to: threads) == nil)
        #expect(ReviewThread.applying(.comment(comment(10), deleted: false), to: threads) == nil)
    }
}

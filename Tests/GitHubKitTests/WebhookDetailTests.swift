import Foundation
import Testing
@testable import GitHubKit

private func delivery(_ body: [String: Any]) -> Data {
    let repository: [String: Any] = ["name": "site", "owner": ["login": "acme"]]
    return (try? JSONSerialization.data(withJSONObject: body.merging(["repository": repository]) { old, _ in old })) ?? Data()
}

// Testing has a Comment too.
private typealias Comment = GitHubKit.Comment

private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text) ?? .distantPast
}

private func author(_ login: String, type: String = "User") -> [String: Any] {
    ["login": login, "avatar_url": "https://example.com/\(login).png", "type": type]
}

private func comment(_ id: String, _ body: String = "A comment") -> Comment {
    Comment(
        id: id, databaseID: 1, author: User(login: "octocat", avatarURL: URL(string: "https://example.com/a.png")!, isBot: false),
        body: body, createdAt: .distantPast
    )
}

private func detail(comments: [Comment] = [], reviews: [Review] = []) -> PullRequestDetail {
    PullRequestDetail(
        id: "PR_7", body: "The description", comments: comments, reviews: reviews, requestedReviewers: [],
        commits: [Commit(oid: "abc", headline: "A commit")], reviewThreads: []
    )
}

struct WebhookDetailTests {
    // MARK: Reading

    @Test func aRealConversationCommentIsRead() throws {
        let event = try #require(WebhookEvent(payload: try fixture("webhook_issue_comment_created")))

        #expect(event.pullRequest == 53)
        #expect(event.change == .comment(
            Comment(
                id: "IC_kwDOVqHLzs8AAAABm2eE3A", databaseID: 6_902_219_996,
                author: User(
                    login: "bojanrajkovic", avatarURL: URL(string: "https://avatars.githubusercontent.com/u/110747?v=4")!,
                    isBot: false
                ),
                body: "Capture test: PR comment.", createdAt: date("2026-11-15T22:12:59Z")
            ),
            deleted: false
        ))
    }

    @Test func aRealReviewWithOnlyLineCommentsIsRead() throws {
        // GitHub sends this for every line comment: a null body and a lowercase state.
        let event = try #require(WebhookEvent(payload: try fixture("webhook_pull_request_review_submitted")))
        guard case .review(let review)? = event.change else {
            Issue.record("no review read")
            return
        }

        #expect(event.pullRequest == 53)
        #expect(review.id == "PRR_kwDOVqHLzs8AAAABYHQnkg")
        #expect(review.state == .commented)
        #expect(review.body.isEmpty)
        #expect(review.submittedAt == date("2026-11-15T22:13:00Z"))
        #expect(review.author?.login == "bojanrajkovic")
    }

    @Test(arguments: [("approved", Review.State.approved), ("changes_requested", .changesRequested), ("dismissed", .dismissed)])
    func aReviewsStateIsRead(state: String, expected: Review.State) {
        let change = WebhookEvent(payload: delivery([
            "action": "submitted", "pull_request": ["number": 7],
            "review": ["node_id": "PRR_1", "user": author("hubot"), "body": "Looks right.", "state": state, "submitted_at": "2026-11-15T22:13:00Z"],
        ]))?.change

        #expect(change == .review(Review(
            id: "PRR_1", author: User(login: "hubot", avatarURL: URL(string: "https://example.com/hubot.png")!, isBot: false),
            state: expected, body: "Looks right.", submittedAt: date("2026-11-15T22:13:00Z")
        )))
    }

    private func commentDelivery(action: String, issue: [String: Any], user: Any = author("octocat")) -> Data {
        delivery([
            "action": action, "issue": issue,
            "comment": ["id": 9, "node_id": "IC_9", "user": user, "body": "Hello", "created_at": "2026-11-15T22:12:59Z"],
        ])
    }

    @Test func aDeletedCommentIsReadAsDeleted() {
        let issue: [String: Any] = ["number": 7, "pull_request": ["url": "u"]]
        guard case .comment(let comment, let deleted)? = WebhookEvent(payload: commentDelivery(action: "deleted", issue: issue))?.change else {
            Issue.record("no comment read")
            return
        }
        #expect(deleted)
        #expect(comment.id == "IC_9")
    }

    @Test func aCommentOnAnIssueThatIsNoPullRequestIsNotRead() {
        let event = WebhookEvent(payload: commentDelivery(action: "created", issue: ["number": 8]))

        #expect(event?.pullRequest == nil)
        #expect(event?.change == nil)
    }

    @Test func aBotIsNamedAsGraphQLNamesItAndADeletedAccountHasNoAuthor() {
        let issue: [String: Any] = ["number": 7, "pull_request": ["url": "u"]]
        func commentAuthor(of user: Any) -> User? {
            guard case .comment(let comment, _)? = WebhookEvent(payload: commentDelivery(action: "created", issue: issue, user: user))?.change else {
                Issue.record("no comment read")
                return nil
            }
            return comment.author
        }

        let bot = commentAuthor(of: author("renovate[bot]", type: "Bot"))
        #expect(bot?.login == "renovate")
        #expect(bot?.isBot == true)
        #expect(commentAuthor(of: NSNull()) == nil)
    }

    // MARK: Applying

    @Test func aNewCommentJoinsTheEndOfTheConversation() {
        let new = detail(comments: [comment("IC_1")]).applying(.comment(comment("IC_2"), deleted: false))

        #expect(new?.comments.map(\.id) == ["IC_1", "IC_2"])
    }

    @Test func anEditedCommentReplacesItsCopyInPlace() {
        let old = detail(comments: [comment("IC_1"), comment("IC_2"), comment("IC_3")])
        let new = old.applying(.comment(comment("IC_2", "Edited"), deleted: false))

        #expect(new?.comments.map(\.body) == ["A comment", "Edited", "A comment"])
    }

    @Test func aDeletedCommentLeavesAndOneNotHeldChangesNothing() {
        let old = detail(comments: [comment("IC_1"), comment("IC_2")])

        #expect(old.applying(.comment(comment("IC_1"), deleted: true))?.comments.map(\.id) == ["IC_2"])
        #expect(old.applying(.comment(comment("IC_9"), deleted: true)) == old)
    }

    @Test func aReviewJoinsTheReviewsAndADismissalReplacesItsCopy() {
        let approved = Review(id: "PRR_1", author: nil, state: .approved, body: "Good", submittedAt: .distantPast)
        let dismissed = Review(id: "PRR_1", author: nil, state: .dismissed, body: "Good", submittedAt: .distantPast)

        let submitted = detail().applying(.review(approved))
        #expect(submitted?.reviews == [approved])
        #expect(submitted?.applying(.review(dismissed))?.reviews == [dismissed])
    }

    private func fields(body: String = "The description", requestedReviewers: [RequestedReviewer] = []) -> PullRequestFields {
        PullRequestFields(
            title: "T", body: body, state: .open, isDraft: false, labels: [], headOID: "abc",
            headRefName: "head", baseRefName: "main", additions: 1, deletions: 1, changedFileCount: 1,
            autoMergeMethod: nil, requestedReviewers: requestedReviewers, updatedAt: .distantPast
        )
    }

    @Test func anEditedDescriptionReplacesTheBodyAndKeepsTheRest() throws {
        let old = detail(comments: [comment("IC_1")])
        let new = try #require(old.applying(.pullRequest(fields(body: "A new description"), reloads: false)))

        #expect(new.body == "A new description")
        #expect((new.id, new.comments, new.commits) == (old.id, old.comments, old.commits))
    }

    @Test func aReviewRequestReplacesTheRequestedReviewers() throws {
        let asked: [RequestedReviewer] = [.user(User(login: "hubot", avatarURL: URL(string: "https://example.com/h.png")!, isBot: false))]
        let requested = try #require(detail().applying(.pullRequest(fields(requestedReviewers: asked), reloads: false)))
        #expect(requested.requestedReviewers == asked)

        // `review_request_removed` carries the reviewers that are left.
        let removed = try #require(requested.applying(.pullRequest(fields(), reloads: false)))
        #expect(removed.requestedReviewers.isEmpty)
    }

    // MARK: Counting

    @Test func oneChangeSinceTheLastLookIsAppliedAndMoreThanOneIsNot() {
        var changes = WebhookChanges()
        let first = WebhookChange.comment(comment("IC_1"), deleted: false)
        let second = WebhookChange.comment(comment("IC_2"), deleted: false)

        changes.note(first)
        #expect(changes.only(since: 0) == first)

        // Two came before the screen looked again. The first is gone, so the part has to load.
        changes.note(second)
        #expect(changes.only(since: 0) == nil)
        #expect(changes.only(since: 1) == second)

        // A delivery whose payload could not be applied.
        changes.note(nil)
        #expect(changes.only(since: 2) == nil)
    }
}

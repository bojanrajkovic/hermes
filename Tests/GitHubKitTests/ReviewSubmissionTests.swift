import Foundation
import Testing
@testable import GitHubKit

@Suite struct ReviewSubmissionTests {
    private let threads = [
        ReviewSubmission.Thread(path: "a.swift", end: .init(line: 12, side: .right), body: "Rename this."),
        ReviewSubmission.Thread(
            path: "b.swift", start: .init(line: 3, side: .left), end: .init(line: 5, side: .right), body: "Why?"
        ),
    ]
    private let replies = [
        ReviewSubmission.Reply(threadID: "PRRT_1", body: "Done."),
        ReviewSubmission.Reply(threadID: "PRRT_2", body: "Agreed."),
    ]

    private func submission(
        event: ReviewSubmission.Event = .requestChanges, body: String = "Two things.", replies: [ReviewSubmission.Reply] = []
    ) -> ReviewSubmission {
        ReviewSubmission(
            pullRequestID: "PR_1", commitOID: "abc123", event: event, body: body, threads: threads, replies: replies
        )
    }

    private let threadInputs: JSONValue = [
        ["path": "a.swift", "line": 12, "side": "RIGHT", "body": "Rename this."],
        ["path": "b.swift", "line": 5, "side": "RIGHT", "startLine": 3, "startSide": "LEFT", "body": "Why?"],
    ]

    @Test func withoutRepliesOneRequestCreatesAndSubmits() {
        let request = submission().createRequest

        #expect(request.query.contains("addPullRequestReview(input: $input)"))
        #expect(request.query.contains("$input: AddPullRequestReviewInput!"))
        #expect(request.variables == ["input": [
            "pullRequestId": "PR_1",
            "commitOID": "abc123",
            "event": "REQUEST_CHANGES",
            "body": "Two things.",
            "threads": threadInputs,
        ]])
    }

    @Test func anEmptySummaryIsLeftOut() {
        #expect(submission(event: .approve, body: "").createRequest.variables == ["input": [
            "pullRequestId": "PR_1",
            "commitOID": "abc123",
            "event": "APPROVE",
            "threads": threadInputs,
        ]])
    }

    @Test func withRepliesTheReviewIsCreatedPending() {
        // No event leaves the review pending; the summary goes on the submit request.
        #expect(submission(replies: replies).createRequest.variables == ["input": [
            "pullRequestId": "PR_1",
            "commitOID": "abc123",
            "threads": threadInputs,
        ]])
    }

    @Test func eachReplyIsAddedToThePendingReview() {
        let requests = submission(replies: replies).replyRequests(reviewID: "PRR_9")

        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.query.contains("addPullRequestReviewThreadReply(input: $input)") })
        #expect(requests.map(\.variables) == [
            ["input": ["pullRequestReviewId": "PRR_9", "pullRequestReviewThreadId": "PRRT_1", "body": "Done."]],
            ["input": ["pullRequestReviewId": "PRR_9", "pullRequestReviewThreadId": "PRRT_2", "body": "Agreed."]],
        ])
    }

    @Test func submitCarriesTheEventAndSummary() {
        let request = submission(event: .comment, replies: replies).submitRequest(reviewID: "PRR_9")

        #expect(request.query.contains("submitPullRequestReview(input: $input)"))
        #expect(request.variables == ["input": [
            "pullRequestReviewId": "PRR_9", "event": "COMMENT", "body": "Two things.",
        ]])
    }

    @Test func deleteNamesThePendingReview() {
        let request = ReviewSubmission.deleteRequest(reviewID: "PRR_9")

        #expect(request.query.contains("deletePullRequestReview(input: $input)"))
        #expect(request.variables == ["input": ["pullRequestReviewId": "PRR_9"]])
    }

    @Test func requestEncodesAsAGraphQLBody() throws {
        let data = try JSONEncoder().encode(submission(event: .approve, body: "").createRequest)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variables = try #require(body["variables"] as? [String: Any])
        let input = try #require(variables["input"] as? [String: Any])
        let firstThread = try #require((input["threads"] as? [[String: Any]])?.first)

        #expect(body["query"] is String)
        #expect(input["event"] as? String == "APPROVE")
        #expect(firstThread["line"] as? Int == 12)
        #expect(firstThread["startLine"] == nil)
    }
}

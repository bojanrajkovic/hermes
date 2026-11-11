import Foundation

/// A whole review, sent to GitHub as one batch: a verdict, a summary, new
/// threads, and replies to existing threads.
public struct ReviewSubmission: Sendable, Hashable {
    public enum Event: String, Sendable, Hashable {
        case comment = "COMMENT"
        case approve = "APPROVE"
        case requestChanges = "REQUEST_CHANGES"
    }

    /// A line in the diff.
    public struct Position: Sendable, Hashable {
        /// The line number in the file: the base version for `.left`, the
        /// head version for `.right`.
        public let line: Int
        public let side: DiffSide

        public init(line: Int, side: DiffSide) {
            self.line = line
            self.side = side
        }
    }

    /// A new comment thread on a line or a range of lines.
    public struct Thread: Sendable, Hashable {
        /// The file's path in the repository.
        public let path: String
        /// The first line of a multi-line comment. Nil for a single line.
        public let start: Position?
        /// The line the comment is on, or the last line of a multi-line comment.
        public let end: Position
        /// Markdown.
        public let body: String

        public init(path: String, start: Position? = nil, end: Position, body: String) {
            self.path = path
            self.start = start
            self.end = end
            self.body = body
        }
    }

    /// A reply to an existing thread.
    public struct Reply: Sendable, Hashable {
        /// `ReviewThread.id` of the thread to reply to.
        public let threadID: String
        /// Markdown.
        public let body: String

        public init(threadID: String, body: String) {
            self.threadID = threadID
            self.body = body
        }
    }

    /// `PullRequest.id` of the pull request to review.
    public let pullRequestID: String
    /// The head commit the review was written against.
    public let commitOID: String
    public let event: Event
    /// The summary, as Markdown. May be empty.
    public let body: String
    public let threads: [Thread]
    public let replies: [Reply]

    public init(
        pullRequestID: String, commitOID: String, event: Event, body: String,
        threads: [Thread] = [], replies: [Reply] = []
    ) {
        self.pullRequestID = pullRequestID
        self.commitOID = commitOID
        self.event = event
        self.body = body
        self.threads = threads
        self.replies = replies
    }
}

/// A review on GitHub, as returned after submitting.
public struct SubmittedReview: Sendable, Hashable, Decodable {
    /// The GraphQL node ID.
    public let id: String
    public let url: URL

    public init(id: String, url: URL) {
        self.id = id
        self.url = url
    }
}

// MARK: Requests

// GitHub's `addPullRequestReview` cannot reply to existing threads. So a
// submission with replies takes three steps: create the review as pending
// (no event), add each reply to it, then submit it. Without replies, one
// request creates and submits.
//
// GitHub allows a user one pending review on a pull request, and rejects
// `addPullRequestReview` while there is one. So when the viewer has a pending
// review, the threads and replies are added to it, and it is submitted.
extension ReviewSubmission {
    private static let reviewSelection = "{ pullRequestReview { id url } }"

    /// Reads the viewer's pending review on the pull request. Nobody else's
    /// pending review is visible.
    var pendingReviewRequest: GraphQLRequest {
        GraphQLRequest(
            query: "query($id: ID!) { node(id: $id) { ... on PullRequest { reviews(states: PENDING, first: 1) { nodes { id } } } } }",
            variables: ["id": .string(pullRequestID)]
        )
    }

    /// Creates the review with its new threads. The review is submitted right
    /// away when there are no replies, and left pending otherwise.
    var createRequest: GraphQLRequest {
        var input: [String: JSONValue] = [
            "pullRequestId": .string(pullRequestID),
            "commitOID": .string(commitOID),
            "threads": .array(threads.map { .object($0.input) }),
        ]
        if replies.isEmpty {
            input["event"] = .string(event.rawValue)
            if !body.isEmpty { input["body"] = .string(body) }
        }
        return GraphQLRequest(
            query: "mutation($input: AddPullRequestReviewInput!) { result: addPullRequestReview(input: $input) \(Self.reviewSelection) }",
            variables: ["input": .object(input)]
        )
    }

    /// Adds each new thread to the pending review `reviewID`, in the order of `threads`.
    func threadRequests(reviewID: String) -> [GraphQLRequest] {
        threads.map { thread in
            var input = thread.input
            input["pullRequestReviewId"] = .string(reviewID)
            return GraphQLRequest(
                query: "mutation($input: AddPullRequestReviewThreadInput!) { result: addPullRequestReviewThread(input: $input) { thread { comments(first: 1) { nodes { id } } } } }",
                variables: ["input": .object(input)]
            )
        }
    }

    /// Adds each reply to the pending review `reviewID`.
    func replyRequests(reviewID: String) -> [GraphQLRequest] {
        replies.map { reply in
            GraphQLRequest(
                query: "mutation($input: AddPullRequestReviewThreadReplyInput!) { result: addPullRequestReviewThreadReply(input: $input) { comment { id } } }",
                variables: ["input": [
                    "pullRequestReviewId": .string(reviewID),
                    "pullRequestReviewThreadId": .string(reply.threadID),
                    "body": .string(reply.body),
                ]]
            )
        }
    }

    /// Submits the pending review `reviewID` with the event and summary.
    func submitRequest(reviewID: String) -> GraphQLRequest {
        var input: [String: JSONValue] = [
            "pullRequestReviewId": .string(reviewID),
            "event": .string(event.rawValue),
        ]
        if !body.isEmpty { input["body"] = .string(body) }
        return GraphQLRequest(
            query: "mutation($input: SubmitPullRequestReviewInput!) { result: submitPullRequestReview(input: $input) \(Self.reviewSelection) }",
            variables: ["input": .object(input)]
        )
    }

    /// Deletes the pending review `reviewID`.
    static func deleteRequest(reviewID: String) -> GraphQLRequest {
        GraphQLRequest(
            query: "mutation($input: DeletePullRequestReviewInput!) { result: deletePullRequestReview(input: $input) { clientMutationId } }",
            variables: ["input": ["pullRequestReviewId": .string(reviewID)]]
        )
    }

    /// Deletes the review comment `commentID`.
    static func deleteCommentRequest(commentID: String) -> GraphQLRequest {
        GraphQLRequest(
            query: "mutation($input: DeletePullRequestReviewCommentInput!) { result: deletePullRequestReviewComment(input: $input) { clientMutationId } }",
            variables: ["input": ["id": .string(commentID)]]
        )
    }
}

extension ReviewSubmission.Thread {
    fileprivate var input: [String: JSONValue] {
        var input: [String: JSONValue] = [
            "path": .string(path),
            "line": .int(end.line),
            "side": .string(end.side.rawValue),
            "body": .string(body),
        ]
        if let start {
            input["startLine"] = .int(start.line)
            input["startSide"] = .string(start.side.rawValue)
        }
        return input
    }
}

// MARK: Responses

private struct Mutation<Result: Decodable & Sendable>: Decodable, Sendable { let result: Result }
private struct ReviewResult: Decodable, Sendable { let pullRequestReview: SubmittedReview }
private struct ThreadResult: Decodable, Sendable {
    struct Thread: Decodable, Sendable { let comments: Connection<NodeID> }
    let thread: Thread?
}
private struct ReplyResult: Decodable, Sendable { let comment: NodeID? }
private struct Acknowledged: Decodable, Sendable {}
private struct PendingReviewData: Decodable, Sendable {
    struct PullRequest: Decodable, Sendable { let reviews: Connection<NodeID> }
    let node: PullRequest
}

extension GitHubClient {
    /// Submits a review with all its threads and replies.
    ///
    /// When the viewer has a pending review on the pull request, started on
    /// github.com or left by a submission that did not finish, the threads
    /// and replies are added to it and it is submitted with them.
    ///
    /// When a step fails, what the submission added is deleted, so that a
    /// retry does not post it twice: the half-built review, or the comments
    /// added to a pending review that was already there.
    ///
    /// - Throws: `GitHubError.graphQL` when GitHub rejects the review: a line
    ///   outside the diff, a commit that is no longer the head, or an empty
    ///   comment review. Other `GitHubError` cases as for any request.
    public func submitReview(_ submission: ReviewSubmission) async throws -> SubmittedReview {
        let pending = try await (run(submission.pendingReviewRequest) as PendingReviewData).node.reviews.nodes.first
        if let pending { return try await submitReview(submission, addingTo: pending.id) }

        let created = try await (run(submission.createRequest) as Mutation<ReviewResult>).result.pullRequestReview
        guard !submission.replies.isEmpty else { return created }

        do {
            for request in submission.replyRequests(reviewID: created.id) {
                _ = try await run(request) as Acknowledged
            }
            return try await (run(submission.submitRequest(reviewID: created.id)) as Mutation<ReviewResult>)
                .result.pullRequestReview
        } catch {
            // A new task, so the cleanup still runs when this one was cancelled.
            await Task {
                _ = try? await run(ReviewSubmission.deleteRequest(reviewID: created.id)) as Acknowledged
            }.value
            throw error
        }
    }

    /// Adds the submission's threads and replies to the pending review
    /// `reviewID` and submits it. The review itself is never deleted: it may
    /// hold comments the user drafted on github.com.
    private func submitReview(_ submission: ReviewSubmission, addingTo reviewID: String) async throws -> SubmittedReview {
        var added: [String] = []
        do {
            for (thread, request) in zip(submission.threads, submission.threadRequests(reviewID: reviewID)) {
                // GitHub answers a line outside the diff with a null thread and no error.
                guard let comment = try await (run(request) as Mutation<ThreadResult>).result.thread?.comments.nodes.first
                else {
                    throw GitHubError.graphQL([
                        GraphQLError(message: "\(thread.path), line \(thread.end.line) is not part of the diff.", type: nil),
                    ])
                }
                added.append(comment.id)
            }
            for request in submission.replyRequests(reviewID: reviewID) {
                if let comment = try await (run(request) as Mutation<ReplyResult>).result.comment { added.append(comment.id) }
            }
            return try await (run(submission.submitRequest(reviewID: reviewID)) as Mutation<ReviewResult>)
                .result.pullRequestReview
        } catch {
            // A new task, so the cleanup still runs when this one was cancelled.
            await Task { [added] in
                for id in added {
                    _ = try? await run(ReviewSubmission.deleteCommentRequest(commentID: id)) as Acknowledged
                }
            }.value
            throw error
        }
    }
}


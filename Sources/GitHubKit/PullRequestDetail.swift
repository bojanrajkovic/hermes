import Foundation

/// The side of a diff a line is on.
public enum DiffSide: String, Sendable, Hashable, Decodable {
    /// The base version: deleted lines.
    case left = "LEFT"
    /// The head version: added and unchanged lines.
    case right = "RIGHT"
}

/// A submitted or pending review.
public struct Review: Sendable, Hashable, Identifiable, Decodable {
    public enum State: String, Sendable, Hashable, Decodable {
        /// Started but not submitted. Only its author sees it.
        case pending = "PENDING"
        case commented = "COMMENTED"
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case dismissed = "DISMISSED"
    }

    /// The GraphQL node ID.
    public let id: String
    /// Nil when the author's account was deleted.
    public let author: User?
    public let state: State
    /// The summary, as Markdown. Empty when the review has only line comments.
    public let body: String
    /// Nil while the review is pending.
    public let submittedAt: Date?

    public init(id: String, author: User?, state: State, body: String, submittedAt: Date?) {
        self.id = id
        self.author = author
        self.state = state
        self.body = body
        self.submittedAt = submittedAt
    }
}

/// Someone asked to review a pull request.
public enum RequestedReviewer: Sendable, Hashable {
    case user(User)
    case team(name: String, slug: String)
}

extension RequestedReviewer: Decodable {
    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name, slug
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .typename) == "Team" {
            self = .team(
                name: try container.decode(String.self, forKey: .name),
                slug: try container.decode(String.self, forKey: .slug)
            )
        } else {
            self = .user(try User(from: decoder))
        }
    }
}

/// A commit on a pull request.
public struct Commit: Sendable, Hashable, Identifiable {
    /// The commit's SHA.
    public let oid: String
    /// The first line of the commit message.
    public let headline: String

    public var id: String { oid }

    public init(oid: String, headline: String) {
        self.oid = oid
        self.headline = headline
    }
}

extension Commit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case oid
        case headline = "messageHeadline"
    }
}

/// A thread of review comments on one place in the diff.
public struct ReviewThread: Sendable, Hashable, Identifiable {
    /// The GraphQL node ID. Replies are addressed to it.
    public let id: String
    /// The file's path in the repository.
    public let path: String
    /// The line the thread ends on, in the current diff. Nil when the thread
    /// is outdated and its line is no longer part of the diff.
    public let line: Int?
    /// The first line of a multi-line thread. Nil for a single-line thread.
    public let startLine: Int?
    /// The side `line` is on.
    public let diffSide: DiffSide
    /// The side `startLine` is on. Nil for a single-line thread.
    public let startDiffSide: DiffSide?
    public let isResolved: Bool
    /// True when a later commit changed the lines the thread is on.
    public let isOutdated: Bool
    /// Oldest first.
    public let comments: [Comment]

    public init(
        id: String, path: String, line: Int?, startLine: Int?, diffSide: DiffSide, startDiffSide: DiffSide?,
        isResolved: Bool, isOutdated: Bool, comments: [Comment]
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.startLine = startLine
        self.diffSide = diffSide
        self.startDiffSide = startDiffSide
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.comments = comments
    }
}

extension ReviewThread: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, path, line, startLine, diffSide, startDiffSide, isResolved, isOutdated, comments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        startLine = try container.decodeIfPresent(Int.self, forKey: .startLine)
        diffSide = try container.decode(DiffSide.self, forKey: .diffSide)
        startDiffSide = try container.decodeIfPresent(DiffSide.self, forKey: .startDiffSide)
        isResolved = try container.decode(Bool.self, forKey: .isResolved)
        isOutdated = try container.decode(Bool.self, forKey: .isOutdated)
        comments = try container.decode(Connection<Comment>.self, forKey: .comments).nodes
    }
}

/// A pull request's description, conversation, reviews, and commits.
public struct PullRequestDetail: Sendable, Hashable, Identifiable {
    /// The GraphQL node ID. `ReviewSubmission` needs it.
    public let id: String
    /// Markdown.
    public let body: String
    /// Conversation comments, oldest first. Review comments are in `reviewThreads`.
    public let comments: [Comment]
    /// Oldest first.
    public let reviews: [Review]
    public let requestedReviewers: [RequestedReviewer]
    /// Oldest first.
    public let commits: [Commit]
    public let reviewThreads: [ReviewThread]

    public init(
        id: String, body: String, comments: [Comment], reviews: [Review],
        requestedReviewers: [RequestedReviewer], commits: [Commit], reviewThreads: [ReviewThread]
    ) {
        self.id = id
        self.body = body
        self.comments = comments
        self.reviews = reviews
        self.requestedReviewers = requestedReviewers
        self.commits = commits
        self.reviewThreads = reviewThreads
    }
}

extension PullRequestDetail: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, body, comments, reviews, reviewRequests, commits, reviewThreads
    }

    // Null when the requested reviewer is a team the viewer cannot see.
    private struct Request: Decodable { let requestedReviewer: RequestedReviewer? }
    private struct CommitNode: Decodable { let commit: Commit }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        comments = try container.decode(Connection<Comment>.self, forKey: .comments).nodes
        reviews = try container.decode(Connection<Review>.self, forKey: .reviews).nodes
        requestedReviewers = try container.decode(Connection<Request>.self, forKey: .reviewRequests)
            .nodes.compactMap(\.requestedReviewer)
        commits = try container.decode(Connection<CommitNode>.self, forKey: .commits).nodes.map(\.commit)
        reviewThreads = try container.decode(Connection<ReviewThread>.self, forKey: .reviewThreads).nodes
    }
}

/// What changes when someone pushes to or edits a pull request.
public struct PullRequestRevision: Sendable, Hashable, Decodable {
    /// The head commit's SHA.
    public let headOID: String
    public let updatedAt: Date

    public init(headOID: String, updatedAt: Date) {
        self.headOID = headOID
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case headOID = "headRefOid"
        case updatedAt
    }
}

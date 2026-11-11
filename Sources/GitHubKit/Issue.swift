import Foundation

/// A pull request that closes an issue when merged.
public struct LinkedPullRequest: Sendable, Hashable, Decodable {
    public enum State: String, Sendable, Hashable, Decodable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"
    }

    public let number: Int
    public let title: String
    public let state: State
    public let headRefName: String

    public init(number: Int, title: String, state: State, headRefName: String) {
        self.number = number
        self.title = title
        self.state = state
        self.headRefName = headRefName
    }
}

/// An issue, with what a list row shows.
public struct Issue: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable, Decodable {
        case open = "OPEN"
        case closed = "CLOSED"
    }

    /// The GraphQL node ID.
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    /// Nil when the author's account was deleted.
    public let author: User?
    public let labels: [GitHubLabel]
    public let commentCount: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let assignees: [User]
    /// Pull requests that close this issue when merged: open, merged, and closed ones.
    public let linkedPullRequests: [LinkedPullRequest]

    public init(
        id: String, number: Int, title: String, url: URL, state: State, author: User?, labels: [GitHubLabel],
        commentCount: Int, createdAt: Date, updatedAt: Date, assignees: [User],
        linkedPullRequests: [LinkedPullRequest]
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.author = author
        self.labels = labels
        self.commentCount = commentCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.assignees = assignees
        self.linkedPullRequests = linkedPullRequests
    }
}

extension Issue: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, number, title, url, state, author, labels, comments, createdAt, updatedAt, assignees
        case closedByPullRequestsReferences
    }

    private struct Count: Decodable { let totalCount: Int }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        state = try container.decode(State.self, forKey: .state)
        author = try container.decodeIfPresent(User.self, forKey: .author)
        labels = try container.decode(Connection<GitHubLabel>.self, forKey: .labels).nodes
        commentCount = try container.decode(Count.self, forKey: .comments).totalCount
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        assignees = try container.decode(Connection<User>.self, forKey: .assignees).nodes
        linkedPullRequests = try container
            .decode(Connection<LinkedPullRequest>.self, forKey: .closedByPullRequestsReferences).nodes
    }
}

/// One page of a repository's issues.
public struct IssuePage: Sendable, Hashable {
    public let items: [Issue]
    /// Pass this as `after` to load the next page. Nil when the page is empty.
    public let endCursor: String?
    public let hasNextPage: Bool
    /// How many open issues the repository has across all pages.
    public let totalCount: Int

    public init(items: [Issue], endCursor: String?, hasNextPage: Bool, totalCount: Int) {
        self.items = items
        self.endCursor = endCursor
        self.hasNextPage = hasNextPage
        self.totalCount = totalCount
    }
}

/// A comment in a conversation or in a review thread.
public struct Comment: Sendable, Hashable, Identifiable, Decodable {
    /// The GraphQL node ID.
    public let id: String
    /// Nil when the author's account was deleted.
    public let author: User?
    /// Markdown.
    public let body: String
    public let createdAt: Date

    public init(id: String, author: User?, body: String, createdAt: Date) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

/// An issue's description and conversation.
public struct IssueDetail: Sendable, Hashable {
    /// Markdown.
    public let body: String
    /// Oldest first.
    public let comments: [Comment]

    public init(body: String, comments: [Comment]) {
        self.body = body
        self.comments = comments
    }
}

extension IssueDetail: Decodable {
    private enum CodingKeys: String, CodingKey { case body, comments }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        body = try container.decode(String.self, forKey: .body)
        comments = try container.decode(Connection<Comment>.self, forKey: .comments).nodes
    }
}

import Foundation
import GitHubKit

/// One account's lists, as keys into the store's tables, and the state of their loads.
public struct AccountLists: Sendable {
    /// Open pull requests in the account's repositories, newest first.
    public internal(set) var openPullRequests: [ItemKey] = []
    /// Repositories the account owns and the viewer can push to, most recently pushed first.
    public internal(set) var repositories: [RepositoryRef] = []
    /// The viewer's teams and mentions, without merged branches, which come from the table.
    var signals = AttentionSignals()

    /// True once the lists have loaded at least once.
    public internal(set) var hasLoaded = false
    public internal(set) var listError: String?
    /// When the last refresh that succeeded finished.
    public internal(set) var lastRefresh: Date?
    public internal(set) var isRefreshing = false
    /// When the last refresh started, whether or not it succeeded.
    var lastAttempt: Date?
    /// When the last pull request load started. Nil until the first finishes.
    var pullRequestsLoadedAt: Date?
    var repositoriesTriedAt: Date?

    public init() {}
}

/// The loaded part of one repository's open issues, as keys into the store's issue table.
public struct IssueList: Sendable {
    public internal(set) var keys: [ItemKey] = []
    var endCursor: String?
    public internal(set) var hasNextPage = true
    public internal(set) var isLoading = false
    public internal(set) var error: String?

    public init() {}
}

/// The store's cache keeps the lists and what the next refresh needs, not the state of a load.
extension AccountLists: Codable {
    private enum CodingKeys: String, CodingKey {
        case openPullRequests, repositories, signals, hasLoaded
        /// Kept so the first refresh after a launch loads only what changed since.
        case pullRequestsLoadedAt
    }
}


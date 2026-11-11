import Foundation

/// The combined review outcome GitHub computes for a pull request.
public enum ReviewDecision: String, Sendable, Hashable, Decodable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// Whether a pull request merges cleanly into its base.
public enum MergeableState: String, Sendable, Hashable, Decodable {
    case mergeable = "MERGEABLE"
    /// The pull request has merge conflicts.
    case conflicting = "CONFLICTING"
    /// GitHub has not computed the answer yet.
    case unknown = "UNKNOWN"
}

/// The state of a commit status, and of the rollup of all checks on a commit.
public enum StatusState: String, Sendable, Hashable, Decodable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    /// A required check has not reported yet.
    case expected = "EXPECTED"
}

/// A pull request's place in a stack of dependent pull requests.
public struct StackEntry: Sendable, Hashable {
    /// The stack's node ID.
    public let stackID: String
    /// The stack's number within its repository.
    public let stackNumber: Int
    /// How many pull requests the stack has, including merged or closed ones.
    public let size: Int
    /// The branch the bottom of the stack targets.
    public let baseRefName: String
    /// The 1-based position, counted from the bottom of the stack.
    public let position: Int

    public init(stackID: String, stackNumber: Int, size: Int, baseRefName: String, position: Int) {
        self.stackID = stackID
        self.stackNumber = stackNumber
        self.size = size
        self.baseRefName = baseRefName
        self.position = position
    }
}

/// An open pull request, with what a list row shows.
public struct PullRequest: Sendable, Hashable, Identifiable {
    /// The GraphQL node ID.
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let repository: RepositoryRef
    /// Nil when the author's account was deleted.
    public let author: User?
    public let isDraft: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let headRefName: String
    public let baseRefName: String
    /// The head commit's SHA.
    public let headOID: String
    /// Nil when the repository does not require reviews and nobody reviewed.
    public let reviewDecision: ReviewDecision?
    public let additions: Int
    public let deletions: Int
    public let changedFileCount: Int
    public let mergeable: MergeableState
    public let labels: [GitHubLabel]
    /// The rollup of every check on the head commit. Nil when it has none.
    public let checkState: StatusState?
    /// Nil when the pull request is not part of a stack.
    public let stack: StackEntry?
    /// The numbers of the issues that merging this pull request closes.
    public let closingIssueNumbers: [Int]

    public init(
        id: String, number: Int, title: String, url: URL, repository: RepositoryRef, author: User?,
        isDraft: Bool, createdAt: Date, updatedAt: Date, headRefName: String, baseRefName: String,
        headOID: String, reviewDecision: ReviewDecision?, additions: Int, deletions: Int,
        changedFileCount: Int, mergeable: MergeableState, labels: [GitHubLabel], checkState: StatusState?,
        stack: StackEntry?, closingIssueNumbers: [Int]
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repository = repository
        self.author = author
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.headOID = headOID
        self.reviewDecision = reviewDecision
        self.additions = additions
        self.deletions = deletions
        self.changedFileCount = changedFileCount
        self.mergeable = mergeable
        self.labels = labels
        self.checkState = checkState
        self.stack = stack
        self.closingIssueNumbers = closingIssueNumbers
    }
}

extension PullRequest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, number, title, url, repository, author, isDraft, createdAt, updatedAt, headRefName
        case baseRefName, headRefOid, reviewDecision, additions, deletions, changedFiles, mergeable
        case labels, commits, stack, stackEntry, closingIssuesReferences
    }

    private struct HeadCommit: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable { let state: StatusState }
            let statusCheckRollup: Rollup?
        }
        let commit: Commit
    }

    private struct Stack: Decodable {
        let id: String
        let number: Int
        let size: Int
        let baseRefName: String
    }

    private struct Position: Decodable { let position: Int }
    private struct Number: Decodable { let number: Int }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        repository = try container.decode(RepositoryRef.self, forKey: .repository)
        author = try container.decodeIfPresent(User.self, forKey: .author)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        headRefName = try container.decode(String.self, forKey: .headRefName)
        baseRefName = try container.decode(String.self, forKey: .baseRefName)
        headOID = try container.decode(String.self, forKey: .headRefOid)
        reviewDecision = try container.decodeIfPresent(ReviewDecision.self, forKey: .reviewDecision)
        additions = try container.decode(Int.self, forKey: .additions)
        deletions = try container.decode(Int.self, forKey: .deletions)
        changedFileCount = try container.decode(Int.self, forKey: .changedFiles)
        mergeable = try container.decode(MergeableState.self, forKey: .mergeable)
        labels = try container.decode(Connection<GitHubLabel>.self, forKey: .labels).nodes
        checkState = try container.decode(Connection<HeadCommit>.self, forKey: .commits)
            .nodes.last?.commit.statusCheckRollup?.state
        closingIssueNumbers = try container.decode(Connection<Number>.self, forKey: .closingIssuesReferences)
            .nodes.map(\.number)

        let stack = try container.decodeIfPresent(Stack.self, forKey: .stack)
        let position = try container.decodeIfPresent(Position.self, forKey: .stackEntry)?.position
        if let stack, let position {
            self.stack = StackEntry(
                stackID: stack.id, stackNumber: stack.number, size: stack.size,
                baseRefName: stack.baseRefName, position: position
            )
        } else {
            self.stack = nil
        }
    }
}

// MARK: Bot filter

extension PullRequest {
    /// True when something is wrong that a person has to look at: the CI
    /// rollup is `failure` or `error`, or there are merge conflicts.
    public var needsAttention: Bool {
        checkState == .failure || checkState == .error || mergeable == .conflicting
    }

    /// Whether the pull request list shows this pull request.
    ///
    /// Pull requests by people are always shown. Pull requests by bots are
    /// shown only when `needsAttention` is true.
    ///
    /// - Parameter showingAllBots: Pass `true` to show every bot pull request.
    public func isShown(showingAllBots: Bool) -> Bool {
        showingAllBots || author?.isBot != true || needsAttention
    }
}

// MARK: Stacks

/// The pull requests of one stack that are in a list, bottom first.
public struct PullRequestStack: Sendable, Hashable, Identifiable {
    /// The stack's node ID.
    public let id: String
    /// The stack's number within its repository.
    public let number: Int
    /// How many pull requests the stack has. This can exceed
    /// `pullRequests.count` when some are merged, closed, or filtered out.
    public let size: Int
    /// The branch the bottom of the stack targets.
    public let baseRefName: String
    /// Ordered by position, bottom of the stack first.
    public let pullRequests: [PullRequest]

    public init(id: String, number: Int, size: Int, baseRefName: String, pullRequests: [PullRequest]) {
        self.id = id
        self.number = number
        self.size = size
        self.baseRefName = baseRefName
        self.pullRequests = pullRequests
    }
}

/// A row group in a pull request list: one unstacked pull request, or a stack.
public enum PullRequestGroup: Sendable, Hashable, Identifiable {
    case single(PullRequest)
    case stack(PullRequestStack)

    public var id: String {
        switch self {
        case .single(let pullRequest): pullRequest.id
        case .stack(let stack): stack.id
        }
    }
}

extension PullRequest {
    /// Groups pull requests into stacks.
    ///
    /// Each stack appears once, where its first member was in `pullRequests`,
    /// with its members ordered by position. Unstacked pull requests keep
    /// their place as `.single`.
    public static func grouped(_ pullRequests: [PullRequest]) -> [PullRequestGroup] {
        let stacked = pullRequests.compactMap { pullRequest in
            pullRequest.stack.map { (entry: $0, pullRequest: pullRequest) }
        }
        let members = Dictionary(grouping: stacked, by: \.entry.stackID)
        var emitted: Set<String> = []

        return pullRequests.compactMap { pullRequest in
            guard let entry = pullRequest.stack else { return .single(pullRequest) }
            guard emitted.insert(entry.stackID).inserted else { return nil }
            return .stack(PullRequestStack(
                id: entry.stackID, number: entry.stackNumber, size: entry.size, baseRefName: entry.baseRefName,
                pullRequests: members[entry.stackID, default: []]
                    .sorted { $0.entry.position < $1.entry.position }
                    .map(\.pullRequest)
            ))
        }
    }
}

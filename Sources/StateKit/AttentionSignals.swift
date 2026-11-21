import GitHubKit

/// A branch of a repository, such as the head of a merged pull request.
public struct ItemBranch: Hashable, Sendable {
    public let repository: RepositoryRef
    public let name: String

    public init(repository: RepositoryRef, name: String) {
        self.repository = repository
        self.name = name
    }
}

/// What Hermes knows about the viewer's part in pull requests, besides what each pull request holds.
public struct AttentionSignals: Equatable, Sendable {
    /// The teams the viewer is on.
    public var teams: Set<Reviewer> = []
    /// Node IDs of pull requests that mention the viewer.
    public var mentions: Set<String> = []
    /// Head branches of pull requests Hermes knows merged.
    public var mergedBranches: Set<ItemBranch> = []

    public init(teams: Set<Reviewer> = [], mentions: Set<String> = [], mergedBranches: Set<ItemBranch> = []) {
        self.teams = teams
        self.mentions = mentions
        self.mergedBranches = mergedBranches
    }
}

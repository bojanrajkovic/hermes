import Foundation
import GitHubKit

/// Why a pull request needs the viewer's attention, strongest first.
enum AttentionReason: Int, Comparable, Hashable, Sendable {
    /// The viewer is asked to review, by name.
    case reviewRequested
    /// The viewer's pull request has a review asking for changes.
    case changesRequested
    /// The viewer's pull request has a failing check.
    case failingChecks
    /// The viewer's pull request has merge conflicts.
    case conflicts
    /// The viewer's pull request is based on a branch that merged.
    case needsRebase
    /// A team the viewer is on is asked to review.
    case teamReviewRequested
    /// The head moved past the commit the viewer last reviewed.
    case newCommits
    /// The viewer is mentioned.
    case mentioned
    /// The viewer's pull request is approved, its checks pass, and it can merge.
    case readyToMerge
    /// The viewer opened it in the last day.
    case openedRecently

    /// Failing checks, conflicts, and a needed rebase are one rank: each blocks the viewer's own pull request.
    var rank: Int {
        switch self {
        case .reviewRequested: 0
        case .changesRequested: 1
        case .failingChecks, .conflicts, .needsRebase: 2
        case .teamReviewRequested: 3
        case .newCommits: 4
        case .mentioned: 5
        case .readyToMerge: 6
        case .openedRecently: 7
        }
    }

    var label: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .changesRequested: "Changes requested"
        case .failingChecks: "Checks failing"
        case .conflicts: "Conflicts"
        case .needsRebase: "Needs rebase"
        case .teamReviewRequested: "Team review"
        case .newCommits: "New commits"
        case .mentioned: "Mentioned"
        case .readyToMerge: "Ready to merge"
        case .openedRecently: "Opened recently"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A branch of a repository, such as the head of a merged pull request.
struct ItemBranch: Hashable, Sendable {
    let repository: RepositoryRef
    let name: String
}

/// What Hermes knows about the viewer's part in pull requests, besides what each pull request holds.
struct AttentionSignals: Equatable, Sendable {
    /// The teams the viewer is on.
    var teams: Set<Reviewer> = []
    /// Node IDs of pull requests that mention the viewer.
    var mentions: Set<String> = []
    /// Head branches of pull requests Hermes knows merged.
    var mergedBranches: Set<ItemBranch> = []
}

/// The strongest reason `pullRequest` needs the viewer's attention, or nil when it does not.
func attentionReason(for pullRequest: PullRequest, viewer: String, signals: AttentionSignals, now: Date) -> AttentionReason? {
    let isMine = pullRequest.author?.login == viewer
    var reasons: [AttentionReason] = []

    if pullRequest.requestedReviewers.contains(.user(login: viewer)) { reasons.append(.reviewRequested) }
    if !signals.teams.isDisjoint(with: pullRequest.requestedReviewers) { reasons.append(.teamReviewRequested) }
    if !isMine, let reviewed = pullRequest.viewerReviewedCommit, reviewed != pullRequest.headOID {
        reasons.append(.newCommits)
    }
    if signals.mentions.contains(pullRequest.id) { reasons.append(.mentioned) }

    if isMine {
        let failing = pullRequest.checkState == .failed
        if pullRequest.reviewDecision == .changesRequested { reasons.append(.changesRequested) }
        if failing { reasons.append(.failingChecks) }
        if pullRequest.mergeable == .conflicting { reasons.append(.conflicts) }
        if signals.mergedBranches.contains(ItemBranch(repository: pullRequest.repository, name: pullRequest.baseRefName)) {
            reasons.append(.needsRebase)
        }
        // Checks that merging does not require do not hold it back.
        let checksPass = pullRequest.checkState != .failed && pullRequest.checkState != .pending
        if pullRequest.reviewDecision == .approved, checksPass, pullRequest.mergeable == .mergeable, !pullRequest.isDraft {
            reasons.append(.readyToMerge)
        }
        if now.timeIntervalSince(pullRequest.createdAt) < 24 * 3600 { reasons.append(.openedRecently) }
    }
    return reasons.min()
}

/// The pull requests that need the viewer's attention, each with its strongest reason, ranked by
/// reason and then most recently updated first.
func attentionList(
    _ pullRequests: [PullRequest], viewer: String, signals: AttentionSignals, now: Date
) -> [(pullRequest: PullRequest, reason: AttentionReason)] {
    pullRequests
        .compactMap { pullRequest in
            attentionReason(for: pullRequest, viewer: viewer, signals: signals, now: now).map { (pullRequest, $0) }
        }
        .sorted {
            ($0.reason.rank, $1.pullRequest.updatedAt, $1.pullRequest.number) < ($1.reason.rank, $0.pullRequest.updatedAt, $0.pullRequest.number)
        }
}

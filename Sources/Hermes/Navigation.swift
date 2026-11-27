import Foundation
import GitHubKit
import StateKit
import HermesUI

/// A pull request or issue, named by repository and number.
/// What a window was opened with, kept current as it changes: the window's
/// account, a `hermes://` link to what it shows, the pull request tab, and which
/// list groups are open. macOS saves it with the window, so a relaunch restores them.
struct WindowState: Codable, Hashable {
    var id = UUID()
    var login: String?
    var url: URL?
    var tab = PullRequestTab.files
    /// `WindowModel.expansion`: list groups the user opened or closed, by node ID.
    var expansion: [String: Bool] = [:]

    init(id: UUID = UUID(), login: String? = nil, url: URL? = nil, tab: PullRequestTab = .files, expansion: [String: Bool] = [:]) {
        self.id = id
        self.login = login
        self.url = url
        self.tab = tab
        self.expansion = expansion
    }

    private enum CodingKeys: String, CodingKey { case id, login, url, tab, expansion }

    /// A window saved before a field existed restores with that field's default.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        login = try container.decodeIfPresent(String.self, forKey: .login)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        tab = try container.decodeIfPresent(PullRequestTab.self, forKey: .tab) ?? .files
        expansion = try container.decodeIfPresent([String: Bool].self, forKey: .expansion) ?? [:]
    }
}
extension PullRequest {
    /// The pull requests that merge when this one does: itself, and for a
    /// stacked one the open members of its stack below it, bottom first.
    func mergeSet(among pullRequests: [PullRequest]) -> [PullRequest] {
        guard let entry = stack else { return [self] }
        let below = pullRequests
            .filter { $0.stack?.stackID == entry.stackID && ($0.stack?.position ?? 0) < entry.position }
            .sorted { ($0.stack?.position ?? 0) < ($1.stack?.position ?? 0) }
        return below + [self]
    }
}

/// What the detail pane shows.
enum Destination: Hashable, Sendable {
    case pullRequest(ItemKey)
    case issue(ItemKey)
    case session(UUID)
    /// A local branch that has no open pull request, read from the user's checkout.
    case localBranch(LocalBranchKey)
}

/// The tabs of a pull request's detail pane.
enum PullRequestTab: Int, CaseIterable, Identifiable, Sendable, Codable {
    case conversation, files, checks, sessions

    var id: Self { self }

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .files: "Files"
        case .checks: "Checks"
        case .sessions: "Sessions"
        }
    }
}

/// Which of a repository's lists the middle column shows.
enum RepositoryList: String, CaseIterable, Identifiable, Sendable {
    /// Local stacks shows only for a repository with a checkout.
    case pullRequests, issues, localStacks

    var id: Self { self }
}

/// What the sidebar selected for the middle column to list: an Inbox filter, a repository,
/// or the sessions.
enum Scope: Hashable, Sendable {
    case filter(InboxFilter)
    case repository(RepositoryRef)
    case sessions
}

/// A cross-repository pull request filter.
enum InboxFilter: String, CaseIterable, Identifiable, Sendable {
    case needsAttention, yours, failing, drafts, bots, all

    var id: Self { self }

    var title: String {
        switch self {
        case .needsAttention: "Needs Your Attention"
        case .yours: "Yours"
        case .failing: "Failing CI"
        case .drafts: "Drafts"
        case .bots: "Bots"
        case .all: "All Pull Requests"
        }
    }

    var symbol: String {
        switch self {
        case .needsAttention: "bell"
        case .yours: "person"
        case .failing: "xmark.octagon"
        case .drafts: "pencil.line"
        case .bots: "gearshape.2"
        case .all: "tray.full"
        }
    }

    /// Whether `pullRequest` belongs under this filter.
    ///
    /// Every filter except `bots` leaves out the bot pull requests the bot
    /// filter hides. `bots` lists every bot pull request.
    ///
    /// - Parameters:
    ///   - viewer: The signed-in user's login.
    ///   - attention: The viewer's part in each pull request, for `needsAttention`.
    func matches(
        _ pullRequest: PullRequest, viewer: String, attention: AttentionSignals, now: Date, showingAllBots: Bool
    ) -> Bool {
        if self == .bots { return pullRequest.author?.isBot == true }
        guard pullRequest.isShown(showingAllBots: showingAllBots) else { return false }

        switch self {
        case .needsAttention: return attentionReason(for: pullRequest, viewer: viewer, signals: attention, now: now) != nil
        case .yours: return pullRequest.author?.login == viewer
        case .failing: return pullRequest.checkState == .failed
        case .drafts: return pullRequest.isDraft
        case .bots, .all: return true
        }
    }
}

/// One repository's rows: its pull requests grouped into stacks, and its counts.
struct RepositorySection: Identifiable, Hashable, Sendable {
    let ref: RepositoryRef
    let isPrivate: Bool
    /// The shown pull requests, with stacks folded into one group each.
    let groups: [PullRequestGroup]
    let shownPullRequestCount: Int
    /// Bot pull requests the bot filter leaves out.
    let hiddenBotCount: Int
    let openIssueCount: Int

    var id: RepositoryRef { ref }
}

/// Builds the repository list: one section per repository that has an open
/// pull request or an open issue.
///
/// Repositories with pull requests in `pullRequests` come first, then the
/// rest, each part in the order of `repositories`. A pull request whose
/// repository is missing from `repositories` still gets a section.
///
/// - Parameter includingEmpty: Pass `false` to leave out repositories with no
///   pull request in `pullRequests`, for a filtered list.
func repositorySections(
    repositories: [Repository], pullRequests: [PullRequest], showingAllBots: Bool, includingEmpty: Bool = true
) -> [RepositorySection] {
    let byRepository = Dictionary(grouping: pullRequests, by: \.repository)
    let known = Set(repositories.map(\.ref))
    var refs = repositories.map { (ref: $0.ref, isPrivate: $0.isPrivate, issues: $0.openIssueCount) }
    var seen = known
    for pullRequest in pullRequests where seen.insert(pullRequest.repository).inserted {
        refs.append((pullRequest.repository, false, 0))
    }

    let sections = refs.compactMap { repository -> RepositorySection? in
        let all = byRepository[repository.ref] ?? []
        let shown = all.filter { $0.isShown(showingAllBots: showingAllBots) }
        guard !all.isEmpty || (includingEmpty && repository.issues > 0) else { return nil }
        return RepositorySection(
            ref: repository.ref, isPrivate: repository.isPrivate, groups: PullRequest.grouped(shown),
            shownPullRequestCount: shown.count, hiddenBotCount: all.count - shown.count,
            openIssueCount: repository.issues
        )
    }
    return sections.filter { $0.shownPullRequestCount > 0 } + sections.filter { $0.shownPullRequestCount == 0 }
}

extension StatusKind {
    init(_ state: ChecksRollup?) {
        switch state {
        case .passed: self = .passed
        case .failed: self = .failed
        case .optionalFailed: self = .warning
        case .pending: self = .pending
        case nil: self = .none
        }
    }
}

import Foundation
import GitHubKit

/// Everything Hermes knows about GitHub, one copy of each fact. Every window and screen
/// reads from here, so two views of the same fact can't disagree.
///
/// Records live in tables keyed by identity: pull requests and issues by `ItemKey`,
/// repositories by `RepositoryRef`. An account's lists hold keys into those tables, so a
/// pull request that two lists show is one record.
///
/// Fetches write here and nowhere else. When two fetches return the same fact, the one that
/// started later wins (`Stamped`).
@Observable
@MainActor
public final class GitHubStore {
    public static let issuePageSize = 30
    /// How often a poll loop wakes up. Each tick refreshes only what is due.
    nonisolated public static let tick: Duration = .seconds(15)

    public let client: GitHubClient

    public internal(set) var pullRequests: [ItemKey: PullRequest] = [:]
    public internal(set) var issues: [ItemKey: Issue] = [:]
    public internal(set) var repositories: [RepositoryRef: Stamped<Repository>] = [:]
    public internal(set) var accounts: [String: AccountLists] = [:]
    public internal(set) var issueLists: [RepositoryRef: IssueList] = [:]

    /// The signed-in user's login. Nil until sign-in finishes.
    public var viewer: String?

    /// Each open pull request's description, conversation, reviews, commits, and review threads.
    public internal(set) var details: [ItemKey: PullRequestDetail] = [:]
    /// Why a pull request's detail could not load. Cleared by the next load that works.
    public internal(set) var detailErrors: [ItemKey: String] = [:]
    /// Whether each open pull request can merge, and how.
    public internal(set) var readiness: [ItemKey: MergeReadiness] = [:]
    /// Each open pull request's head commit, update time, and viewed files, as the last
    /// revision fetch or viewed mark left them.
    public internal(set) var revisions: [ItemKey: Stamped<PullRequestRevision>] = [:]

    /// How many detail loads have started for each pull request. A load that a later one
    /// overtakes drops its answer.
    @ObservationIgnored var detailLoads: [ItemKey: Int] = [:]
    /// How many webhook changes each detail took. A load that ran meanwhile runs again.
    @ObservationIgnored var detailWrites: [ItemKey: Int] = [:]
    /// The update time each loaded detail matches.
    @ObservationIgnored var detailLoadedFor: [ItemKey: Date] = [:]
    @ObservationIgnored var readinessInputs: [ItemKey: ReadinessInput] = [:]
    /// How many viewed marks were sent for each file, and the last send, so marks go out in order.
    @ObservationIgnored var viewedSends: [ViewedFile: Int] = [:]
    @ObservationIgnored var viewedTasks: [ViewedFile: Task<Void, Never>] = [:]
    /// Marks sent to GitHub that it hasn't confirmed. Every revision taken keeps them.
    @ObservationIgnored var viewedInFlight: [ViewedFile: Bool] = [:]

    /// The webhook payloads put into rows. A load reads it before and after asking GitHub,
    /// to tell whether a row took a payload meanwhile.
    @ObservationIgnored var applied = AppliedPayloads()

    /// The pull requests an account's windows show, most important first. Each refresh loads
    /// these again by ID, because GitHub's search can trail a change by a minute.
    @ObservationIgnored public var watched: (String) -> [ItemKey] = { _ in [] }
    /// Whether Hermes is the active app. Polls run every tick while it is.
    @ObservationIgnored public var isActive: () -> Bool = { true }
    /// How long a poll waits between refreshes while Hermes is in the background.
    @ObservationIgnored public var backgroundInterval: TimeInterval = 60

    @ObservationIgnored private var scheduler: Scheduler?

    public init(client: GitHubClient) {
        self.client = client
        scheduler = Scheduler(tick: \.interval) { [weak self] interest in await self?.poll(interest) }
    }

    // MARK: Interests

    /// Keeps `interest` fresh until the calling task is cancelled. Two callers showing the
    /// same interest share one poll.
    public func showing(_ interest: Interest) async {
        await scheduler?.showing(interest)
    }

    /// The interests being polled now.
    var polling: Set<Interest> { scheduler?.polling ?? [] }

    private func poll(_ interest: Interest) async {
        switch interest {
        case .account(let login):
            guard shouldRefresh(
                isActive: isActive(), lastAttempt: accounts[login]?.lastAttempt,
                backgroundInterval: backgroundInterval, now: .now
            ) else { return }
            await refresh(login)
        case .pullRequest(let key):
            await pollPullRequest(key)
        }
    }

    // MARK: Lookups

    public func lists(of login: String) -> AccountLists {
        accounts[login] ?? AccountLists()
    }

    /// The account's open pull requests, newest first.
    public func openPullRequests(of login: String) -> [PullRequest] {
        lists(of: login).openPullRequests.compactMap { pullRequests[$0] }
    }

    /// The account's repositories, most recently pushed first.
    public func repositories(of login: String) -> [Repository] {
        lists(of: login).repositories.compactMap { repositories[$0]?.value }
    }

    /// What the attention inbox ranks by, with the head branches of pull requests Hermes saw merge.
    public func attention(of login: String) -> AttentionSignals {
        var signals = lists(of: login).signals
        signals.mergedBranches = Set(pullRequests.values.filter { $0.state == .merged }.map {
            ItemBranch(repository: $0.repository, name: $0.headRefName)
        })
        return signals
    }

    public func pullRequest(_ key: ItemKey) -> PullRequest? { pullRequests[key] }

    public func issue(_ key: ItemKey) -> Issue? { issues[key] }

    /// The members of `pullRequest`'s stack in its account's open list, bottom first. Empty when
    /// it is not in a stack. The open list decides what is open, as it does for every list.
    public func stack(of pullRequest: PullRequest) -> [PullRequest] {
        guard let stackID = pullRequest.stack?.stackID else { return [] }
        return openPullRequests(of: pullRequest.repository.owner)
            .filter { $0.stack?.stackID == stackID }
            .sorted { ($0.stack?.position ?? 0) < ($1.stack?.position ?? 0) }
    }

    /// Every pull request held, open ones first, for matching a webhook event. A closed pull
    /// request can share its head commit with an open one, and the open one is the one on screen.
    public var heldPullRequests: [PullRequest] {
        let all = Array(pullRequests.values)
        return all.filter { $0.state == .open } + all.filter { $0.state != .open }
    }

    /// Open issues across all pages. Nil until a repository load or an issue page reports it.
    public func openIssueCount(of repository: RepositoryRef) -> Int? {
        repositories[repository]?.value.openIssueCount
    }

    /// The loaded issues of a repository's list, most recently updated first.
    public func listedIssues(of repository: RepositoryRef) -> [Issue] {
        issueList(of: repository).keys.compactMap { issues[$0] }
    }

    public func issueList(of repository: RepositoryRef) -> IssueList {
        issueLists[repository] ?? IssueList()
    }

    // MARK: Writes

    /// Keeps a pull request or issue loaded by number.
    public func store(_ item: FetchedItem, for key: ItemKey) {
        switch item {
        case .pullRequest(let pullRequest): pullRequests[key] = pullRequest
        case .issue(let issue): issues[key] = issue
        }
    }

    /// Takes a repository from a fetch that started at `startedAt`, unless a later fetch already wrote it.
    func store(_ repository: Repository, startedAt: Date) {
        if repositories[repository.ref]?.write(repository, startedAt: startedAt) == nil {
            repositories[repository.ref] = Stamped(repository, fetchedAt: startedAt)
        }
    }

    /// Loads one pull request or issue again and replaces its record.
    public func refetch(_ key: ItemKey) async {
        while true {
            let before = applied
            guard let item = try? await client.item(key) else { return }
            // A payload the row took while GitHub answered is newer than the answer, so the row loads once more.
            guard !applied.rows(since: before).contains(key) else { continue }
            return store(item, for: key)
        }
    }

    /// Puts the fields of a webhook's `pull_request` payload into the pull request's record.
    ///
    /// - Returns: False when the payload is older than the last one the record took, and
    ///   changed nothing.
    public func apply(_ fields: PullRequestFields, to key: ItemKey) -> Bool {
        guard let held = pullRequests[key], applied.take(fields, for: key) else { return false }
        pullRequests[key] = held.applying(fields)
        return true
    }
}

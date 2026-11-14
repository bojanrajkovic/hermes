import Foundation
import GitHubKit

/// One account's pull requests, repositories, and issues. Every window that
/// shows the account reads the same copy, so each list loads once.
@Observable
@MainActor
final class AccountData {
    static let issuePageSize = 30

    /// Empty for the copy a window uses before it has an account.
    let login: String
    private let client: GitHubClient
    /// The signed-in user's login, once known. Review searches are about them, not the account.
    private let viewer: () -> String?

    private(set) var pullRequests: [PullRequest] = []
    private(set) var repositories: [Repository] = []
    /// The viewer's part in each pull request: review requests, reviews, and mentions.
    private var signals = AttentionSignals()
    private(set) var issueLists: [RepositoryRef: IssueList] = [:]
    /// Pull requests and issues loaded one at a time, by number, because they
    /// are not in the lists above: closed ones, ones in another account, and
    /// ones that left a list while a window could be showing them.
    private(set) var fetchedPullRequests: [ItemKey: PullRequest] = [:]
    private(set) var fetchedIssues: [ItemKey: Issue] = [:]
    private var fetchedStates: [ItemKey: LinkedPullRequest.State] = [:]

    /// True once the lists have loaded at least once.
    private(set) var hasLoaded = false
    private(set) var listError: String?
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    /// When the last pull request load started. Nil until the first finishes.
    private var pullRequestsLoadedAt: Date?
    private var repositoriesTriedAt: Date?

    init(login: String, client: GitHubClient, viewer: @escaping () -> String?) {
        self.login = login
        self.client = client
        self.viewer = viewer
    }

    /// What the attention inbox ranks by, with the head branches of pull requests Hermes saw merge.
    var attention: AttentionSignals {
        var signals = signals
        signals.mergedBranches = Set(fetchedStates.compactMap { key, state in
            state == .merged ? fetchedPullRequests[key].map { ItemBranch(repository: key.repository, name: $0.headRefName) } : nil
        })
        return signals
    }

    // MARK: Loading

    /// Brings the lists up to date. Rows keep their identity, so selection and scroll position stay.
    ///
    /// The first load fetches the pull requests that involve the viewer, shows
    /// them, then fetches the rest of the account. Later refreshes fetch only the
    /// pull requests updated since the last one, so a large organization costs a
    /// few requests per refresh instead of hundreds.
    ///
    /// - Parameter everything: Also reload the repositories, which otherwise
    ///   reload once they are 10 minutes old. For ⌘R.
    func refresh(everything: Bool = false) async {
        guard !login.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let started = Date.now
        // Tried, not loaded: a failed load waits as long as a good one, so it does not retry every refresh.
        let reposAreStale = repositoriesTriedAt.map { started.timeIntervalSince($0) > 600 } ?? true
        if everything || reposAreStale { repositoriesTriedAt = started }
        async let loadedRepositories = everything || reposAreStale ? client.repositories(owner: login) : nil
        do {
            if let pullRequestsLoadedAt {
                try await loadChanges(since: pullRequestsLoadedAt)
            } else {
                try await loadEverything()
            }
            pullRequestsLoadedAt = started
            if let repositories = try await loadedRepositories { self.repositories = repositories }
            listError = nil
            lastRefresh = .now
        } catch {
            listError = describe(error)
        }

        for repository in issueLists.keys { await reloadIssues(of: repository) }
    }

    /// The viewer's pull requests first, so their lists show while the rest of the account loads.
    /// The rest is only what is in repositories the viewer can push to. A load that fails part
    /// way keeps what it fetched, and the next refresh fetches only what is still missing.
    private func loadEverything() async throws {
        async let involved = client.pullRequestIDs(matching: PullRequestSearch.involvingViewer(owner: login)[0])
        async let signaled = loadSignals()
        let (involvedIDs, signaledIDs) = try await (involved, signaled)
        try await loadMissing(Array(Set(involvedIDs).union(signaledIDs)))
        hasLoaded = true

        let rest = try await client.pullRequestHits(matching: PullRequestSearch.open(owner: login)).filter(\.canPush)
        try await loadMissing(rest.map(\.id))
    }

    /// Loads the pull requests not held yet, 50 at a time, adding each batch as it arrives.
    private func loadMissing(_ ids: [String]) async throws {
        let held = Set(pullRequests.map(\.id))
        let missing = ids.filter { !held.contains($0) }
        for start in stride(from: 0, to: missing.count, by: 50) {
            let batch = try await client.pullRequests(ids: Array(missing[start..<min(start + 50, missing.count)]))
            pullRequests = PullRequestChanges.apply(to: pullRequests, changed: batch, closed: [])
        }
    }

    /// The pull requests updated since the last refresh, and the current review requests.
    // shortcut: a repository archived since the first load keeps its pull requests until relaunch; reload everything if that matters.
    private func loadChanges(since: Date) async throws {
        async let open = client.pullRequestHits(matching: PullRequestSearch.updated(owner: login, since: since, open: true))
        async let closed = client.pullRequestIDs(matching: PullRequestSearch.updated(owner: login, since: since, open: false))
        async let signaled = loadSignals()
        let (openHits, closedIDs, signaledIDs) = try await (open, closed, signaled)

        // A read-only repository's pull request loads only when the viewer already holds it or has a part in it.
        // A review request or a mention does not update the pull request, so one not held yet loads here.
        let held = Set(pullRequests.map(\.id))
        let openIDs = openHits.filter { $0.canPush || held.contains($0.id) || signaledIDs.contains($0.id) }.map(\.id)
        // A check that finishes does not update its pull request, so pending ones load again until they settle.
        let pending = pullRequests.filter { $0.checkState == .pending || $0.checkState == .expected }.map(\.id)
        let changed = try await client.pullRequests(ids: Array(Set(openIDs + pending).union(signaledIDs.subtracting(held))))
        let reloaded = PullRequestChanges.apply(to: pullRequests, changed: changed, closed: Set(closedIDs))
        keepLeaving(pullRequests: reloaded)
        pullRequests = reloaded
    }

    /// Searches for the viewer's review requests, reviews, and mentions, and the commit of each
    /// of their latest reviews. Returns every pull request they name, to load from any repository.
    private func loadSignals() async throws -> Set<String> {
        async let direct = client.pullRequestIDs(matching: PullRequestSearch.directlyRequested(owner: login))
        async let requested = client.pullRequestIDs(matching: PullRequestSearch.reviewRequested(owner: login))
        async let reviewed = client.pullRequestIDs(matching: PullRequestSearch.reviewedByViewer(owner: login))
        async let mentions = client.pullRequestIDs(matching: PullRequestSearch.mentioningViewer(owner: login))
        let (directIDs, requestedIDs, reviewedIDs, mentionIDs) = try await (direct, requested, reviewed, mentions)
        let commits = if let viewer = viewer() {
            try await client.latestReviewCommits(pullRequestIDs: reviewedIDs, viewer: viewer)
        } else {
            [String: String]()
        }

        signals = AttentionSignals(
            directRequests: Set(directIDs), teamRequests: Set(requestedIDs).subtracting(directIDs),
            reviewedCommits: commits, mentions: Set(mentionIDs)
        )
        return Set(directIDs + requestedIDs + reviewedIDs + mentionIDs)
    }

    /// Reloads when the lists are older than a few seconds, for app activation.
    func refreshIfStale() async {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 10 { return }
        await refresh()
    }

    /// Keeps a pull request that left the open list readable, since a window
    /// may be showing it, and loads whether it was merged or closed.
    private func keepLeaving(pullRequests reloaded: [PullRequest]) {
        let staying = Set(reloaded.map(\.key))
        for leaving in pullRequests where !staying.contains(leaving.key) && fetchedPullRequests[leaving.key] == nil {
            fetchedPullRequests[leaving.key] = leaving
            Task { await refetch(leaving.key) }
        }
    }

    /// Loads one pull request or issue again and replaces the copy held: the
    /// one in its list, or the one loaded by number. A pull request that is no
    /// longer open is also stored by number, with its state.
    func refetch(_ key: ItemKey) async {
        guard let item = try? await client.item(key) else { return }
        store(item, for: key)
    }

    /// Keeps an item loaded by number.
    func store(_ item: FetchedItem, for key: ItemKey) {
        switch item {
        case .pullRequest(let pullRequest, let state):
            let listed = pullRequests.firstIndex { $0.key == key }
            if let listed { pullRequests[listed] = pullRequest }
            if listed == nil || state != .open {
                fetchedPullRequests[key] = pullRequest
                fetchedStates[key] = state
            }
        case .issue(let issue):
            if let listed = issueLists[key.repository]?.items.firstIndex(where: { $0.number == key.number }) {
                issueLists[key.repository]?.items[listed] = issue
            } else {
                fetchedIssues[key] = issue
            }
        }
    }

    // MARK: Issues

    func issueList(of repository: RepositoryRef) -> IssueList {
        issueLists[repository] ?? IssueList()
    }

    /// Loads the next page of a repository's issues. Does nothing while a page
    /// is loading or when every issue is loaded.
    func loadMoreIssues(of repository: RepositoryRef) async {
        var list = issueList(of: repository)
        guard !list.isLoading, list.hasNextPage else { return }
        list.isLoading = true
        list.error = nil
        issueLists[repository] = list

        do {
            let page = try await client.issues(repository: repository, pageSize: Self.issuePageSize, after: list.endCursor)
            guard var current = issueLists[repository] else { return }
            let known = Set(current.items.map(\.id))
            current.items += page.items.filter { !known.contains($0.id) }
            current.endCursor = page.endCursor ?? current.endCursor
            current.hasNextPage = page.hasNextPage
            current.totalCount = page.totalCount
            current.isLoading = false
            issueLists[repository] = current
        } catch {
            guard var current = issueLists[repository] else { return }
            current.isLoading = false
            current.error = describe(error)
            issueLists[repository] = current
        }
    }

    /// Loads again as many issues as are loaded now, in pages of up to 100.
    func reloadIssues(of repository: RepositoryRef) async {
        guard let existing = issueLists[repository], !existing.isLoading, !existing.items.isEmpty else { return }
        var reloaded = IssueList()
        do {
            repeat {
                let page = try await client.issues(
                    repository: repository, pageSize: min(100, max(Self.issuePageSize, existing.items.count - reloaded.items.count)),
                    after: reloaded.endCursor
                )
                reloaded.items += page.items
                reloaded.endCursor = page.endCursor
                reloaded.hasNextPage = page.hasNextPage
                reloaded.totalCount = page.totalCount
            } while reloaded.hasNextPage && reloaded.items.count < existing.items.count
        } catch {
            return
        }
        // Skip the result when more pages were loaded meanwhile.
        guard let current = issueLists[repository], !current.isLoading, current.items.count == existing.items.count else { return }
        keepLeaving(issues: existing.items, in: repository, reloaded: reloaded.items)
        issueLists[repository] = reloaded
    }

    /// Keeps an issue that left the loaded part of its list readable, and loads whether it was closed.
    private func keepLeaving(issues: [Issue], in repository: RepositoryRef, reloaded: [Issue]) {
        let staying = Set(reloaded.map(\.number))
        for leaving in issues where !staying.contains(leaving.number) {
            let key = ItemKey(repository: repository, number: leaving.number)
            guard fetchedIssues[key] == nil else { continue }
            fetchedIssues[key] = leaving
            Task { await refetch(key) }
        }
    }

    // MARK: Lookups

    func pullRequest(_ key: ItemKey) -> PullRequest? {
        pullRequests.first { $0.number == key.number && $0.repository == key.repository } ?? fetchedPullRequests[key]
    }

    /// Merged or closed, for a pull request that is not in the open list. Nil when unknown.
    func closedState(of key: ItemKey) -> LinkedPullRequest.State? {
        fetchedStates[key]
    }

    func issue(_ key: ItemKey) -> Issue? {
        issueLists[key.repository]?.items.first { $0.number == key.number } ?? fetchedIssues[key]
    }

    func stack(of pullRequest: PullRequest) -> [PullRequest] {
        guard let stackID = pullRequest.stack?.stackID else { return [] }
        return pullRequests
            .filter { $0.stack?.stackID == stackID }
            .sorted { ($0.stack?.position ?? 0) < ($1.stack?.position ?? 0) }
    }
}

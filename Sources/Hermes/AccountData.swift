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

    private(set) var pullRequests: [PullRequest] = []
    private(set) var repositories: [Repository] = []
    /// Node IDs of the open pull requests that ask for the viewer's review.
    private(set) var reviewRequested: Set<String> = []
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
    private var repositoriesLoadedAt: Date?

    init(login: String, client: GitHubClient) {
        self.login = login
        self.client = client
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
        let reposAreStale = repositoriesLoadedAt.map { started.timeIntervalSince($0) > 600 } ?? true
        async let loadedRepositories = everything || reposAreStale ? client.repositories(owner: login) : nil
        do {
            if let pullRequestsLoadedAt {
                try await loadChanges(since: pullRequestsLoadedAt)
            } else {
                try await loadEverything()
            }
            pullRequestsLoadedAt = started
            if let repositories = try await loadedRepositories {
                self.repositories = repositories
                repositoriesLoadedAt = started
            }
            listError = nil
            lastRefresh = .now
        } catch {
            listError = describe(error)
        }

        for repository in issueLists.keys { await reloadIssues(of: repository) }
    }

    /// The viewer's pull requests first, so their lists show while the rest of the account loads.
    private func loadEverything() async throws {
        let queries = PullRequestSearch.involvingViewer(owner: login)
        async let involved = client.pullRequestIDs(matching: queries[0])
        async let requested = client.pullRequestIDs(matching: queries[1])
        let (involvedIDs, requestedIDs) = try await (involved, requested)
        reviewRequested = Set(requestedIDs)
        let mine = Array(Set(involvedIDs + requestedIDs))
        pullRequests = PullRequestChanges.apply(to: [], changed: try await client.pullRequests(ids: mine), closed: [])
        hasLoaded = true

        let held = Set(pullRequests.map(\.id))
        let rest = try await client.pullRequestIDs(matching: PullRequestSearch.open(owner: login)).filter { !held.contains($0) }
        pullRequests = PullRequestChanges.apply(to: pullRequests, changed: try await client.pullRequests(ids: rest), closed: [])
    }

    /// The pull requests updated since the last refresh, and the current review requests.
    // shortcut: a repository archived since the first load keeps its pull requests until relaunch; reload everything if that matters.
    private func loadChanges(since: Date) async throws {
        async let open = client.pullRequestIDs(matching: PullRequestSearch.updated(owner: login, since: since, open: true))
        async let closed = client.pullRequestIDs(matching: PullRequestSearch.updated(owner: login, since: since, open: false))
        async let requested = client.pullRequestIDs(matching: PullRequestSearch.reviewRequested(owner: login))
        let (openIDs, closedIDs, requestedIDs) = try await (open, closed, requested)

        // A review request does not update the pull request, so one not held yet loads here.
        let held = Set(pullRequests.map(\.id))
        let changed = try await client.pullRequests(ids: Array(Set(openIDs + requestedIDs.filter { !held.contains($0) })))
        let reloaded = PullRequestChanges.apply(to: pullRequests, changed: changed, closed: Set(closedIDs))
        keepLeaving(pullRequests: reloaded)
        pullRequests = reloaded
        reviewRequested = Set(requestedIDs)
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

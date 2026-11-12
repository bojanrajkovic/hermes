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

    init(login: String, client: GitHubClient) {
        self.login = login
        self.client = client
    }

    // MARK: Loading

    /// Reloads the pull requests, repositories, and the issue lists that are
    /// open. Rows keep their identity, so selection and scroll position stay.
    func refresh() async {
        guard !login.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let loadedPullRequests = client.openPullRequests(owner: login)
        async let loadedRepositories = client.repositories(owner: login)
        async let requested = try? reviewRequestedIDs()
        do {
            let (pullRequests, repositories) = try await (loadedPullRequests, loadedRepositories)
            keepLeaving(pullRequests: pullRequests)
            self.pullRequests = pullRequests
            self.repositories = repositories
            listError = nil
            hasLoaded = true
            lastRefresh = .now
        } catch {
            listError = describe(error)
        }
        if let requested = await requested { reviewRequested = requested }

        for repository in issueLists.keys { await reloadIssues(of: repository) }
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

    private func reviewRequestedIDs() async throws -> Set<String> {
        struct Data: Decodable, Sendable {
            struct Search: Decodable, Sendable { let nodes: [Node] }
            struct Node: Decodable, Sendable { let id: String? }
            let search: Search
        }
        // shortcut: the first 100 requests; upgrade to paging if someone has more waiting.
        let query = """
            { search(query: "is:pr is:open archived:false review-requested:@me", type: ISSUE, first: 100) {
                nodes { ... on PullRequest { id } }
            } }
            """
        return Set(try await client.graphQL(query, as: Data.self).search.nodes.compactMap(\.id))
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

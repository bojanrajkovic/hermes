import AppKit
import Foundation
import GitHubKit
import HermesUI
import RepoKit
import SessionsUI

/// The loaded part of one repository's open issues.
struct IssueList: Sendable {
    var items: [Issue] = []
    var endCursor: String?
    var hasNextPage = true
    /// Open issues across all pages. Nil until the first page arrives.
    var totalCount: Int?
    var isLoading = false
    var error: String?
}

/// Why the app cannot show the signed-in user's data.
enum StartupProblem: Equatable {
    case ghNotInstalled
    case ghNotLoggedIn(message: String)
    case other(message: String)

    init(_ error: any Error) {
        switch error {
        case GitHubError.ghNotInstalled: self = .ghNotInstalled
        case GitHubError.ghNotLoggedIn(let message): self = .ghNotLoggedIn(message: message)
        case GitHubError.http(status: 401, _): self = .ghNotLoggedIn(message: "GitHub rejected the token.")
        default: self = .other(message: describe(error))
        }
    }
}

/// A sentence for an error a list or a pane failed with.
func describe(_ error: any Error) -> String {
    switch error {
    case GitHubError.rateLimited(let resetAt):
        "GitHub's rate limit is used up until \(resetAt.formatted(date: .omitted, time: .shortened))."
    case GitHubError.http(let status, let message):
        message.isEmpty ? "GitHub answered with HTTP \(status)." : message
    case GitHubError.graphQL(let errors):
        errors.first?.message ?? "GitHub could not answer the query."
    case GitHubError.decoding(let description):
        "GitHub's answer had an unexpected shape: \(description)"
    case GitHubError.commandFailed(let message):
        message
    case GitHubError.ghNotInstalled:
        "The GitHub CLI (gh) is not installed."
    case GitHubError.ghNotLoggedIn:
        "The GitHub CLI (gh) is not logged in."
    default:
        error.localizedDescription
    }
}

/// The app's state: who is signed in, the selected account's pull requests,
/// repositories and issues, and what the window shows.
@Observable
@MainActor
final class AppModel {
    enum Startup: Equatable {
        case loading
        case failed(StartupProblem)
        case ready(ViewerProfile)
    }

    static let issuePageSize = 30

    let client: GitHubClient
    let repoCache: RepoCache
    let sessions: SessionStore
    let checkouts = CheckoutFinder()
    private let defaults: UserDefaults

    // MARK: Account

    private(set) var startup: Startup = .loading
    private(set) var account: Account?

    var viewer: ViewerProfile? {
        if case .ready(let viewer) = startup { viewer } else { nil }
    }

    // MARK: Lists

    private(set) var pullRequests: [PullRequest] = []
    private(set) var repositories: [Repository] = []
    /// Node IDs of the open pull requests that ask for the viewer's review.
    private(set) var reviewRequested: Set<String> = []
    private(set) var issueLists: [RepositoryRef: IssueList] = [:]
    /// Pull requests and issues loaded one at a time, by number, because they
    /// are not in the lists above: closed ones, or ones in another account.
    private(set) var fetchedPullRequests: [ItemKey: PullRequest] = [:]
    private(set) var fetchedIssues: [ItemKey: Issue] = [:]
    private var fetchedStates: [ItemKey: LinkedPullRequest.State] = [:]

    /// True once the selected account's lists have loaded at least once.
    private(set) var hasLoaded = false
    private(set) var listError: String?
    private(set) var lastRefresh: Date?
    private var refreshingLogin: String?
    /// The lists each account showed last, by login. Switching back to an
    /// account shows them at once while they reload.
    private var remembered: [String: (pullRequests: [PullRequest], repositories: [Repository])] = [:]
    var isRefreshing: Bool { refreshingLogin != nil }

    // MARK: Settings

    var showingAllBots: Bool {
        didSet { defaults.set(showingAllBots, forKey: Keys.showingAllBots) }
    }
    /// Seconds between automatic reloads of the lists.
    var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    // MARK: Navigation

    var destination: Destination? {
        // Going anywhere else gives up on a by-number load still in flight.
        didSet { resolving = nil }
    }
    var scope: Scope = .filter(.needsReview)
    var repositoryList: RepositoryList = .pullRequests
    var pullRequestTab: PullRequestTab = .files {
        // Handed over once the Checks tab showed it, so picking the same check again is a change.
        didSet { if pullRequestTab != .checks { checkToOpen = nil } }
    }
    /// The check picked in a checks summary, shown first on the Checks tab.
    var checkToOpen: Check?
    /// Tree nodes the user opened or closed, by node ID. Other nodes use their default.
    var expansion: [String: Bool] = [:]
    /// The row the lists should scroll to. `serial` makes a repeated request a new value.
    private(set) var scrollRequest: (target: AnyHashable, serial: Int)?
    var isPaletteShown = false
    /// The origin of the session the launch sheet is about to start.
    var launching: SessionOrigin?
    /// A pull request or issue number the palette is loading.
    private(set) var resolving: ItemKey?
    var resolveError: String?

    private enum Keys {
        static let account = "selectedAccount"
        static let showingAllBots = "showingAllBots"
        static let refreshInterval = "refreshInterval"
    }

    init(
        client: GitHubClient = GitHubClient(), repoCache: RepoCache = RepoCache(),
        sessions: SessionStore = SessionStore(), defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.repoCache = repoCache
        self.sessions = sessions
        self.defaults = defaults
        showingAllBots = defaults.bool(forKey: Keys.showingAllBots)
        let interval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = interval > 0 ? interval : 60
    }

    // MARK: Startup and accounts

    /// Loads the viewer, picks the remembered account, and loads its lists.
    func start() async {
        startup = .loading
        do {
            let viewer = try await client.viewer()
            startup = .ready(viewer)
            let remembered = defaults.string(forKey: Keys.account)
            account = viewer.accounts.first { $0.login == remembered } ?? viewer.accounts.first
            for account in viewer.accounts {
                Task { _ = await AvatarCache.shared.image(for: account.avatarURL) }
            }
            await refresh()
        } catch {
            startup = .failed(StartupProblem(error))
        }
    }

    func select(_ account: Account) {
        guard account != self.account else { return }
        self.account = account
        defaults.set(account.login, forKey: Keys.account)

        let known = remembered[account.login]
        pullRequests = known?.pullRequests ?? []
        repositories = known?.repositories ?? []
        issueLists = [:]
        fetchedPullRequests = [:]
        fetchedIssues = [:]
        fetchedStates = [:]
        hasLoaded = known != nil
        listError = nil
        destination = nil
        scope = .filter(.needsReview)
        expansion = [:]
        Task { await refresh() }
    }

    // MARK: Loading

    /// Reloads the selected account's pull requests, repositories, and the
    /// issue lists that are open. Rows keep their identity, so selection and
    /// scroll position stay where they are.
    func refresh() async {
        guard let login = account?.login, refreshingLogin != login else { return }
        refreshingLogin = login
        defer { if refreshingLogin == login { refreshingLogin = nil } }

        async let loadedPullRequests = client.openPullRequests(owner: login)
        async let loadedRepositories = client.repositories(owner: login)
        async let requested = try? reviewRequestedIDs()
        do {
            let (pullRequests, repositories) = try await (loadedPullRequests, loadedRepositories)
            guard account?.login == login else { return }
            keepOpenPullRequest(missingFrom: pullRequests)
            self.pullRequests = pullRequests
            self.repositories = repositories
            remembered[login] = (pullRequests, repositories)
            listError = nil
            hasLoaded = true
            lastRefresh = .now
        } catch {
            guard account?.login == login else { return }
            listError = describe(error)
        }
        if let requested = await requested, account?.login == login { reviewRequested = requested }

        for repository in issueLists.keys { await reloadIssues(of: repository) }
    }

    /// Reloads when the lists are older than a few seconds, for app activation.
    func refreshIfStale() async {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 10 { return }
        await refresh()
    }

    /// Keeps the pull request in the detail pane readable after it leaves the
    /// open list, and loads whether it was merged or closed.
    private func keepOpenPullRequest(missingFrom reloaded: [PullRequest]) {
        guard case .pullRequest(let key) = destination, fetchedPullRequests[key] == nil,
              let open = pullRequests.first(where: { $0.key == key }),
              !reloaded.contains(where: { $0.key == key }) else { return }
        fetchedPullRequests[key] = open
        Task { await refetch(key) }
    }

    /// Loads one pull request or issue again and replaces the copy the app
    /// holds: the one in its list, or the one loaded by number. A pull request
    /// that is no longer open is also stored by number, with its state, so it
    /// stays readable after it leaves the open list.
    func refetch(_ key: ItemKey) async {
        let login = account?.login
        guard let item = try? await client.item(key), account?.login == login else { return }
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
            let page = try await client.issues(
                repository: repository, pageSize: Self.issuePageSize, after: list.endCursor
            )
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
        // Skip the result when the user loaded more pages or switched account meanwhile.
        guard let current = issueLists[repository], !current.isLoading, current.items.count == existing.items.count else { return }
        keepOpenIssue(in: repository, missingFrom: reloaded.items)
        issueLists[repository] = reloaded
    }

    /// Keeps the issue in the detail pane readable after it leaves the loaded
    /// part of its list, and loads whether it was closed.
    private func keepOpenIssue(in repository: RepositoryRef, missingFrom reloaded: [Issue]) {
        guard case .issue(let key) = destination, key.repository == repository,
              let open = issueLists[repository]?.items.first(where: { $0.number == key.number }),
              !reloaded.contains(where: { $0.number == key.number }) else { return }
        fetchedIssues[key] = open
        Task { await refetch(key) }
    }

    // MARK: Lookups

    var sections: [RepositorySection] {
        repositorySections(repositories: repositories, pullRequests: pullRequests, showingAllBots: showingAllBots)
    }

    /// The pull requests under an Inbox filter, grouped by repository.
    func sections(for filter: InboxFilter) -> [RepositorySection] {
        if filter == .all {
            return repositorySections(
                repositories: repositories, pullRequests: pullRequests, showingAllBots: showingAllBots, includingEmpty: false
            )
        }
        return repositorySections(
            repositories: repositories, pullRequests: pullRequests.filter(matcher(filter)), showingAllBots: true,
            includingEmpty: false
        )
    }

    func count(for filter: InboxFilter) -> Int {
        pullRequests.count(where: matcher(filter))
    }

    private func matcher(_ filter: InboxFilter) -> (PullRequest) -> Bool {
        let viewer = viewer?.login ?? ""
        let reviewRequested = reviewRequested
        let showingAllBots = showingAllBots
        return { filter.matches($0, viewer: viewer, reviewRequested: reviewRequested, showingAllBots: showingAllBots) }
    }

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

    /// Every loaded pull request of `pullRequest`'s stack, bottom first. Empty
    /// when it is not in a stack.
    /// The pull requests a merge of `pullRequest` lands: itself, and for a
    /// stacked one every member below it, bottom first.
    func mergeSet(of pullRequest: PullRequest) -> [PullRequest] {
        pullRequest.mergeSet(among: pullRequests)
    }

    /// Merges a pull request, and for a stacked one the members below it, then reloads them.
    func merge(_ pullRequest: PullRequest, method: MergeMethod) async throws {
        let merged = mergeSet(of: pullRequest)
        if pullRequest.stack != nil {
            try await client.mergeStack(repository: pullRequest.repository, upTo: pullRequest.number, method: method)
        } else {
            try await client.mergePullRequest(pullRequestID: pullRequest.id, method: method, expectedHeadOID: pullRequest.headOID)
        }
        for member in merged { await refetch(member.key) }
        await refresh()
    }

    func stack(of pullRequest: PullRequest) -> [PullRequest] {
        guard let stackID = pullRequest.stack?.stackID else { return [] }
        return pullRequests
            .filter { $0.stack?.stackID == stackID }
            .sorted { ($0.stack?.position ?? 0) < ($1.stack?.position ?? 0) }
    }

    /// The repository the user is looking at: the open item's, or the listed one.
    var currentRepository: RepositoryRef? {
        switch destination {
        case .pullRequest(let key), .issue(let key): return key.repository
        case .session(let id):
            if let session = sessions.sessions.first(where: { $0.id == id }) { return session.origin.repository }
        case nil: break
        }
        if case .repository(let repository) = scope { return repository }
        return nil
    }

    // MARK: Sessions

    func session(_ id: UUID) -> ClaudeSession? {
        sessions.sessions.first { $0.id == id }
    }

    func sessions(startedFrom key: ItemKey, isPullRequest: Bool) -> [ClaudeSession] {
        sessions.sessions.filter { $0.origin.key == key && $0.origin.isPullRequest == isPullRequest }
    }

    /// The open pull request a session works on: the one it was started from,
    /// or the one whose head branch is the session's branch.
    func linkedPullRequest(of session: ClaudeSession) -> PullRequest? {
        if session.origin.isPullRequest, let pullRequest = pullRequest(session.origin.key) { return pullRequest }
        guard let branch = session.branch else { return nil }
        return pullRequests.first { $0.repository == session.origin.repository && $0.headRefName == branch }
    }

    // MARK: Navigation

    func isExpanded(_ node: String, default defaultValue: Bool) -> Bool {
        expansion[node] ?? defaultValue
    }

    /// Shows `destination` in the detail pane and moves the lists to it.
    ///
    /// - Parameter tab: The pull request tab to open. Nil keeps the current tab.
    func navigate(to destination: Destination, tab: PullRequestTab? = nil) {
        self.destination = destination
        if let tab { pullRequestTab = tab }

        switch destination {
        case .pullRequest(let key):
            reveal(key.repository, list: .pullRequests)
            if let stackID = pullRequest(key)?.stack?.stackID { expansion["stack:\(stackID)"] = true }
            if let id = pullRequest(key)?.id { scroll(to: id) }
        case .issue(let key):
            reveal(key.repository, list: .issues)
            if let id = issue(key)?.id { scroll(to: id) }
        case .session:
            scope = .sessions
        }
    }

    /// Asks the lists to bring a row into view. `target` is the row's `ForEach` identity.
    func scroll(to target: AnyHashable) {
        scrollRequest = (target, (scrollRequest?.serial ?? 0) + 1)
    }

    /// Shows a repository's pull requests or issues in the lists.
    func reveal(_ repository: RepositoryRef, list: RepositoryList) {
        // An item a filter already lists stays in that filter.
        if case .filter(let filter) = scope, list == .pullRequests, case .pullRequest(let key) = destination,
           let pullRequest = pullRequest(key), matcher(filter)(pullRequest) { return }
        scope = .repository(repository)
        repositoryList = list
    }

    /// Moves to the neighboring pull request of the open one's stack.
    ///
    /// - Parameter offset: 1 for the next one up the stack, -1 for the next one down.
    func moveInStack(by offset: Int) {
        guard case .pullRequest(let key) = destination, let current = pullRequest(key) else { return }
        let stack = stack(of: current)
        guard let index = stack.firstIndex(where: { $0.id == current.id }), stack.indices.contains(index + offset) else { return }
        navigate(to: .pullRequest(stack[index + offset].key))
    }

    var canMoveDownStack: Bool { stackNeighbor(-1) != nil }
    var canMoveUpStack: Bool { stackNeighbor(1) != nil }

    private func stackNeighbor(_ offset: Int) -> PullRequest? {
        guard case .pullRequest(let key) = destination, let current = pullRequest(key) else { return nil }
        let stack = stack(of: current)
        guard let index = stack.firstIndex(where: { $0.id == current.id }), stack.indices.contains(index + offset) else { return nil }
        return stack[index + offset]
    }

    /// Opens the pull request or issue with this number, loading it from
    /// GitHub when it is not in the lists.
    func open(_ key: ItemKey) async {
        if pullRequest(key) != nil { return navigate(to: .pullRequest(key), tab: .files) }
        if issue(key) != nil { return navigate(to: .issue(key)) }

        resolving = key
        resolveError = nil
        do {
            let item = try await client.item(key)
            // The user went elsewhere or switched account meanwhile.
            guard resolving == key else { return }
            switch item {
            case .pullRequest(let pullRequest, let state):
                fetchedPullRequests[key] = pullRequest
                fetchedStates[key] = state
                navigate(to: .pullRequest(key), tab: .files)
            case .issue(let issue):
                fetchedIssues[key] = issue
                navigate(to: .issue(key))
            }
        } catch {
            guard resolving == key else { return }
            resolving = nil
            resolveError = "Could not open \(key): \(describe(error))"
        }
    }

    /// The origin a session starts from for the open pull request or issue.
    var launchableOrigin: SessionOrigin? {
        switch destination {
        case .pullRequest(let key): pullRequest(key).map(SessionOrigin.init)
        case .issue(let key): issue(key).map { SessionOrigin($0, in: key.repository) }
        case .session, nil: nil
        }
    }

    /// The GitHub page of what the detail pane shows.
    var destinationURL: URL? {
        switch destination {
        case .pullRequest(let key): pullRequest(key)?.url
        case .issue(let key): issue(key)?.url
        case .session(let id): session(id)?.origin.url
        case nil: nil
        }
    }
}

extension SessionOrigin {
    init(_ pullRequest: PullRequest) {
        self = .pullRequest(
            repository: pullRequest.repository, number: pullRequest.number, title: pullRequest.title,
            headRefName: pullRequest.headRefName, baseRefName: pullRequest.baseRefName, url: pullRequest.url
        )
    }

    init(_ issue: Issue, in repository: RepositoryRef) {
        self = .issue(repository: repository, number: issue.number, title: issue.title, url: issue.url)
    }

    var repository: RepositoryRef {
        switch self {
        case .pullRequest(let repository, _, _, _, _, _), .issue(let repository, _, _, _): repository
        }
    }

    var number: Int {
        switch self {
        case .pullRequest(_, let number, _, _, _, _), .issue(_, let number, _, _): number
        }
    }

    var url: URL {
        switch self {
        case .pullRequest(_, _, _, _, _, let url), .issue(_, _, _, let url): url
        }
    }

    var isPullRequest: Bool {
        if case .pullRequest = self { true } else { false }
    }

    var key: ItemKey { ItemKey(repository: repository, number: number) }
}

// MARK: Loading one item by number

/// A pull request or an issue, whichever a number names.
enum FetchedItem: Decodable, Sendable {
    case pullRequest(PullRequest, state: LinkedPullRequest.State)
    case issue(Issue)

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case state
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .typename) == "PullRequest" {
            self = .pullRequest(
                try PullRequest(from: decoder), state: try container.decode(LinkedPullRequest.State.self, forKey: .state)
            )
        } else {
            self = .issue(try Issue(from: decoder))
        }
    }
}

extension GitHubClient {
    /// Loads the pull request or issue with a number, in any state.
    ///
    /// The field lists repeat the ones `GitHubKit` uses for its list queries,
    /// because `PullRequest` and `Issue` decode exactly those fields.
    func item(_ key: ItemKey) async throws -> FetchedItem {
        struct Data: Decodable, Sendable {
            struct Repository: Decodable, Sendable { let issueOrPullRequest: FetchedItem }
            let repository: Repository
        }
        let user = "__typename login avatarUrl"
        let query = """
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                issueOrPullRequest(number: $number) {
                  __typename
                  ... on PullRequest {
                    id number title url state isDraft createdAt updatedAt headRefName baseRefName headRefOid
                    reviewDecision additions deletions changedFiles mergeable
                    repository { name owner { login } }
                    author { \(user) }
                    labels(first: 20) { nodes { name color } }
                    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
                    stack { id number size baseRefName }
                    stackEntry { position }
                    closingIssuesReferences(first: 20) { nodes { number } }
                  }
                  ... on Issue {
                    id number title url state createdAt updatedAt
                    author { \(user) }
                    labels(first: 20) { nodes { name color } }
                    comments { totalCount }
                    assignees(first: 20) { nodes { \(user) } }
                    closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
                      nodes { number title state headRefName }
                    }
                  }
                }
              }
            }
            """
        return try await graphQL(
            query,
            variables: ["owner": .string(key.repository.owner), "name": .string(key.repository.name), "number": .int(key.number)],
            as: Data.self
        ).repository.issueOrPullRequest
    }
}

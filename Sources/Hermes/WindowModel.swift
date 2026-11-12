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

/// One window's state: the account it shows and what it shows of it. The
/// data comes from the `AppStore` every window shares.
@Observable
@MainActor
final class WindowModel {
    typealias Startup = AppStore.Startup

    let store: AppStore

    // MARK: Account

    private(set) var account: Account?
    /// The account's lists, shared with the other windows that show it.
    var data: AccountData { store.data(for: account?.login ?? "") }

    var client: GitHubClient { store.client }
    var repoCache: RepoCache { store.repoCache }
    var sessions: SessionStore { store.sessions }
    var startup: Startup { store.startup }
    var viewer: ViewerProfile? { store.viewer }

    // MARK: Lists

    var pullRequests: [PullRequest] { data.pullRequests }
    var repositories: [Repository] { data.repositories }
    var hasLoaded: Bool { data.hasLoaded }
    var listError: String? { data.listError }
    var isRefreshing: Bool { data.isRefreshing }

    // MARK: Settings

    var showingAllBots: Bool {
        get { store.showingAllBots }
        set { store.showingAllBots = newValue }
    }
    var refreshInterval: TimeInterval {
        get { store.refreshInterval }
        set { store.refreshInterval = newValue }
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
    /// Where a link asked the open pull request's diff to go. The Files tab takes it.
    var diffTarget: DeepLink.PullRequestTarget?
    /// The comment a link asked the open conversation to scroll to, by its REST ID. The conversation takes it.
    var commentToShow: Int?
    /// A link that arrived before the accounts were loaded.
    var pendingLink: DeepLink?
    /// Tree nodes the user opened or closed, by node ID. Other nodes use their default.
    var expansion: [String: Bool] = [:]
    /// The row the lists should scroll to. `serial` makes a repeated request a new value.
    private(set) var scrollRequest: (target: AnyHashable, serial: Int)?
    var isPaletteShown = false
    /// The sheet that asks for a link to open in a new window.
    var isOpenLinkShown = false
    /// The origin of the session the launch sheet is about to start.
    var launching: SessionOrigin?
    /// A pull request or issue number the palette is loading.
    private(set) var resolving: ItemKey?
    var resolveError: String?

    init(store: AppStore) {
        self.store = store
    }

    /// Makes a window model with its own store, for tests and snapshots.
    convenience init(
        client: GitHubClient = GitHubClient(), repoCache: RepoCache = RepoCache(),
        sessions: SessionStore = SessionStore(), defaults: UserDefaults = .standard
    ) {
        self.init(store: AppStore(client: client, repoCache: repoCache, sessions: sessions, defaults: defaults))
    }

    // MARK: Startup and accounts

    /// Signs in when no window has yet, picks the window's account, and loads its lists.
    ///
    /// - Parameter login: The account to show. Nil shows the account picked last.
    func start(login: String? = nil) async {
        if store.viewer == nil { await store.start() }
        guard let viewer = store.viewer else { return }
        if account == nil { account = store.account(login ?? store.lastLogin) ?? viewer.accounts.first }
        if let link = pendingLink {
            pendingLink = nil
            Task { await open(link) }
        }
        await refresh()
    }

    func select(_ account: Account) {
        guard account != self.account else { return }
        self.account = account
        store.lastLogin = account.login
        destination = nil
        scope = .filter(.needsReview)
        expansion = [:]
        Task { await refresh() }
    }

    // MARK: Loading

    /// Reloads everything, repositories included. For ⌘R and the Refresh buttons.
    func refresh() async { await data.refresh(everything: true) }
    func refreshIfStale() async { await data.refreshIfStale() }
    func refetch(_ key: ItemKey) async { await data.refetch(key) }

    // MARK: Issues

    func issueList(of repository: RepositoryRef) -> IssueList { data.issueList(of: repository) }
    func loadMoreIssues(of repository: RepositoryRef) async { await data.loadMoreIssues(of: repository) }
    func reloadIssues(of repository: RepositoryRef) async { await data.reloadIssues(of: repository) }

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
        let reviewRequested = data.reviewRequested
        let showingAllBots = showingAllBots
        return { filter.matches($0, viewer: viewer, reviewRequested: reviewRequested, showingAllBots: showingAllBots) }
    }

    func pullRequest(_ key: ItemKey) -> PullRequest? { data.pullRequest(key) }

    /// Merged or closed, for a pull request that is not in the open list. Nil when unknown.
    func closedState(of key: ItemKey) -> LinkedPullRequest.State? { data.closedState(of: key) }

    func issue(_ key: ItemKey) -> Issue? { data.issue(key) }

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

    /// Every loaded pull request of `pullRequest`'s stack, bottom first. Empty when it is not in a stack.
    func stack(of pullRequest: PullRequest) -> [PullRequest] { data.stack(of: pullRequest) }

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
            data.store(item, for: key)
            switch item {
            case .pullRequest: navigate(to: .pullRequest(key), tab: .files)
            case .issue: navigate(to: .issue(key))
            }
        } catch {
            guard resolving == key else { return }
            resolving = nil
            resolveError = "Could not open \(key): \(describe(error))"
        }
    }

    /// A `hermes://` link to what the window shows, which a restored window opens again.
    var placeURL: URL? {
        let path: String? = switch destination {
        case .pullRequest(let key): "\(key.repository)/pull/\(key.number)"
        case .issue(let key): "\(key.repository)/issues/\(key.number)"
        // Sessions end with the app, so a restored window can't show one.
        case .session, nil: if case .repository(let repository) = scope { "\(repository)" } else { nil }
        }
        return path.flatMap { URL(string: "hermes://\($0)") }
    }

    /// Opens a window of its own on the same account, showing `link`, or the account's lists when it is nil.
    func openWindow(showing url: URL? = nil) {
        store.openWindow?(WindowState(login: account?.login, url: url))
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

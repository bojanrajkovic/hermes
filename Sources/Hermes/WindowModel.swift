import AppKit
import Foundation
import GitHubKit
import HermesUI
import RepoKit
import SessionsUI
import StateKit

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

/// One window's state: the account it shows and what it shows of it. The
/// data comes from the `AppStore` every window shares.
@Observable
@MainActor
final class WindowModel {
    typealias Startup = AppStore.Startup

    let store: AppStore

    // MARK: Account

    private(set) var account: Account?
    /// The window's account login. Empty before the window has an account.
    var login: String { account?.login ?? "" }
    var github: GitHubStore { store.github }

    var client: GitHubClient { store.client }
    var repoCache: RepoCache { store.repoCache }
    var sessions: SessionStore { store.sessions }
    var startup: Startup { store.startup }
    var viewer: ViewerProfile? { store.viewer }

    // MARK: Lists

    /// The account's pull requests, without those in ignored repositories. Every list reads these.
    var pullRequests: [PullRequest] {
        let ignored = store.ignored
        let open = github.openPullRequests(of: login)
        return ignored.isEmpty ? open : open.filter { !ignored.contains($0.repository) }
    }
    var repositories: [Repository] {
        let ignored = store.ignored
        let owned = github.repositories(of: login)
        return ignored.isEmpty ? owned : owned.filter { !ignored.contains($0.ref) }
    }
    var hasLoaded: Bool { github.lists(of: login).hasLoaded }
    var listError: String? { github.lists(of: login).listError }
    var isRefreshing: Bool { github.lists(of: login).isRefreshing }

    // MARK: Settings

    var showingAllBots: Bool {
        get { store.showingAllBots }
        set { store.showingAllBots = newValue }
    }

    // MARK: Navigation

    var destination: Destination? {
        // Going anywhere else gives up on a by-number load still in flight.
        didSet { resolving = nil }
    }
    var scope: Scope = .filter(.needsAttention)
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
        store.windows.add(self)
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
        scope = .filter(.needsAttention)
        expansion = [:]
        Task { await refresh() }
    }

    // MARK: Loading

    /// Reloads everything, repositories included. For ⌘R and the Refresh buttons.
    func refresh() async { await github.refresh(login, everything: true) }
    func refreshIfStale() async { await github.refreshIfStale(login) }
    func refetch(_ key: ItemKey) async { await github.refetch(key) }

    // MARK: Issues

    func issueList(of repository: RepositoryRef) -> IssueList { github.issueList(of: repository) }
    func listedIssues(of repository: RepositoryRef) -> [Issue] { github.listedIssues(of: repository) }
    /// Open issues across all pages. Nil until a repository load or an issue page reports it.
    func openIssueCount(of repository: RepositoryRef) -> Int? { github.openIssueCount(of: repository) }
    func loadMoreIssues(of repository: RepositoryRef) async { await github.loadMoreIssues(of: repository) }
    func reloadIssues(of repository: RepositoryRef) async { await github.reloadIssues(of: repository) }

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
        let attention = github.attention(of: login)
        let showingAllBots = showingAllBots
        let now = Date.now
        return { filter.matches($0, viewer: viewer, attention: attention, now: now, showingAllBots: showingAllBots) }
    }

    /// The attention inbox: the pull requests that need the viewer, each with its strongest reason, ranked.
    var attentionItems: [(pullRequest: PullRequest, reason: AttentionReason)] {
        attentionList(
            pullRequests.filter(matcher(.needsAttention)), viewer: viewer?.login ?? "", signals: github.attention(of: login), now: .now
        )
    }

    /// The open pull request, when one is.
    var openPullRequest: ItemKey? {
        if case .pullRequest(let key) = destination { key } else { nil }
    }

    /// The pull requests in the list on screen, top first.
    var listedPullRequests: [PullRequest] {
        switch scope {
        case .filter(.needsAttention): attentionItems.map(\.pullRequest)
        case .filter(let filter): pullRequests.filter(matcher(filter))
        case .repository(let repository):
            pullRequests.filter { $0.repository == repository && $0.isShown(showingAllBots: showingAllBots) }
        case .sessions: []
        }
    }

    func pullRequest(_ key: ItemKey) -> PullRequest? { github.pullRequest(key) }

    /// Merged or closed. Nil for an open pull request or one that isn't loaded.
    func closedState(of key: ItemKey) -> LinkedPullRequest.State? {
        github.pullRequest(key).flatMap { $0.state == .open ? nil : $0.state }
    }

    func issue(_ key: ItemKey) -> Issue? { github.issue(key) }

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

    /// Turns auto-merge on with `method`, or off when `method` is nil, then reloads the pull request.
    func setAutoMerge(_ pullRequest: PullRequest, method: MergeMethod?) async throws {
        if let method {
            try await client.enableAutoMerge(pullRequestID: pullRequest.id, method: method, expectedHeadOID: pullRequest.headOID)
        } else {
            try await client.disableAutoMerge(pullRequestID: pullRequest.id)
        }
        await refetch(pullRequest.key)
    }

    /// Every loaded pull request of `pullRequest`'s stack, bottom first. Empty when it is not in a stack.
    func stack(of pullRequest: PullRequest) -> [PullRequest] { github.stack(of: pullRequest) }

    /// The repository the user is looking at: the open item's, or the listed one.
    var currentRepository: RepositoryRef? {
        switch destination {
        case .pullRequest(let key), .issue(let key): return key.repository
        case .session(let id):
            if let session = sessions.sessions.first(where: { $0.id == id }) { return session.origin.repository }
        case .localBranch(let key): return key.repository
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
        return pullRequest(headedBy: branch, in: session.origin.repository)
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
        case .localBranch(let key):
            reveal(key.repository, list: .localStacks)
            scroll(to: key)
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

    /// Moves to the neighbor of the open item in its stack.
    ///
    /// - Parameter offset: 1 for the next one up the stack, -1 for the next one down.
    func moveInStack(by offset: Int) {
        if let neighbor = stackNeighbor(offset) { navigate(to: neighbor) }
    }

    var canMoveDownStack: Bool { stackNeighbor(-1) != nil }
    var canMoveUpStack: Bool { stackNeighbor(1) != nil }

    private func stackNeighbor(_ offset: Int) -> Destination? {
        let sequence = stackSequence
        guard let destination, let index = sequence.firstIndex(of: destination), sequence.indices.contains(index + offset) else {
            return nil
        }
        return sequence[index + offset]
    }

    /// The open item's stack, bottom first. For a pull request: its stack on
    /// GitHub, then the local branches built on its top that have no pull
    /// request yet. For a local branch: its local stack, where a branch with an
    /// open pull request is that pull request. Empty when there is no stack.
    var stackSequence: [Destination] {
        switch destination {
        case .pullRequest(let key):
            guard let pullRequest = pullRequest(key) else { return [] }
            let stacked = stack(of: pullRequest)
            let members = stacked.isEmpty ? [pullRequest] : stacked
            let above = localStacks.entry(key.repository)?.stacks.branches(above: members[members.count - 1].headRefName) ?? []
            let local = above
                .filter { self.pullRequest(headedBy: $0.name, in: key.repository) == nil }
                .map { Destination.localBranch(LocalBranchKey(repository: key.repository, branch: $0.name)) }
            let sequence = members.map { Destination.pullRequest($0.key) } + local
            return sequence.count > 1 ? sequence : []
        case .localBranch(let key):
            guard let stack = localStacks.entry(key.repository)?.stacks.stack(containing: key.branch),
                  stack.branches.count > 1 else { return [] }
            return stack.branches.map { destination(ofBranch: $0.name, in: key.repository) }
        case .issue, .session, nil:
            return []
        }
    }

    var localStacks: LocalStacks { store.localStacks }

    /// The open pull request whose head is this branch.
    func pullRequest(headedBy branch: String, in repository: RepositoryRef) -> PullRequest? {
        pullRequests.first { $0.repository == repository && $0.headRefName == branch }
    }

    /// Where a local branch leads: its open pull request, or the branch screen.
    func destination(ofBranch branch: String, in repository: RepositoryRef) -> Destination {
        if let pullRequest = pullRequest(headedBy: branch, in: repository) { return .pullRequest(pullRequest.key) }
        return .localBranch(LocalBranchKey(repository: repository, branch: branch))
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
            github.store(item, for: key)
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
        // Sessions end with the app, so a restored window can't show one. Local branches have no link.
        case .session, .localBranch, nil: if case .repository(let repository) = scope { "\(repository)" } else { nil }
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
        case .session, .localBranch, nil: nil
        }
    }

    /// The GitHub page of what the detail pane shows.
    var destinationURL: URL? {
        switch destination {
        case .pullRequest(let key): pullRequest(key)?.url
        case .issue(let key): issue(key)?.url
        case .session(let id): session(id)?.origin.url
        case .localBranch, nil: nil
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

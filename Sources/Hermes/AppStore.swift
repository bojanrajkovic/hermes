import AppKit
import Foundation
import GitHubKit
import HermesUI
import RepoKit
import SessionsUI
import StateKit

/// What every window shares: the signed-in user, the GitHub store, Claude
/// sessions, and settings. Each window has its own `WindowModel` on top.
@Observable
@MainActor
final class AppStore {
    enum Startup: Equatable {
        case loading
        case failed(StartupProblem)
        case ready(ViewerProfile)
    }

    let client: GitHubClient
    /// Everything Hermes knows about GitHub, for every account.
    let github: GitHubStore
    let repoCache: RepoCache
    let sessions: SessionStore
    let localStacks: LocalStacks
    private let defaults: UserDefaults

    private(set) var startup: Startup = .loading
    /// The window that was key last. Links open there.
    @ObservationIgnored weak var frontmost: WindowModel?
    /// Every window that is up.
    @ObservationIgnored let windows = NSHashTable<WindowModel>.weakObjects()
    /// Opens a window. Set by the first window, since only a view can open one.
    @ObservationIgnored var openWindow: ((WindowState) -> Void)?
    /// Links that arrived before any window was up.
    @ObservationIgnored private var waitingLinks: [URL] = []

    var viewer: ViewerProfile? {
        if case .ready(let viewer) = startup { viewer } else { nil }
    }

    /// The account a new window shows: the one picked last in any window.
    var lastLogin: String? {
        get { defaults.string(forKey: Keys.account) }
        set { defaults.set(newValue, forKey: Keys.account) }
    }

    /// False until the user finishes first-run setup. Everyone sees it once, existing users included.
    var hasFinishedSetup: Bool {
        didSet { defaults.set(hasFinishedSetup, forKey: Keys.finishedSetup) }
    }

    /// Repositories left out of every list, the sidebar, and ⌘K. Their pull requests still open from a link.
    var ignoredRepositories: Set<RepositoryRef> {
        didSet { defaults.set(ignoredRepositories.map(\.description).sorted(), forKey: Keys.ignoredRepositories) }
    }

    /// The ignore list in force: empty when the app was launched with `HERMES_SHOW_IGNORED=1`.
    var ignored: Set<RepositoryRef> {
        ProcessInfo.processInfo.environment["HERMES_SHOW_IGNORED"] == "1" ? [] : ignoredRepositories
    }

    /// Every repository Hermes has loaded in any account, for the ignore list's picker.
    var knownRepositories: [RepositoryRef] {
        Set(github.repositories.keys).union(github.pullRequests.keys.map(\.repository))
            .sorted { $0.description.localizedStandardCompare($1.description) == .orderedAscending }
    }

    /// A `hermes://` link to what the window used last showed. The first window of a launch opens
    /// there when macOS does not restore windows.
    var lastPlace: URL? {
        get { defaults.url(forKey: Keys.lastPlace) }
        set { defaults.set(newValue, forKey: Keys.lastPlace) }
    }

    var showingAllBots: Bool {
        didSet { defaults.set(showingAllBots, forKey: Keys.showingAllBots) }
    }
    /// Seconds between automatic reloads of the lists.
    var refreshInterval: TimeInterval {
        didSet {
            defaults.set(refreshInterval, forKey: Keys.refreshInterval)
            github.backgroundInterval = refreshInterval
        }
    }

    /// Whether Hermes runs webhook forwarders. Off until the user asks: each one creates a
    /// webhook on a repository.
    var usesWebhooks: Bool {
        didSet {
            defaults.set(usesWebhooks, forKey: Keys.usesWebhooks)
            Task {
                await checkOrganizationHookScope()
                await syncForwarders()
            }
        }
    }
    let forwarders = Forwarders()
    /// The relay tenants this Mac uses.
    let relays: Relays
    /// Whether the `gh` token may create an organization's webhook, or nil until the first
    /// check answers. Checked when Hermes comes to the front, which is when a `gh auth refresh`
    /// in a terminal has just finished.
    private(set) var hasOrganizationHookScope: Bool?

    /// The organizations the viewer owns. Each can have one forwarder for all its repositories.
    var ownedOrganizations: [String] {
        (viewer?.organizations ?? []).filter(\.canAdminister).map(\.login)
    }

    /// The owned organizations the user picked to forward. None until they pick: the webhook
    /// is one every owner of the organization sees.
    var forwardedOrganizations: Set<String> {
        didSet {
            defaults.set(forwardedOrganizations.sorted(), forKey: Keys.forwardedOrganizations)
            Task {
                await checkOrganizationHookScope()
                await syncForwarders()
            }
        }
    }

    func checkOrganizationHookScope() async {
        guard usesWebhooks else { return }
        hasOrganizationHookScope = await GitHubAuth.scopes().contains(WebhookForwarder.organizationScope)
    }

    private enum Keys {
        static let usesWebhooks = "usesWebhooks"
        static let forwardedOrganizations = "forwardedOrganizations"
        static let account = "selectedAccount"
        static let showingAllBots = "showingAllBots"
        static let refreshInterval = "refreshInterval"
        static let finishedSetup = "finishedSetup"
        static let ignoredRepositories = "ignoredRepositories"
        static let lastPlace = "lastPlace"
    }

    init(
        client: GitHubClient = GitHubClient(), repoCache: RepoCache = RepoCache(),
        sessions: SessionStore = SessionStore(), defaults: UserDefaults = .standard
    ) {
        self.client = client
        github = GitHubStore(client: client)
        self.repoCache = repoCache
        self.sessions = sessions
        localStacks = LocalStacks(sessions: sessions)
        self.defaults = defaults
        relays = Relays(defaults: defaults)
        showingAllBots = defaults.bool(forKey: Keys.showingAllBots)
        hasFinishedSetup = defaults.bool(forKey: Keys.finishedSetup)
        ignoredRepositories = Set((defaults.stringArray(forKey: Keys.ignoredRepositories) ?? []).compactMap { saved in
            let parts = saved.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 ? RepositoryRef(owner: parts[0], name: parts[1]) : nil
        })
        usesWebhooks = defaults.bool(forKey: Keys.usesWebhooks)
        forwardedOrganizations = Set(defaults.stringArray(forKey: Keys.forwardedOrganizations) ?? [])
        let interval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = interval > 0 ? interval : 60
        github.backgroundInterval = refreshInterval
        github.isActive = { NSApp?.isActive ?? true }
        github.watched = { [weak self] login in self?.watched(in: login) ?? [] }
        relays.onEvent = { [weak self] event in
            guard let webhook = WebhookEvent(payload: event.payload) else {
                return Relays.log.info("relay event \(event.name, privacy: .public) names no repository")
            }
            Relays.log.info("relay event \(event.name, privacy: .public) for \(webhook.repository.description, privacy: .public)")
            self?.reload(webhook, part: EventPart(event: event.name))
        }
    }

    /// Loads the signed-in user once. Windows that open later reuse it.
    func start() async {
        startup = .loading
        do {
            let viewer = try await client.viewer()
            github.signedIn(as: viewer.login)
            startup = .ready(viewer)
            for account in viewer.accounts {
                Task { _ = await AvatarCache.shared.image(for: account.avatarURL) }
            }
        } catch {
            startup = .failed(StartupProblem(error))
        }
    }

    /// Keeps the webhook forwarders in step with the settings and the windows, until its task
    /// is cancelled. The store polls GitHub itself while windows show its accounts.
    func keepForwardersInSync() async {
        while (try? await Task.sleep(for: GitHubStore.tick)) != nil { await syncForwarders() }
    }

    /// Runs a forwarder for each organization the user picked and each of the viewer's own
    /// repositories that a window watches, or none when the setting is off. A repository a
    /// relay covers gets none.
    func syncForwarders() async {
        relays.sync()
        guard usesWebhooks, let viewer = viewer?.login else { return forwarders.stopAll() }
        let logins = Set(windows.allObjects.compactMap { $0.account?.login })
        let wanted = Forwarders.targets(
            watched: logins.sorted().flatMap { watched(in: $0) }.map(\.repository), viewer: viewer,
            organizations: hasOrganizationHookScope == true ? forwardedOrganizations.intersection(ownedOrganizations) : [],
            waiting: forwarders.waiting, covered: relays.covered
        )
        await forwarders.sync(to: wanted) { [weak self] event in self?.reload(event) }
    }

    /// Takes in what a webhook says changed and puts it in the store. For a pull request
    /// Hermes holds, the change goes into its record, detail, or checks. What the payload
    /// can't carry loads instead, but only while a screen shows it. A pull request Hermes doesn't
    /// hold loads the account, which is how a new pull request joins the lists.
    ///
    /// - Parameter part: Which part of the pull request changed, when the event's name says
    ///   and the payload can't be read.
    private func reload(_ event: WebhookEvent, part: EventPart? = nil) {
        // A relay sends events for every repository the user can see. One in an account no
        // window shows has nothing to update.
        guard windows.allObjects.contains(where: { $0.account?.login == event.repository.owner }) else { return }
        let login = event.repository.owner
        if let number = event.issue { return reloadIssue(ItemKey(repository: event.repository, number: number)) }
        let held = event.pullRequest(among: github.heldPullRequests)
        Forwarders.log.debug("event for \(event.repository.description, privacy: .public) #\(held?.number ?? 0)")

        guard let held else {
            // The account's own load finds a new pull request, and one whose new head Hermes has
            // not heard of yet. A busy repository sends many such events, so they share loads.
            return load(.account(login)) { [github] in await github.refresh(login) }
        }
        let key = held.key
        let head = CommitKey(repository: held.repository, oid: held.headOID)
        switch event.change {
        case .pullRequest(let fields, let reloads)?:
            // Deliveries can arrive out of order. A payload older than the record's last changes nothing.
            if github.apply(fields, to: key) { applyToDetail(event.change, of: key) }
            if reloads { load(.record(key)) { [github] in await github.refetch(key) } }
        case .comment?:
            // A comment changes nothing a row shows.
            applyToDetail(event.change, of: key)
        case .review?:
            applyToDetail(event.change, of: key)
            // The row's review decision is GitHub's to work out.
            load(.record(key)) { [github] in await github.refetch(key) }
        case .reply?, .threadResolved?, .threads?:
            // A row shows none of it.
            if let change = event.change, !github.applyToThreads(change, for: key) { loadDetailIfShown(key) }
        case .status?, .checkRun?, .checks?:
            // The checks shown are the head commit's. A check on an older commit isn't among them.
            if let change = event.change, event.commit == held.headOID, !github.applyToChecks(change, for: head) {
                loadChecksIfShown(head)
            }
            // The row's rollup is GitHub's to work out.
            load(.record(key)) { [github] in await github.refetch(key) }
        case nil:
            // A forwarder's delivery has no name. One that names a commit is a status or a check.
            switch part ?? (event.commit == nil ? nil : .checks) {
            case .threads?: loadDetailIfShown(key)
            case .checks?: loadChecksIfShown(head)
            case nil: loadDetailIfShown(key)
            }
            load(.record(key)) { [github] in await github.refetch(key) }
        }
    }

    /// Puts a change into the pull request's detail, or loads the detail when the change can't go in.
    private func applyToDetail(_ change: WebhookChange?, of key: ItemKey) {
        if let change, github.applyToDetail(change, for: key) { return }
        loadDetailIfShown(key)
    }

    /// Loads a pull request's detail while a screen shows the pull request. A closed one
    /// loads its detail when it opens again, so a change it missed shows then.
    private func loadDetailIfShown(_ key: ItemKey) {
        guard github.isShowing(.pullRequest(key)) else { return }
        load(.detail(key)) { [github] in await github.loadDetail(key) }
    }

    /// Loads a commit's checks while a screen shows them. A screen that opens later loads them itself.
    private func loadChecksIfShown(_ commit: CommitKey) {
        guard github.isShowing(.checks(commit)) else { return }
        load(.checks(commit)) { [github] in await github.loadChecks(commit) }
    }

    /// An issue was opened, closed, edited, or commented on. Its record and its repository's
    /// loaded list load again, when the store holds them. The list's page carries the
    /// repository's open issue count.
    private func reloadIssue(_ key: ItemKey) {
        if github.issue(key) != nil { load(.record(key)) { [github] in await github.refetch(key) } }
        if github.issueLists[key.repository] != nil {
            load(.issues(key.repository)) { [github] in await github.reloadIssues(of: key.repository) }
        }
    }

    /// Runs `operation` for the first event of a burst that loads `target`, and once more, a
    /// few seconds later, for the events that came while it ran.
    private func load(_ target: EventLoad, _ operation: @escaping () async -> Void) {
        guard bursts.shouldLoad(target) else { return }
        Task {
            repeat {
                await operation()
                try? await Task.sleep(for: Self.eventSpacing)
            } while bursts.loaded(target)
        }
    }

    /// How long after loading a pull request for an event Hermes waits before loading it
    /// again for the events that came meanwhile.
    static let eventSpacing: Duration = .seconds(5)
    @ObservationIgnored private var bursts = EventBursts()

    /// Opens a link in the frontmost window, or in a new window when it ends in `?window=new`
    /// or no window is up. A link Hermes can't read is reported in the frontmost window.
    func open(_ url: URL) {
        if let link = RelayLink(url: url) { return open(link) }
        guard let link = DeepLink(url: url) else {
            frontmost?.resolveError = "Hermes can't open \(url.absoluteString)."
            return
        }
        let asksForWindow = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "window" && $0.value == "new" } == true
        if let frontmost, !asksForWindow {
            Task { await frontmost.open(link) }
        } else if let openWindow {
            openWindow(WindowState(url: url))
        } else {
            waitingLinks.append(url)
        }
    }

    /// Takes one step of setting up or joining a relay tenant. A link that fails is reported
    /// in the frontmost window.
    private func open(_ link: RelayLink) {
        switch link {
        case .setup(let code, let state):
            // GitHub sends back the state Hermes gave it. Any other link was not asked for.
            guard relays.setup?.state == state else {
                frontmost?.resolveError = "This relay setup link does not belong to a setup Hermes started."
                return
            }
            Task { await relays.finishSetup(code: code) }
        case .session(let tenantID, let grant, let state):
            Task {
                if let error = await relays.finishSignIn(tenantID: tenantID, grant: grant, state: state) {
                    frontmost?.resolveError = error
                }
                await syncForwarders()
            }
        case .join(let tenant):
            if let refusal = relays.refusal(of: tenant) {
                frontmost?.resolveError = refusal
                return
            }
            let host = tenant.server.host() ?? tenant.server.absoluteString
            guard offersRelay(tenant, question: "Join the relay at \(host)?", accept: "Join", decline: "Cancel") else { return }
            relays.join(tenant)
            // The tenant's owner may have published it since the launch read the accounts' files.
            Task { await loadPublishedRelays() }
        }
    }

    /// Asks whether to use a relay tenant. A link or a published file can come from someone
    /// else, so the user sees the server before anything is sent to it.
    private func offersRelay(_ tenant: RelayTenant, question: String, accept: String, decline: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "The relay is at \(tenant.server.host() ?? tenant.server.absoluteString). Hermes opens your browser to sign in with GitHub. GitHub shows which account owns the relay's App. Cancel there if it is not the account you expect. The relay then sends this Mac the changes in the repositories you can see, as they happen."
        alert.addButton(withTitle: accept)
        alert.addButton(withTitle: decline)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Looks, once a launch, for a relay tenant that each of the viewer's accounts publishes
    /// in its `.github-private` repository, and asks about the ones this Mac does not use. A tenant
    /// the user turns down is not asked about again. Settings lists it, with a Connect button.
    func discoverRelays() async {
        guard !hasLookedForRelays, viewer != nil else { return }
        hasLookedForRelays = true

        for published in await loadPublishedRelays() where relays.shouldOffer(published.tenant) {
            let name = account(published.account)?.name ?? published.account
            if offersRelay(published.tenant, question: "\(name) has a relay. Connect?", accept: "Connect", decline: "Not Now") {
                relays.join(published.tenant, organization: published.organization)
            } else {
                relays.decline(published.tenant)
            }
        }
    }

    /// Reads the relay tenant each of the viewer's accounts publishes, and records them. The
    /// launch reads them, and so does joining a tenant by a link, which names no account.
    @discardableResult
    private func loadPublishedRelays() async -> [PublishedRelay] {
        var published: [PublishedRelay] = []
        for account in viewer?.accounts ?? [] {
            // An account with no file, and one that can't be read, publishes no relay.
            if let tenant = try? await client.publishedRelay(of: account.login) {
                published.append(PublishedRelay(account: account.login, isOrganization: account.kind == .organization, tenant: tenant))
            }
        }
        relays.found(published)
        return published
    }

    @ObservationIgnored private var hasLookedForRelays = false

    /// Called by a window once it is up, to open the links that came first.
    func windowIsUp() {
        let links = waitingLinks
        waitingLinks = []
        for url in links { open(url) }
    }

    /// The account with this login, when the viewer has it.
    func account(_ login: String?) -> Account? {
        viewer?.accounts.first { $0.login.caseInsensitiveCompare(login ?? "") == .orderedSame }
    }

    /// The pull requests an account's windows show, most important first: the open ones,
    /// those with a session, the attention inbox, then the lists on screen.
    private func watched(in login: String) -> [ItemKey] {
        let windows = windows.allObjects.filter { $0.account?.login == login }
        guard let window = windows.first else { return [] }
        return windows.compactMap(\.openPullRequest)
            + sessions.sessions.compactMap { window.linkedPullRequest(of: $0)?.key }
            + window.attentionItems.map(\.pullRequest.key)
            + windows.flatMap(\.listedPullRequests).map(\.key)
    }
}

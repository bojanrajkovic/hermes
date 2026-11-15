import AppKit
import Foundation
import GitHubKit
import HermesUI
import RepoKit
import SessionsUI

/// What every window shares: the signed-in user, each account's data, Claude
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
    // Filled in while a view reads it, so it is not observed. The entries are, and an entry is never replaced.
    @ObservationIgnored private var accounts: [String: AccountData] = [:]

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
        Set(accounts.values.flatMap { $0.repositories.map(\.ref) + $0.pullRequests.map(\.repository) })
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
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
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
        relays.onEvent = { [weak self] event in
            guard let webhook = WebhookEvent(payload: event.payload) else { return }
            self?.reload(webhook, part: EventCounts.part(ofEvent: event.name))
        }
    }

    /// Loads the signed-in user once. Windows that open later reuse it.
    func start() async {
        startup = .loading
        do {
            let viewer = try await client.viewer()
            startup = .ready(viewer)
            for account in viewer.accounts {
                Task { _ = await AvatarCache.shared.image(for: account.avatarURL) }
            }
        } catch {
            startup = .failed(StartupProblem(error))
        }
    }

    /// How often the lists refresh while Hermes is the active app.
    static let activeRefreshInterval: TimeInterval = 15

    /// Refreshes every account a window shows, until its task is cancelled: every 15 seconds
    /// while Hermes is the active app, and every `refreshInterval` otherwise. One loop for the
    /// app, so two windows on an account cost one refresh.
    func keepFresh() async {
        var refreshedAt = Date.now
        while (try? await Task.sleep(for: .seconds(Self.activeRefreshInterval))) != nil {
            await syncForwarders()
            guard NSApp.isActive || Date.now.timeIntervalSince(refreshedAt) >= refreshInterval else { continue }
            refreshedAt = .now
            let logins = Set(windows.allObjects.compactMap { $0.account?.login })
            await withTaskGroup(of: Void.self) { group in
                for login in logins { group.addTask { await self.data(for: login).refresh() } }
            }
        }
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

    /// What deliveries have said about each pull request's description and conversation,
    /// review threads, and checks. The screens that show those apply the latest change, or
    /// reload, when a count rises.
    private(set) var eventCounts: [ItemKey: EventCounts] = [:]

    private func note(_ change: WebhookChange?, in part: EventCounts.Part, of key: ItemKey) {
        eventCounts[key, default: EventCounts()][keyPath: part].note(change)
    }

    /// Takes in what a webhook says changed. For a pull request Hermes holds, it applies the
    /// fields the payload carries, and loads the pull request when the event changed more
    /// than that. Otherwise it loads the account, which is how a new pull request joins the lists.
    ///
    /// - Parameter part: The count to raise for the pull request, when the event's name says
    ///   which part of it changed. A forwarder's deliveries carry no name.
    private func reload(_ event: WebhookEvent, part: EventCounts.Part? = nil) {
        // A relay sends events for every repository the user can see. One in an account no
        // window shows has nothing to update.
        guard windows.allObjects.contains(where: { $0.account?.login == event.repository.owner }) else { return }
        let data = data(for: event.repository.owner)
        let held = event.pullRequest(among: data.heldPullRequests)
        Forwarders.log.debug("event for \(event.repository.description, privacy: .public) #\(held?.number ?? 0)")

        guard let held else {
            // The account's own load finds a new pull request, and one whose new head Hermes has
            // not heard of yet. A busy repository sends many such events, so they share loads.
            return load(ItemKey(repository: RepositoryRef(owner: data.login, name: ""), number: 0), part: nil) {
                await data.refresh()
            }
        }
        let key = held.key
        switch event.change {
        case .pullRequest(let fields, let reloads):
            data.store(.pullRequest(held.applying(fields)), for: key)
            note(event.change, in: \.detail, of: key)
            // A load that is running may have asked GitHub before this change, so it runs once more.
            guard reloads else { return bursts.applied(key) }
        case .comment:
            // A comment changes nothing a row shows.
            return note(event.change, in: \.detail, of: key)
        case .review:
            // The row's review decision is GitHub's to work out.
            note(event.change, in: \.detail, of: key)
        case nil:
            break
        }
        load(key, part: part) { await data.refetch(key) }
    }

    /// Runs `operation` for the first event of a burst about `key`, and once more, a few
    /// seconds later, for the events that came while it ran.
    private func load(_ key: ItemKey, part: EventCounts.Part?, _ operation: @escaping () async -> Void) {
        guard bursts.shouldLoad(key, part: part) else { return }
        if let part { note(nil, in: part, of: key) }

        Task {
            while true {
                await operation()
                try? await Task.sleep(for: Self.eventSpacing)
                guard let parts = bursts.loaded(key) else { break }
                for part in parts { note(nil, in: part, of: key) }
            }
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
            if offersRelay(tenant, question: "Join the relay at \(host)?", accept: "Join", decline: "Cancel") { relays.join(tenant) }
        }
    }

    /// Asks whether to use a relay tenant. A link or a published file can come from someone
    /// else, so the user sees the server before anything is sent to it.
    private func offersRelay(_ tenant: RelayTenant, question: String, accept: String, decline: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "The relay is at \(tenant.server.host() ?? tenant.server.absoluteString). Hermes opens your browser to sign in with GitHub. The relay then sends this Mac the changes in the repositories you can see, as they happen."
        alert.addButton(withTitle: accept)
        alert.addButton(withTitle: decline)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Looks, once a launch, for a relay tenant that each of the viewer's accounts publishes
    /// in its `.github` repository, and asks about the ones this Mac does not use. A tenant
    /// the user turns down is not asked about again. Settings lists it, with a Connect button.
    func discoverRelays() async {
        guard !hasLookedForRelays, let viewer else { return }
        hasLookedForRelays = true

        var published: [PublishedRelay] = []
        for account in viewer.accounts {
            // An account with no file, and one that can't be read, publishes no relay.
            if let tenant = try? await client.publishedRelay(of: account.login) {
                published.append(PublishedRelay(account: account.login, tenant: tenant))
            }
        }
        relays.found(published)

        for published in published where relays.shouldOffer(published.tenant) {
            let name = account(published.account)?.name ?? published.account
            if offersRelay(published.tenant, question: "\(name) has a relay. Connect?", accept: "Connect", decline: "Not Now") {
                relays.join(published.tenant)
            } else {
                relays.decline(published.tenant)
            }
        }
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

    /// One account's data, made on first use. An empty login is the data of a window with no account yet.
    func data(for login: String) -> AccountData {
        if let data = accounts[login] { return data }
        let data = AccountData(login: login, client: client) { [weak self] in self?.watched(in: login) ?? [] }
        accounts[login] = data
        return data
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

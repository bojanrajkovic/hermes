import AppKit
import Foundation
import GitHubKit
import os

/// A relay tenant this Mac uses.
struct RelayMembership: Codable, Hashable, Identifiable {
    /// The GitHub App the user registered for a tenant.
    struct App: Codable, Hashable {
        /// The account that owns the App: the user's own, or an organization they own.
        let account: String
        /// The App's name in its URLs, such as `hermes-acme`.
        let slug: String
    }

    let tenant: RelayTenant
    /// The App behind the tenant, when this user set the tenant up. Nil for a tenant joined
    /// by a link, whose App belongs to someone else.
    let app: App?
    /// The organization the tenant belongs to, when Hermes knows it: the tenant was set up
    /// for one, or found in one's `.github-private`. Hermes names it to the relay, which can
    /// then tell a member who has no repository yet from someone outside the organization.
    /// Nil for a personal account, which has no members to ask GitHub about.
    var organization: String?

    var id: String { tenant.id }
}

/// A relay tenant an account publishes in its `.github-private` repository.
struct PublishedRelay: Hashable, Identifiable {
    /// The account's login.
    let account: String
    var isOrganization = false
    let tenant: RelayTenant

    var id: String { "\(account)/\(tenant.id)" }
    /// The account's login, when the account is an organization.
    var organization: String? { isOrganization ? account : nil }
}

/// What a tenant's connection is doing.
enum RelayState: Equatable {
    /// There is no refresh token: the user has not signed in to the tenant, or the relay
    /// refused the token and they have to sign in again.
    case signedOut
    case connecting
    /// The relay sends events for these repositories, the ones the user can see through the tenant's App.
    case connected(repositories: Set<RepositoryRef>)
    /// The connection ended and may start again at `retryAt`.
    case waiting(retryAt: Date, error: String)
    /// The relay no longer has the tenant: its App was uninstalled.
    case gone
}

/// The relay tenants this Mac uses, their connections, and the setup of a new one. A user
/// can have several: one for their own account and one for each organization, each with
/// its own App, refresh token, and connection. See `plans/relay-client.md`.
@Observable
@MainActor
final class Relays {
    /// What a tenant does after its connection ends.
    enum Next: Equatable {
        case connect
        case signIn
        case stop
        /// Connect again after `delay`, having failed `failures` times in a row.
        case wait(delay: TimeInterval, failures: Int)
    }

    /// What follows a connection that ended after `ran` seconds, with `failures` ended in a
    /// row before it. A failure waits as a forwarder's does: 30 seconds, doubling to 30
    /// minutes, and counted from one again after a connection that held for five minutes.
    ///
    /// A relay that asks for a new connection within seconds of the last one waits like a
    /// failure, so a relay that keeps asking is not answered in a tight loop.
    static func next(after ending: RelayConnection.Ending, failures: Int, ran: TimeInterval) -> Next {
        switch ending {
        case .recheck where ran >= quickRecheck: return .connect
        case .unauthorized: return .signIn
        case .gone: return .stop
        case .recheck, .failed:
            let count = ran >= Forwarders.settledAfter ? 1 : failures + 1
            return .wait(delay: Forwarders.retryDelay(afterFailures: count), failures: count)
        }
    }

    /// A connection the relay closed for a re-check sooner than this counts as a failure.
    static let quickRecheck: TimeInterval = 5

    /// Setting up a tenant: Hermes sends the owner to GitHub to create an App, GitHub sends
    /// them back with a code, and Hermes hands the App's secrets to the relay.
    struct Setup {
        enum Phase: Equatable {
            /// The browser is on GitHub's page that creates the App.
            case creatingApp
            /// GitHub made the App. Its secrets are on their way to the relay.
            case registering
            case failed(String)
            case done(RelayMembership)
        }

        let tenant: RelayTenant
        let account: Account
        /// Sent to GitHub and expected back in the `hermes://relay.setup` link.
        let state: String
        var invite: String
        /// The App's secrets, from when GitHub makes it until the relay has them. Held in
        /// memory only, so a refused invite code can be corrected without a second App.
        var credentials: RelayAppCredentials?
        /// GitHub's code for the App's secrets, kept when redeeming it failed in a way that
        /// left it good. GitHub made the App already, so the code is the only way to its secrets.
        var code: String?
        var phase: Phase

        /// Whether the step that failed can be tried again without a second App.
        var canRetry: Bool { credentials != nil || code != nil }

        /// The page that posts the manifest, in the temporary directory.
        var page: URL {
            FileManager.default.temporaryDirectory.appending(path: "hermes-relay-setup-\(state).html")
        }
    }

    private(set) var memberships: [RelayMembership] {
        didSet { defaults.set(try? JSONEncoder().encode(memberships), forKey: Self.key) }
    }
    private(set) var setup: Setup?

    /// Each tenant's connection, by the tenant's ID. A tenant with no entry has not been tried yet.
    private(set) var states: [String: RelayState] = [:]
    /// When each tenant last sent an event, by the tenant's ID. Settings shows it, because a
    /// connection that is open proves only that the relay answered, not that events arrive.
    private(set) var lastEvents: [String: Date] = [:]
    /// The commit each relay server reports, for Settings.
    private(set) var versions: [URL: String] = [:]
    /// The tenants the viewer's accounts publish, as last looked up.
    private(set) var published: [PublishedRelay] = []
    /// Called for each webhook delivery a relay sends.
    @ObservationIgnored var onEvent: (RelayEvent) -> Void = { _ in }

    @ObservationIgnored private var connections: [String: RelayConnection] = [:]
    /// When each tenant's connection started, which also tells it from an earlier one.
    @ObservationIgnored private var startedAt: [String: Date] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    /// A sign-in the browser has not come back from.
    private struct SignIn {
        let tenantID: String
        /// Sent with the grant. The login address carried its challenge.
        let verifier: RelayVerifier
    }

    /// Each sign-in the browser has not come back from, by its `state`. Held in memory only.
    @ObservationIgnored private var signIns: [String: SignIn] = [:]

    /// The repositories a connected tenant sends events for. They need no forwarder.
    var covered: Set<RepositoryRef> {
        states.values.reduce(into: []) { covered, state in
            if case .connected(let repositories) = state { covered.formUnion(repositories) }
        }
    }

    private let api: RelayAPI
    private let defaults: UserDefaults
    /// Opens a page in the browser.
    private let open: @MainActor (URL) -> Void
    static let key = "relayMemberships"
    static let log = Logger(subsystem: "com.coderinserepeat.hermes", category: "relay")

    init(defaults: UserDefaults, api: RelayAPI = RelayAPI(), open: @escaping @MainActor (URL) -> Void = Relays.openInBrowser) {
        self.defaults = defaults
        self.api = api
        self.open = open
        memberships = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([RelayMembership].self, from: $0) } ?? []
        declined = Set(defaults.stringArray(forKey: "relayDeclined") ?? [])
        gone = Set(defaults.stringArray(forKey: "relayGone") ?? [])
        states = Dictionary(uniqueKeysWithValues: gone.map { ($0, .gone) })
    }

    /// Opens a page in the default browser, not in whatever opens its file type: the setup
    /// page is an `.html` file, which can belong to an editor.
    static func openInBrowser(_ url: URL) {
        if let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://github.com")!) {
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts a tenant for an account: asks the relay whether it is there, writes the page
    /// that posts the App's manifest, and opens it in the browser. The owner creates the App there.
    ///
    /// - Returns: Why the setup did not start, or nil. When it did not, no App exists.
    func beginSetup(account: Account, server: URL, invite: String) async -> String? {
        guard let tenant = RelayTenant(server: server) else { return "That is not a relay's address." }

        // GitHub fixes the App's webhook and sign-in addresses when it creates the App. A
        // server that does not answer would leave an App that can never reach a relay.
        do {
            versions[tenant.server] = try await api.version(of: tenant.server)
        } catch {
            let host = tenant.server.host() ?? tenant.server.absoluteString
            return "The relay at \(host) did not answer, so no App was created. \(describe(error))"
        }

        endSetup()
        let setup = Setup(tenant: tenant, account: account, state: UUID().uuidString, invite: invite, credentials: nil, phase: .creatingApp)
        let page = RelayAppManifest.page(
            manifest: RelayAppManifest.json(for: tenant, login: account.login),
            action: RelayAppManifest.registrationURL(for: account, state: setup.state)
        )
        do {
            try page.write(to: setup.page, atomically: true, encoding: .utf8)
        } catch {
            return "Could not write the setup page: \(error.localizedDescription)"
        }

        self.setup = setup
        open(setup.page)
        return nil
    }

    /// Redeems the code GitHub sent back for the App's secrets, then registers the tenant.
    /// The caller has checked that the link's state is this setup's. `retrySetup` calls it
    /// again with the code it kept.
    func finishSetup(code: String) async {
        guard let setup, setup.phase == .creatingApp || setup.code == code else { return }
        self.setup?.code = nil
        self.setup?.phase = .registering

        do {
            self.setup?.credentials = try await api.redeemManifest(code: code)
        } catch {
            if RelayAPI.canRedeemAgain(after: error) { self.setup?.code = code }
            self.setup?.phase = .failed("GitHub did not hand over the App: \(describe(error))")
            return
        }
        await register()
    }

    /// Repeats the step of the setup that failed: redeeming GitHub's code when that is what
    /// failed, and otherwise registering, with another invite code when one is given.
    func retrySetup(invite: String? = nil) async {
        if let code = setup?.code {
            await finishSetup(code: code)
        } else {
            await register(invite: invite)
        }
    }

    /// Registers the tenant with the invite code given, or the one the setup started with.
    /// Called again after the relay refuses a code.
    func register(invite: String? = nil) async {
        if let invite { setup?.invite = invite }
        guard let setup, let credentials = setup.credentials else { return }
        self.setup?.phase = .registering

        do {
            try await api.register(credentials.registration(invite: setup.invite), as: setup.tenant)
        } catch {
            self.setup?.phase = .failed(describe(error))
            return
        }

        let membership = RelayMembership(
            tenant: setup.tenant, app: .init(account: setup.account.login, slug: credentials.slug),
            organization: setup.account.kind == .organization ? setup.account.login : nil
        )
        memberships.append(membership)
        self.setup?.credentials = nil
        self.setup?.phase = .done(membership)
        Self.log.notice("registered a tenant for \(setup.account.login, privacy: .public)")
        // The new tenant has no token yet, so this marks it signed out, which shows Sign In on its row.
        sync()
    }

    /// Drops the setup in progress, finished or not.
    func endSetup() {
        if let setup { try? FileManager.default.removeItem(at: setup.page) }
        setup = nil
    }

    /// Stops using a tenant on this Mac. The App stays on GitHub and the tenant on the relay.
    func forget(_ membership: RelayMembership) {
        disconnect(membership.id)
        states[membership.id] = nil
        lastEvents[membership.id] = nil
        failures[membership.id] = nil
        gone.remove(membership.id)
        // A sign-in the browser has not come back from is no longer wanted.
        signIns = signIns.filter { $0.value.tenantID != membership.id }
        memberships.removeAll { $0.id == membership.id }
        RelayKeychain.set(refreshToken: nil, for: membership.tenant)
    }

    /// The tenants the relay no longer has, by ID, kept so each row still says so after a relaunch.
    private var gone: Set<String> {
        didSet { defaults.set(gone.sorted(), forKey: "relayGone") }
    }

    // MARK: Joining and signing in

    /// The published tenants the user was offered and turned down, by ID, so each is offered once.
    private(set) var declined: Set<String> {
        didSet { defaults.set(declined.sorted(), forKey: "relayDeclined") }
    }

    /// Whether to ask about a tenant an account publishes: not one whose ID this Mac has, and
    /// not one the user turned down. A tenant turned down stays in `available`, for Settings.
    func shouldOffer(_ tenant: RelayTenant) -> Bool {
        !memberships.contains { $0.id == tenant.id } && !declined.contains(tenant.id)
    }

    func decline(_ tenant: RelayTenant) {
        declined.insert(tenant.id)
    }

    /// Records the tenants the viewer's accounts publish. A tenant this Mac joined by a link
    /// came with no account, so one an organization publishes gets its organization here.
    func found(_ published: [PublishedRelay]) {
        self.published = published
        for index in memberships.indices where memberships[index].organization == nil {
            let tenant = memberships[index].tenant
            if let organization = published.first(where: { $0.tenant == tenant })?.organization {
                memberships[index].organization = organization
            }
        }
    }

    /// The published tenants this Mac does not use. Settings lists them, so one the user
    /// turned down can still be connected to.
    var available: [PublishedRelay] {
        published.filter { published in !memberships.contains { $0.tenant == published.tenant } }
    }

    /// Why a tenant can't be added, or nil when it can. A tenant's ID names one tenant, and
    /// the connection, the sign-in, and the Keychain item all go by it. A link or a
    /// published file that gives a known ID another server is refused, so it can't take
    /// the place of the tenant this Mac uses.
    func refusal(of tenant: RelayTenant) -> String? {
        guard let other = memberships.first(where: { $0.id == tenant.id && $0.tenant != tenant }) else { return nil }
        func host(_ tenant: RelayTenant) -> String { tenant.server.host() ?? tenant.server.absoluteString }
        return "This Mac already uses a relay tenant with this ID, at \(host(other.tenant)). The one at \(host(tenant)) claims the same ID, so Hermes did not add it."
    }

    /// Adds a tenant from a join link or a published file, when this Mac does not have it
    /// yet, and signs in to it. Does nothing for a tenant `refusal(of:)` refuses.
    ///
    /// - Parameter organization: The organization that publishes the tenant. Nil for a join
    ///   link, which names no account, and for a personal account.
    func join(_ tenant: RelayTenant, organization: String? = nil) {
        guard refusal(of: tenant) == nil else { return }
        let membership = memberships.first { $0.tenant == tenant } ?? RelayMembership(tenant: tenant, app: nil, organization: organization)
        if !memberships.contains(membership) { memberships.append(membership) }
        signIn(membership)
    }

    /// Opens the tenant's sign-in in the browser, with a new `state` and the challenge of a
    /// new verifier. The relay sends the user on to GitHub and back to Hermes with a
    /// `hermes://relay.session` link.
    func signIn(_ membership: RelayMembership) {
        let state = UUID().uuidString
        let verifier = RelayVerifier()
        signIns[state] = SignIn(tenantID: membership.id, verifier: verifier)
        open(RelayAPI.loginURL(for: membership.tenant, state: state, verifier: verifier))
    }

    /// Exchanges the grant of a `hermes://relay.session` link, with the sign-in's verifier,
    /// for the refresh token, stores it, and connects.
    ///
    /// - Returns: What went wrong, or nil.
    func finishSignIn(tenantID: String, grant: String, state: String) async -> String? {
        // The relay sends back the state Hermes gave it. Any other link was not asked for.
        guard let signIn = signIns[state], signIn.tenantID == tenantID,
              let membership = memberships.first(where: { $0.id == tenantID }) else {
            return "This relay sign-in link does not belong to a sign-in Hermes started."
        }
        signIns[state] = nil

        let token: String
        do {
            token = try await api.refreshToken(grant: grant, verifier: signIn.verifier, for: membership.tenant)
        } catch {
            return "Could not sign in to the relay: \(describe(error))"
        }
        // The user can remove the tenant while the relay answers. Its token is then not
        // kept, and nothing connects.
        guard memberships.contains(membership) else { return nil }
        guard RelayKeychain.set(refreshToken: token, for: membership.tenant) else {
            return "The Keychain refused the relay's token."
        }

        failures[tenantID] = nil
        gone.remove(tenantID)
        disconnect(tenantID)
        connect(membership)
        return nil
    }

    // MARK: Connections

    /// Connects every tenant that has a refresh token and no connection, except one that is
    /// waiting to retry, signed out, or gone.
    func sync() {
        for membership in memberships where connections[membership.id] == nil {
            switch states[membership.id] {
            case .signedOut, .gone, .connecting, .connected: continue
            case .waiting(let retryAt, _) where retryAt > .now: continue
            case .waiting, nil: connect(membership)
            }
        }
    }

    func stopAll() {
        for id in Array(connections.keys) { disconnect(id) }
    }

    /// Asks each tenant's server which commit it runs.
    func loadVersions() async {
        for server in Set(memberships.map(\.tenant.server)) {
            if let commit = try? await api.version(of: server) { versions[server] = commit }
        }
    }

    private func connect(_ membership: RelayMembership) {
        let id = membership.id
        guard let token = RelayKeychain.refreshToken(for: membership.tenant) else {
            states[id] = .signedOut
            return
        }
        let started = Date.now
        startedAt[id] = started
        states[id] = .connecting
        let connection = RelayConnection(tenant: membership.tenant, refreshToken: token, organization: membership.organization)
        connections[id] = connection
        // One task reads the connection in order. The relay can send a session and close in
        // the same instant, and the session's token has to be stored before the ending
        // starts the next connection, which would otherwise use the spent one.
        Task { [weak self] in
            for await event in connection.events {
                switch event {
                case .message(let message): self?.received(message, from: membership, started: started)
                case .ended(let ending): self?.ended(membership, started: started, ending: ending)
                }
            }
        }
        Self.log.notice("connecting to tenant \(id.prefix(8), privacy: .public)")
    }

    private func disconnect(_ id: String) {
        connections[id]?.stop()
        connections[id] = nil
        startedAt[id] = nil
    }

    /// A message from the connection that started at `started`. One from an earlier
    /// connection of the tenant is dropped.
    private func received(_ message: RelayMessage, from membership: RelayMembership, started: Date) {
        guard startedAt[membership.id] == started else { return }
        switch message {
        case .session(let session):
            // The token the connection used is spent, so this one has to be kept before anything else.
            if !RelayKeychain.set(refreshToken: session.refreshToken, for: membership.tenant) {
                Self.log.error("the Keychain refused the token of tenant \(membership.id.prefix(8), privacy: .public)")
            }
            states[membership.id] = .connected(repositories: Set(session.repositories))
            Self.log.notice("tenant \(membership.id.prefix(8), privacy: .public) covers \(session.repositories.count) repositories")
        case .event(let event):
            lastEvents[membership.id] = .now
            onEvent(event)
        }
    }

    private func ended(_ membership: RelayMembership, started: Date, ending: RelayConnection.Ending) {
        let id = membership.id
        guard startedAt[id] == started else { return }
        disconnect(id)

        let ran = Date.now.timeIntervalSince(started)
        // A connection that held was working, as with a forwarder, so the failures before it
        // are not counted with the next one, whatever ended it.
        if ran >= Forwarders.settledAfter { failures[id] = nil }
        let next = Self.next(after: ending, failures: failures[id] ?? 0, ran: ran)
        Self.log.notice("tenant \(id.prefix(8), privacy: .public) ended: \(String(describing: ending), privacy: .public)")
        switch next {
        case .connect:
            connect(membership)
        case .signIn:
            RelayKeychain.set(refreshToken: nil, for: membership.tenant)
            states[id] = .signedOut
        case .stop:
            RelayKeychain.set(refreshToken: nil, for: membership.tenant)
            states[id] = .gone
            gone.insert(id)
        case .wait(let delay, let count):
            failures[id] = count
            let error = if case .failed(let message) = ending { message } else { "" }
            states[id] = .waiting(retryAt: Date.now.addingTimeInterval(delay), error: error)
        }
    }
}

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

    var id: String { tenant.id }
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
    /// The relay no longer has the tenant: its App was uninstalled, or its invite code withdrawn.
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
        var phase: Phase

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
    /// The commit each relay server reports, for Settings.
    private(set) var versions: [URL: String] = [:]
    /// Called for each webhook delivery a relay sends.
    @ObservationIgnored var onEvent: (RelayEvent) -> Void = { _ in }

    @ObservationIgnored private var connections: [String: RelayConnection] = [:]
    /// When each tenant's connection started, which also tells it from an earlier one.
    @ObservationIgnored private var startedAt: [String: Date] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    /// The `state` of each sign-in the browser has not come back from, and its tenant's ID.
    @ObservationIgnored private var signIns: [String: String] = [:]

    /// The repositories a connected tenant sends events for. They need no forwarder.
    var covered: Set<RepositoryRef> {
        states.values.reduce(into: []) { covered, state in
            if case .connected(let repositories) = state { covered.formUnion(repositories) }
        }
    }

    private let api: RelayAPI
    private let defaults: UserDefaults
    static let key = "relayMemberships"
    static let log = Logger(subsystem: "com.coderinserepeat.hermes", category: "relay")

    init(defaults: UserDefaults, api: RelayAPI = RelayAPI()) {
        self.defaults = defaults
        self.api = api
        memberships = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([RelayMembership].self, from: $0) } ?? []
        declined = Set(defaults.stringArray(forKey: "relayDeclined") ?? [])
    }

    /// Starts a tenant for an account: writes the page that posts the App's manifest and
    /// opens it in the browser. The owner creates the App there.
    func beginSetup(account: Account, server: URL, invite: String) {
        guard let tenant = RelayTenant(server: server) else { return }
        endSetup()
        let setup = Setup(tenant: tenant, account: account, state: UUID().uuidString, invite: invite, credentials: nil, phase: .creatingApp)
        self.setup = setup

        let page = RelayAppManifest.page(
            manifest: RelayAppManifest.json(for: tenant, login: account.login),
            action: RelayAppManifest.registrationURL(for: account, state: setup.state)
        )
        do {
            try page.write(to: setup.page, atomically: true, encoding: .utf8)
        } catch {
            self.setup?.phase = .failed("Could not write the setup page: \(error.localizedDescription)")
            return
        }

        // The default browser, not whatever opens `.html` files, which can be an editor.
        if let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://github.com")!) {
            NSWorkspace.shared.open([setup.page], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(setup.page)
        }
    }

    /// Redeems the code GitHub sent back for the App's secrets, then registers the tenant.
    /// The caller has checked that the link's state is this setup's.
    func finishSetup(code: String) async {
        guard setup?.phase == .creatingApp else { return }
        setup?.phase = .registering
        do {
            setup?.credentials = try await api.redeemManifest(code: code)
        } catch {
            setup?.phase = .failed("GitHub did not hand over the App: \(describe(error))")
            return
        }
        await register()
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

        let membership = RelayMembership(tenant: setup.tenant, app: .init(account: setup.account.login, slug: credentials.slug))
        memberships.append(membership)
        self.setup?.credentials = nil
        self.setup?.phase = .done(membership)
        Self.log.info("registered a tenant for \(setup.account.login, privacy: .public)")
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
        failures[membership.id] = nil
        memberships.removeAll { $0.id == membership.id }
        RelayKeychain.set(refreshToken: nil, for: membership.tenant)
    }

    // MARK: Joining and signing in

    /// The published tenants the user was offered and turned down, by ID, so each is offered once.
    private(set) var declined: Set<String> {
        didSet { defaults.set(declined.sorted(), forKey: "relayDeclined") }
    }

    /// Whether to offer a tenant an account publishes: not one this Mac has, and not one the user turned down.
    func shouldOffer(_ tenant: RelayTenant) -> Bool {
        !memberships.contains { $0.tenant == tenant } && !declined.contains(tenant.id)
    }

    func decline(_ tenant: RelayTenant) {
        declined.insert(tenant.id)
    }

    /// Adds a tenant from a join link, when this Mac does not have it yet, and signs in to it.
    func join(_ tenant: RelayTenant) {
        let membership = memberships.first { $0.tenant == tenant } ?? RelayMembership(tenant: tenant, app: nil)
        if !memberships.contains(membership) { memberships.append(membership) }
        signIn(membership)
    }

    /// Opens the tenant's sign-in in the browser. The relay sends the user on to GitHub and
    /// back to Hermes with a `hermes://relay.session` link.
    func signIn(_ membership: RelayMembership) {
        let state = UUID().uuidString
        signIns[state] = membership.id
        let login = membership.tenant.server.appending(path: "t/\(membership.id)/login")
            .appending(queryItems: [URLQueryItem(name: "state", value: state)])
        NSWorkspace.shared.open(login)
    }

    /// Exchanges the grant of a `hermes://relay.session` link for the refresh token, stores
    /// it, and connects.
    ///
    /// - Returns: What went wrong, or nil.
    func finishSignIn(tenantID: String, grant: String, state: String) async -> String? {
        // The relay sends back the state Hermes gave it. Any other link was not asked for.
        guard signIns[state] == tenantID, let membership = memberships.first(where: { $0.id == tenantID }) else {
            return "This relay sign-in link does not belong to a sign-in Hermes started."
        }
        signIns[state] = nil

        do {
            let token = try await api.refreshToken(grant: grant, for: membership.tenant)
            guard RelayKeychain.set(refreshToken: token, for: membership.tenant) else {
                return "The Keychain refused the relay's token."
            }
        } catch {
            return "Could not sign in to the relay: \(describe(error))"
        }

        failures[tenantID] = nil
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
        connections[id] = RelayConnection(
            tenant: membership.tenant, refreshToken: token,
            onMessage: { [weak self] message in Task { @MainActor in self?.received(message, from: membership, started: started) } },
            onEnd: { [weak self] ending in Task { @MainActor in self?.ended(membership, started: started, ending: ending) } }
        )
        Self.log.info("connecting to tenant \(id.prefix(8), privacy: .public)")
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
            Self.log.info("tenant \(membership.id.prefix(8), privacy: .public) covers \(session.repositories.count) repositories")
        case .event(let event):
            onEvent(event)
        }
    }

    private func ended(_ membership: RelayMembership, started: Date, ending: RelayConnection.Ending) {
        let id = membership.id
        guard startedAt[id] == started else { return }
        disconnect(id)

        let next = Self.next(after: ending, failures: failures[id] ?? 0, ran: Date.now.timeIntervalSince(started))
        Self.log.info("tenant \(id.prefix(8), privacy: .public) ended: \(String(describing: ending), privacy: .public)")
        switch next {
        case .connect:
            connect(membership)
        case .signIn:
            RelayKeychain.set(refreshToken: nil, for: membership.tenant)
            states[id] = .signedOut
        case .stop:
            RelayKeychain.set(refreshToken: nil, for: membership.tenant)
            states[id] = .gone
        case .wait(let delay, let count):
            failures[id] = count
            let error = if case .failed(let message) = ending { message } else { "" }
            states[id] = .waiting(retryAt: Date.now.addingTimeInterval(delay), error: error)
        }
    }
}

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

/// The relay tenants this Mac uses, and the setup of a new one. A user can have several:
/// one for their own account and one for each organization. See `plans/relay-client.md`.
@Observable
@MainActor
final class Relays {
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

    private let api: RelayAPI
    private let defaults: UserDefaults
    static let key = "relayMemberships"
    static let log = Logger(subsystem: "com.coderinserepeat.hermes", category: "relay")

    init(defaults: UserDefaults, api: RelayAPI = RelayAPI()) {
        self.defaults = defaults
        self.api = api
        memberships = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([RelayMembership].self, from: $0) } ?? []
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
    }

    /// Drops the setup in progress, finished or not.
    func endSetup() {
        if let setup { try? FileManager.default.removeItem(at: setup.page) }
        setup = nil
    }

    /// Stops using a tenant on this Mac. The App stays on GitHub and the tenant on the relay.
    func forget(_ membership: RelayMembership) {
        memberships.removeAll { $0.id == membership.id }
        RelayKeychain.set(refreshToken: nil, for: membership.tenant)
    }
}

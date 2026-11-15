import Foundation
import GitHubKit
import Network
import os
import Testing
@testable import Hermes

/// Answers the relay's and GitHub's HTTP calls in place of the network. Each test gives a
/// host its own answers, so tests that run at once do not share any.
final class StubRelayHTTP: URLProtocol, @unchecked Sendable {
    typealias Answer = @Sendable (URLRequest) -> (status: Int, body: String)

    static let answers = OSAllocatedUnfairLock<[String: Answer]>(initialState: [:])

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubRelayHTTP.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let answer = Self.answers.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, body) = answer(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A WebSocket server on this Mac that stands in for a tenant's connection: it sends each
/// client one text frame and closes with `closeCode` in the same instant.
private func standInRelay(sending frame: String, closeCode: UInt16) async throws -> NWListener {
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
    let listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        let text = NWConnection.ContentContext(identifier: "frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(frame.utf8), contentContext: text, completion: .contentProcessed { _ in
            let close = NWProtocolWebSocket.Metadata(opcode: .close)
            close.closeCode = .privateCode(closeCode)
            connection.send(content: nil, contentContext: .init(identifier: "close", metadata: [close]), completion: .idempotent)
        })
    }
    let ready = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
    await withCheckedContinuation { continuation in
        ready.withLock { $0 = continuation }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.withLock { $0.take() }?.resume() }
        }
        listener.start(queue: .global())
    }
    return listener
}

/// The setup, sign-in, and connection of a relay tenant, against stand-ins for the relay and GitHub.
@MainActor
@Suite(.serialized)
struct RelayFlowTests {
    private let defaults: UserDefaults
    private let suite = "relay-flow-tests-\(UUID().uuidString)"
    /// A host only this test uses.
    private let host = "relay-\(UUID().uuidString.lowercased()).example.invalid"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private var server: URL { URL(string: "https://\(host)")! }

    /// The pages Hermes would have opened in the browser.
    private final class Opened { var urls: [URL] = [] }

    private func makeRelays(opened: Opened = Opened()) -> Relays {
        Relays(defaults: defaults, api: RelayAPI(session: StubRelayHTTP.session())) { opened.urls.append($0) }
    }

    private func answer(_ host: String, _ answer: @escaping StubRelayHTTP.Answer) {
        StubRelayHTTP.answers.withLock { $0[host] = answer }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }

    private let acme = Account(kind: .organization, login: "acme", name: nil, avatarURL: URL(string: "https://example.com/acme.png")!, canAdminister: true)

    // MARK: Setup

    @Test func aRelayThatDoesNotAnswerStopsTheSetupBeforeGitHub() async {
        defer { defaults.removePersistentDomain(forName: suite) }
        answer(host) { _ in (502, "") }
        let opened = Opened()
        let relays = makeRelays(opened: opened)

        let error = await relays.beginSetup(account: acme, server: server, invite: "inv")

        #expect(error?.contains(host) == true)
        #expect(relays.setup == nil)
        #expect(opened.urls.isEmpty)
    }

    @Test func aRedemptionGitHubNeverAnsweredKeepsTheCodeForAnotherTry() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        answer(host) { request in request.url?.path() == "/version" ? (200, #"{"commit":"abc"}"#) : (201, "") }
        let gitHubIsUp = OSAllocatedUnfairLock(initialState: false)
        answer("api.github.com") { _ in
            gitHubIsUp.withLock { $0 }
                ? (201, #"{"id":42,"slug":"hermes-acme","client_id":"Iv1.abc","client_secret":"cs","webhook_secret":"ws","pem":"key"}"#)
                : (502, "")
        }
        let opened = Opened()
        let relays = makeRelays(opened: opened)
        #expect(await relays.beginSetup(account: acme, server: server, invite: "inv") == nil)
        #expect(opened.urls.count == 1)

        await relays.finishSetup(code: "c1")
        guard case .failed = relays.setup?.phase else {
            Issue.record("the setup did not fail")
            return
        }
        #expect(relays.setup?.code == "c1")
        #expect(relays.setup?.canRetry == true)

        gitHubIsUp.withLock { $0 = true }
        await relays.retrySetup()

        let membership = try #require(relays.memberships.first)
        #expect(relays.setup?.phase == .done(membership))
        #expect(membership.app == .init(account: "acme", slug: "hermes-acme"))
        #expect(relays.setup?.code == nil)
    }

    @Test func aCodeGitHubRefusedIsNotKept() async {
        defer { defaults.removePersistentDomain(forName: suite) }
        answer(host) { _ in (200, #"{"commit":"abc"}"#) }
        answer("api.github.com") { _ in (404, "") }
        let relays = makeRelays()
        _ = await relays.beginSetup(account: acme, server: server, invite: "inv")

        await relays.finishSetup(code: "c1")

        #expect(relays.setup?.code == nil)
        #expect(relays.setup?.canRetry == false)
    }

    // MARK: Joining and signing in

    @Test func aKnownTenantIDOnAnotherServerIsRefused() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let opened = Opened()
        let relays = makeRelays(opened: opened)
        let tenant = try #require(RelayTenant(server: server))
        let respelled = try #require(RelayTenant(server: URL(string: "HTTPS://\(host.uppercased())/")!, id: tenant.id))
        let impostor = try #require(RelayTenant(server: URL(string: "https://other.example.invalid")!, id: tenant.id))
        relays.join(tenant)

        // The same server spelled another way is the same tenant, and signs in again.
        #expect(relays.refusal(of: respelled) == nil)
        relays.join(respelled)
        #expect(relays.memberships.count == 1)
        #expect(opened.urls.count == 2)

        #expect(relays.refusal(of: impostor)?.contains("other.example.invalid") == true)
        #expect(!relays.shouldOffer(impostor))
        relays.join(impostor)
        #expect(relays.memberships.map(\.tenant) == [tenant])
        #expect(opened.urls.count == 2)
    }

    @Test func removingATenantWhileItSignsInKeepsNoTokenAndConnectsNothing() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let opened = Opened()
        let relays = makeRelays(opened: opened)
        let tenant = try #require(RelayTenant(server: server))
        defer { RelayKeychain.set(refreshToken: nil, for: tenant) }
        relays.join(tenant)
        let membership = try #require(relays.memberships.first)
        let state = try #require(URLComponents(url: opened.urls[0], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        // The user removes the tenant while the relay is answering.
        answer(host) { _ in
            DispatchQueue.main.sync { MainActor.assumeIsolated { relays.forget(membership) } }
            return (200, #"{"refreshToken":"fresh"}"#)
        }

        let error = await relays.finishSignIn(tenantID: tenant.id, grant: "g1", state: state)

        #expect(error == nil)
        #expect(relays.memberships.isEmpty)
        #expect(relays.states[tenant.id] == nil)
        #expect(RelayKeychain.refreshToken(for: tenant) == nil)
    }

    @Test func aRemovedTenantsSignInLinkIsRefused() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let opened = Opened()
        let relays = makeRelays(opened: opened)
        let tenant = try #require(RelayTenant(server: server))
        relays.join(tenant)
        let state = try #require(URLComponents(url: opened.urls[0], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        relays.forget(try #require(relays.memberships.first))
        // The tenant comes back by another link. The sign-in from before it was removed is still not wanted.
        relays.join(tenant)

        #expect(await relays.finishSignIn(tenantID: tenant.id, grant: "g1", state: state) != nil)
    }

    // MARK: Connections

    /// A tenant on a stand-in relay on this Mac, with a refresh token in the Keychain.
    private func connectedTenant(closingWith closeCode: UInt16) async throws -> (RelayTenant, NWListener) {
        let frame = #"{"type":"session","refreshToken":"new-token","expiresAt":1700000000,"repositories":["acme/site"]}"#
        let listener = try await standInRelay(sending: frame, closeCode: closeCode)
        let port = try #require(listener.port)
        let tenant = try #require(RelayTenant(server: URL(string: "http://127.0.0.1:\(port.rawValue)")!))
        try #require(RelayKeychain.set(refreshToken: "old-token", for: tenant))
        defaults.set(try JSONEncoder().encode([RelayMembership(tenant: tenant, app: nil)]), forKey: Relays.key)
        return (tenant, listener)
    }

    @Test func aSessionFollowedAtOnceByACloseStillStoresTheNewToken() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (tenant, listener) = try await connectedTenant(closingWith: 4001)
        defer {
            listener.cancel()
            RelayKeychain.set(refreshToken: nil, for: tenant)
        }
        let relays = makeRelays()

        relays.sync()
        // A re-check within seconds of connecting waits like a failure, so nothing reconnects during the test.
        try await waitFor { if case .waiting = relays.states[tenant.id] { true } else { false } }

        #expect(RelayKeychain.refreshToken(for: tenant) == "new-token")
        relays.stopAll()
    }

    @Test func aTenantTheRelayNoLongerHasStillSaysSoAfterARelaunch() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (tenant, listener) = try await connectedTenant(closingWith: 4004)
        defer {
            listener.cancel()
            RelayKeychain.set(refreshToken: nil, for: tenant)
        }
        let relays = makeRelays()

        relays.sync()
        try await waitFor { relays.states[tenant.id] == .gone }

        #expect(RelayKeychain.refreshToken(for: tenant) == nil)
        let relaunched = makeRelays()
        #expect(relaunched.states[tenant.id] == .gone)
        // Removing it forgets that too.
        relaunched.forget(try #require(relaunched.memberships.first))
        #expect(makeRelays().states[tenant.id] == nil)
    }
}

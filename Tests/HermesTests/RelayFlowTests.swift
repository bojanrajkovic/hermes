import CryptoKit
import Foundation
import GitHubKit
import Network
import os
import TestSupport
import Testing
@testable import Hermes

/// Answers the relay's and GitHub's HTTP calls in place of the network. Each test gives a
/// host its own answers, so tests that run at once do not share any.
final class StubRelayHTTP: URLProtocol, @unchecked Sendable {
    typealias Answer = @Sendable (URLRequest) -> (status: Int, body: String)

    static let answers = OSAllocatedUnfairLock<[String: Answer]>(initialState: [:])
    /// The body of each request a host got, in order.
    static let bodies = OSAllocatedUnfairLock<[String: [Data]]>(initialState: [:])

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
        // URLSession hands a protocol the body as a stream.
        var sent = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
                sent.append(buffer, count: count)
            }
            stream.close()
        }
        Self.bodies.withLock { [sent] in $0[url.host() ?? "", default: []].append(sent) }

        let (status, body) = answer(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A WebSocket server on this Mac that stands in for a tenant's connection. It reads each
/// client's first frame, then sends `frame`, when there is one, and closes with `closeCode`
/// in the same instant.
private final class StandInRelay: Sendable {
    /// What the clients sent: the names of the headers on their connection requests, and
    /// each one's first frame.
    struct Seen: Sendable {
        var headers: [String] = []
        var frames: [String] = []
    }

    let seen = OSAllocatedUnfairLock(initialState: Seen())
    let listener: NWListener

    init(sending frame: String?, closeCode: NWProtocolWebSocket.CloseCode) async throws {
        let options = NWProtocolWebSocket.Options()
        options.setClientRequestHandler(.global()) { [seen] _, headers in
            seen.withLock { $0.headers += headers.map(\.name) }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [seen] connection in
            connection.start(queue: .global())
            connection.receiveMessage { content, _, _, _ in
                seen.withLock { $0.frames.append(String(decoding: content ?? Data(), as: UTF8.self)) }
                let close = NWProtocolWebSocket.Metadata(opcode: .close)
                close.closeCode = closeCode
                let closing = NWConnection.ContentContext(identifier: "close", metadata: [close])
                guard let frame else {
                    connection.send(content: nil, contentContext: closing, completion: .idempotent)
                    return
                }
                let text = NWConnection.ContentContext(identifier: "frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
                connection.send(content: Data(frame.utf8), contentContext: text, completion: .contentProcessed { _ in
                    connection.send(content: nil, contentContext: closing, completion: .idempotent)
                })
            }
        }
        let ready = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        await withCheckedContinuation { continuation in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.withLock { $0.take() }?.resume() }
            }
            listener.start(queue: .global())
        }
    }
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

    /// A value in the query of a page Hermes opened.
    private func query(_ name: String, of url: URL) throws -> String {
        try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value)
    }

    @Test func aSignInSendsTheChallengeToTheBrowserAndItsVerifierToTheRelay() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let opened = Opened()
        let relays = makeRelays(opened: opened)
        let tenant = try #require(RelayTenant(server: server))
        // The relay refuses the grant, so no token is kept and nothing connects.
        answer(host) { _ in (403, "") }
        relays.join(tenant)
        // A second sign-in to the same tenant has its own state and its own verifier.
        relays.signIn(try #require(relays.memberships.first))
        #expect(try query("code_challenge", of: opened.urls[0]) != query("code_challenge", of: opened.urls[1]))

        _ = await relays.finishSignIn(tenantID: tenant.id, grant: "g1", state: try query("state", of: opened.urls[1]))

        let sent = try #require(StubRelayHTTP.bodies.withLock { $0[host] }?.first)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: String])
        #expect(body["grant"] == "g1")
        let verifier = try #require(body["verifier"])
        #expect(verifier.count == 43)
        let digest = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
        let challenge = digest.replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
        #expect(try query("code_challenge", of: opened.urls[1]) == challenge)
    }

    @Test func aSessionLinkWithAStateHermesDidNotSendIsRefused() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let opened = Opened()
        let relays = makeRelays(opened: opened)
        let tenant = try #require(RelayTenant(server: server))
        let other = try #require(RelayTenant(server: server))
        answer(host) { _ in (403, "") }
        relays.join(tenant)
        relays.join(other)

        #expect(await relays.finishSignIn(tenantID: tenant.id, grant: "g1", state: "not-a-state") != nil)
        // Another tenant's sign-in does not vouch for this one.
        #expect(await relays.finishSignIn(tenantID: tenant.id, grant: "g1", state: try query("state", of: opened.urls[1])) != nil)

        // Neither link reached the relay.
        #expect(StubRelayHTTP.bodies.withLock { $0[host] } == nil)
    }

    @Test func removingATenantWhileItSignsInKeepsNoTokenAndConnectsNothing() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let opened = Opened()
        let relays = makeRelays(opened: opened)
        let tenant = try #require(RelayTenant(server: server))
        defer { RelayKeychain.set(refreshToken: nil, for: tenant) }
        relays.join(tenant)
        let membership = try #require(relays.memberships.first)
        let state = try query("state", of: opened.urls[0])
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
        let state = try query("state", of: opened.urls[0])
        relays.forget(try #require(relays.memberships.first))
        // The tenant comes back by another link. The sign-in from before it was removed is still not wanted.
        relays.join(tenant)

        #expect(await relays.finishSignIn(tenantID: tenant.id, grant: "g1", state: state) != nil)
    }

    // MARK: Connections

    private static let session = #"{"type":"session","refreshToken":"new-token","expiresAt":1700000000,"repositories":["acme/site"]}"#

    /// A tenant on a stand-in relay on this Mac, with a refresh token in the Keychain. The
    /// relay answers the client's first frame with `frame`, when there is one, and closes.
    private func connectedTenant(
        sending frame: String? = session, closingWith closeCode: NWProtocolWebSocket.CloseCode
    ) async throws -> (RelayTenant, StandInRelay) {
        let relay = try await StandInRelay(sending: frame, closeCode: closeCode)
        let port = try #require(relay.listener.port)
        let tenant = try #require(RelayTenant(server: URL(string: "http://127.0.0.1:\(port.rawValue)")!))
        try #require(RelayKeychain.set(refreshToken: "old-token", for: tenant))
        defaults.set(try JSONEncoder().encode([RelayMembership(tenant: tenant, app: nil)]), forKey: Relays.key)
        return (tenant, relay)
    }

    @Test func theRefreshTokenGoesInTheFirstFrameAndNotInAHeader() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (tenant, relay) = try await connectedTenant(closingWith: .privateCode(4001))
        defer {
            relay.listener.cancel()
            RelayKeychain.set(refreshToken: nil, for: tenant)
        }
        let relays = makeRelays()

        relays.sync()
        try await waitFor { if case .waiting = relays.states[tenant.id] { true } else { false } }
        relays.stopAll()

        let seen = relay.seen.withLock { $0 }
        #expect(!seen.headers.contains { $0.lowercased() == "authorization" })
        let hello = try #require(seen.frames.first)
        #expect(try JSONSerialization.jsonObject(with: Data(hello.utf8)) as? [String: String] == ["type": "hello", "refreshToken": "old-token"])
    }

    @Test func aSessionFollowedAtOnceByACloseStillStoresTheNewToken() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (tenant, relay) = try await connectedTenant(closingWith: .privateCode(4001))
        defer {
            relay.listener.cancel()
            RelayKeychain.set(refreshToken: nil, for: tenant)
        }
        let relays = makeRelays()

        relays.sync()
        // A re-check within seconds of connecting waits like a failure, so nothing reconnects during the test.
        try await waitFor { if case .waiting = relays.states[tenant.id] { true } else { false } }

        #expect(RelayKeychain.refreshToken(for: tenant) == "new-token")
        relays.stopAll()
    }

    @Test func aTokenTheRelayRefusesIsDeletedAndTheTenantIsSignedOut() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (tenant, relay) = try await connectedTenant(sending: nil, closingWith: .privateCode(4003))
        defer {
            relay.listener.cancel()
            RelayKeychain.set(refreshToken: nil, for: tenant)
        }
        let relays = makeRelays()

        relays.sync()
        try await waitFor { relays.states[tenant.id] == .signedOut }

        #expect(RelayKeychain.refreshToken(for: tenant) == nil)
    }

    @Test func aRelayThatCannotReachGitHubKeepsTheTokenAndWaits() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (tenant, relay) = try await connectedTenant(sending: nil, closingWith: .protocolCode(.internalServerError))
        defer {
            relay.listener.cancel()
            RelayKeychain.set(refreshToken: nil, for: tenant)
        }
        let relays = makeRelays()

        relays.sync()
        try await waitFor { if case .waiting = relays.states[tenant.id] { true } else { false } }
        relays.stopAll()

        // The relay did not use the token, so the next connection sends it again.
        #expect(RelayKeychain.refreshToken(for: tenant) == "old-token")
    }

    @Test func aTenantTheRelayNoLongerHasStillSaysSoAfterARelaunch() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (tenant, relay) = try await connectedTenant(closingWith: .privateCode(4004))
        defer {
            relay.listener.cancel()
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

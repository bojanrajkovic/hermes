import Foundation
import Testing
@testable import GitHubKit

@Suite struct RelayTests {
    private let tenant = RelayTenant(server: URL(string: "https://relay.example.com")!, id: String(repeating: "0a", count: 16))!

    private func message(_ json: String) -> RelayMessage? { RelayMessage(frame: Data(json.utf8)) }

    // MARK: Messages

    @Test func theSessionMessageCarriesTheNewTokenAndTheRepositories() {
        let message = message(#"{"type":"session","refreshToken":"r2","expiresAt":1700000000,"repositories":["octo/app","octo/web","bad"]}"#)

        #expect(message == .session(RelaySession(
            refreshToken: "r2", expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            repositories: [RepositoryRef(owner: "octo", name: "app"), RepositoryRef(owner: "octo", name: "web")]
        )))
    }

    @Test func anEventKeepsThePayloadForTheWebhookReader() throws {
        let frame = #"""
            {"type":"event","event":"pull_request","delivery":"d-1",
             "payload":{"action":"edited","pull_request":{"number":7},"repository":{"name":"app","owner":{"login":"octo"}}}}
            """#
        guard case .event(let event) = message(frame) else {
            Issue.record("not an event")
            return
        }

        #expect(event.name == "pull_request")
        #expect(event.delivery == "d-1")
        #expect(WebhookEvent(payload: event.payload) == WebhookEvent(repository: RepositoryRef(owner: "octo", name: "app"), pullRequest: 7))
    }

    @Test func framesHermesDoesNotKnowAreSkipped() {
        #expect(message(#"{"type":"notice","text":"hello"}"#) == nil)
        #expect(message(#"{"type":"session","refreshToken":"r2"}"#) == nil)
        #expect(message(#"{"type":"event","event":"status","delivery":"d-1"}"#) == nil)
        #expect(message("not json") == nil)
    }

    // MARK: Endings

    @Test func theRelaysCloseCodesDecideWhatHappensNext() {
        func ending(_ code: Int, status: Int? = 101) -> RelayConnection.Ending {
            RelayConnection.ending(closeCode: code, status: status, error: "dropped")
        }

        #expect(ending(4001) == .recheck)
        #expect(ending(4003) == .unauthorized)
        #expect(ending(4004) == .gone)
        // The relay refused the connection request itself.
        #expect(ending(0, status: 404) == .gone)
        // The relay could not reach GitHub, and did not use the token.
        #expect(ending(1011) == .failed("dropped"))
        // The connection request carries no token, so a 401 to it says nothing about one.
        #expect(ending(0, status: 401) == .failed("dropped"))
        // Everything else waits and tries again.
        #expect(ending(1001) == .failed("dropped"))
        #expect(ending(0, status: 502) == .failed("dropped"))
        #expect(ending(0, status: nil) == .failed("dropped"))
    }

    // MARK: Requests

    @Test func aConnectionOpensTheTenantsWebSocket() {
        #expect(RelayConnection.url(for: tenant).absoluteString == "wss://relay.example.com/t/\(tenant.id)/connect")
        let local = RelayTenant(server: URL(string: "http://localhost:8787")!, id: tenant.id)!
        #expect(RelayConnection.url(for: local).absoluteString == "ws://localhost:8787/t/\(tenant.id)/connect")
    }

    @Test func registeringPutsTheSecretsUnderTheTenant() throws {
        let registration = RelayRegistration(invite: "inv", appID: 42, clientID: "Iv1.abc", clientSecret: "cs", webhookSecret: "ws")

        let request = try RelayAPI.registerRequest(registration, as: tenant)

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://relay.example.com/tenants/\(tenant.id)")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body.keys.sorted() == ["appID", "clientID", "clientSecret", "invite", "webhookSecret"])
        #expect(body["appID"] as? Int == 42)
        #expect(body["invite"] as? String == "inv")
    }

    /// The verifier and its challenge from RFC 7636, appendix B.
    private let verifier = RelayVerifier(value: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    private let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    @Test func theChallengeIsTheVerifiersSHA256InBase64URL() {
        #expect(verifier.challenge == challenge)
    }

    @Test func aNewVerifierIs32RandomBytesInBase64URL() {
        let new = RelayVerifier()

        #expect(new.value.count == 43)
        #expect(new.value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) })
        #expect(new != RelayVerifier())
    }

    @Test func theLoginAddressCarriesTheStateAndTheChallenge() {
        let login = RelayAPI.loginURL(for: tenant, state: "s1", verifier: verifier)

        #expect(login.absoluteString == "https://relay.example.com/t/\(tenant.id)/login?state=s1&code_challenge=\(challenge)")
    }

    @Test func theGrantAndTheVerifierArePostedToTheTenantsSession() throws {
        let request = try RelayAPI.sessionRequest(grant: "g1", verifier: verifier, for: tenant)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://relay.example.com/t/\(tenant.id)/session")
        let data = try #require(request.httpBody)
        #expect(try JSONSerialization.jsonObject(with: data) as? [String: String] == ["grant": "g1", "verifier": verifier.value])
    }

    @Test func theRelaysRefusalsHaveTheirOwnErrors() {
        let refused: [Int: RelayError] = [403: .inviteRefused, 409: .alreadyRegistered]

        #expect(RelayAPI.error(status: 201, expecting: 201, refused: refused) == nil)
        #expect(RelayAPI.error(status: 403, expecting: 201, refused: refused) == .inviteRefused)
        #expect(RelayAPI.error(status: 409, expecting: 201, refused: refused) == .alreadyRegistered)
        #expect(RelayAPI.error(status: 400, expecting: 201, refused: refused) == .unexpected(status: 400))
        #expect(RelayAPI.error(status: 200, expecting: 201) == .unexpected(status: 200))
    }
}

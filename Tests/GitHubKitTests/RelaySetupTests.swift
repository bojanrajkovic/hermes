import Foundation
import Testing
@testable import GitHubKit

@Suite struct RelaySetupTests {
    private let tenant = RelayTenant(server: URL(string: "https://relay.example.com")!, id: String(repeating: "0a", count: 16))!

    private func account(_ login: String, _ kind: Account.Kind) -> Account {
        Account(kind: kind, login: login, name: nil, avatarURL: URL(string: "https://example.com/a.png")!)
    }

    @Test func theAppsNameFitsGitHubsLimit() {
        #expect(RelayAppManifest.name(for: "acme") == "hermes-acme")
        // 39 characters is the longest login GitHub allows.
        let long = RelayAppManifest.name(for: String(repeating: "a", count: 39))
        #expect(long == "hermes-" + String(repeating: "a", count: 27))
        #expect(long.count == 34)
        // A cut that lands on a hyphen does not leave it at the end.
        #expect(RelayAppManifest.name(for: String(repeating: "a", count: 26) + "-b") == "hermes-" + String(repeating: "a", count: 26))
    }

    @Test func theManifestPointsTheAppAtTheTenant() throws {
        let data = RelayAppManifest.json(for: tenant, login: "acme")
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(manifest["name"] as? String == "hermes-acme")
        #expect((manifest["hook_attributes"] as? [String: Any])?["url"] as? String == "https://relay.example.com/hook/\(tenant.id)")
        #expect(manifest["callback_urls"] as? [String] == ["https://relay.example.com/t/\(tenant.id)/callback"])
        #expect(manifest["redirect_url"] as? String == "hermes://relay.setup")
        #expect(manifest["public"] as? Bool == false)
        #expect((manifest["default_permissions"] as? [String: String])?["members"] == "read")
        #expect((manifest["default_events"] as? [String])?.contains("pull_request_review_thread") == true)
        // The App is asked for nothing that reads a repository's files or writes anywhere.
        #expect((manifest["default_permissions"] as? [String: String])?.values.allSatisfy { $0 == "read" } == true)
        #expect((manifest["default_permissions"] as? [String: String])?["contents"] == nil)
    }

    @Test func anOrganizationsAppIsRegisteredUnderTheOrganization() {
        #expect(RelayAppManifest.registrationURL(for: account("acme", .organization), state: "s 1").absoluteString
            == "https://github.com/organizations/acme/settings/apps/new?state=s%201")
        #expect(RelayAppManifest.registrationURL(for: account("bojan", .personal), state: "s1").absoluteString
            == "https://github.com/settings/apps/new?state=s1")
    }

    @Test func thePageEscapesTheManifestInsideTheForm() {
        let page = RelayAppManifest.page(manifest: Data(#"{"name":"a<b>&\"c\""}"#.utf8), action: URL(string: "https://github.com/settings/apps/new?state=s1&x=2")!)

        #expect(page.contains(#"value="{&quot;name&quot;:&quot;a&lt;b&gt;&amp;\&quot;c\&quot;&quot;}""#))
        #expect(page.contains(#"action="https://github.com/settings/apps/new?state=s1&amp;x=2""#))
    }

    @Test func theAppsSecretsBecomeTheRegistrationAndThePrivateKeyIsNotRead() throws {
        let json = #"""
            {"id": 42, "slug": "hermes-acme", "client_id": "Iv1.abc", "client_secret": "cs", "webhook_secret": "ws",
             "pem": "-----BEGIN RSA PRIVATE KEY-----", "owner": {"login": "acme"}}
            """#

        let credentials = try JSONDecoder().decode(RelayAppCredentials.self, from: Data(json.utf8))

        #expect(credentials.registration(invite: "inv")
            == RelayRegistration(invite: "inv", appID: 42, clientID: "Iv1.abc", clientSecret: "cs", webhookSecret: "ws"))
        #expect(RelayAppManifest.installURL(slug: credentials.slug).absoluteString == "https://github.com/apps/hermes-acme/installations/new")
        #expect(!String(describing: credentials).contains("PRIVATE KEY"))
    }
}

import Foundation
import Testing
@testable import GitHubKit

@Suite struct RelayLinkTests {
    private let id = String(repeating: "0a", count: 16)
    private let server = URL(string: "https://relay.example.com")!

    private func link(_ string: String) -> RelayLink? { RelayLink(url: URL(string: string)!) }

    @Test func theThreeLinksAreRead() {
        #expect(link("hermes://relay.setup?code=abc&state=s1") == .setup(code: "abc", state: "s1"))
        #expect(link("hermes://relay.session?tenant=\(id)&grant=g1&state=s1") == .session(tenantID: id, grant: "g1", state: "s1"))
        #expect(link("hermes://relay.join?server=https%3A%2F%2Frelay.example.com&tenant=\(id)")
            == .join(RelayTenant(server: server, id: id)!))
    }

    @Test func aJoinLinkReadsBackAsItsTenant() {
        let tenant = RelayTenant(server: URL(string: "https://relay.example.com:8443/base")!, id: id)!

        #expect(tenant.joinLink.absoluteString
            == "hermes://relay.join?server=https%3A%2F%2Frelay%2Eexample%2Ecom%3A8443%2Fbase&tenant=\(id)")
        #expect(RelayLink(url: tenant.joinLink) == .join(tenant))
    }

    @Test func aLinkThatLacksAValueIsNotRead() {
        #expect(link("hermes://relay.setup?code=abc") == nil)
        #expect(link("hermes://relay.setup?code=&state=s1") == nil)
        #expect(link("hermes://relay.session?tenant=\(id)&state=s1") == nil)
        #expect(link("hermes://relay.join?tenant=\(id)") == nil)
        #expect(link("hermes://relay.other?code=abc&state=s1") == nil)
        #expect(link("https://relay.setup?code=abc&state=s1") == nil)
    }

    @Test func aTenantNeedsAHexIDAndAnHTTPSServer() {
        #expect(RelayTenant(server: server, id: "abc") == nil)
        #expect(RelayTenant(server: server, id: String(repeating: "0A", count: 16)) == nil)
        #expect(RelayTenant(server: URL(string: "http://relay.example.com")!, id: id) == nil)
        #expect(RelayTenant(server: URL(string: "hermes://relay.example.com")!, id: id) == nil)
        #expect(RelayTenant(server: URL(string: "http://localhost:8787")!, id: id) != nil)
        #expect(RelayTenant(server: server)?.id.count == 32)
    }

    @Test func relayLinksAndPlaceLinksDoNotOverlap() {
        #expect(DeepLink(url: URL(string: "hermes://relay.join?server=https%3A%2F%2Frelay.example.com&tenant=\(id)")!) == nil)
        #expect(RelayLink(url: URL(string: "hermes://octo/app")!) == nil)
    }
}

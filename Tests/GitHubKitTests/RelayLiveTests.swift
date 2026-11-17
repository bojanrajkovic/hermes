import Foundation
import Testing
@testable import GitHubKit

/// Calls a running relay that need no sign-in and store nothing. Run with
/// `HERMES_LIVE_RELAY=<the relay's base URL> swift test --filter RelayLiveTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERMES_LIVE_RELAY"] != nil))
struct RelayLiveTests {
    private let server = URL(string: ProcessInfo.processInfo.environment["HERMES_LIVE_RELAY"] ?? "https://relay.invalid")!

    @Test func theRelayReportsItsCommit() async throws {
        #expect(try await !RelayAPI().version(of: server).isEmpty)
    }

    /// The relay answers the connection request itself, so URLSession's upgrade reaches its handler.
    @Test func aTenantTheRelayDoesNotHaveEndsAsGone() async throws {
        let tenant = try #require(RelayTenant(server: server))

        var events: [RelayConnection.Event] = []
        for await event in RelayConnection(tenant: tenant, refreshToken: "not-a-token").events { events.append(event) }

        #expect(events == [.ended(.gone)])
    }
}

import Foundation
import GitHubKit
import Testing
@testable import Hermes

@MainActor
struct RelaysTests {
    private func next(_ ending: RelayConnection.Ending, failures: Int = 0, ran: TimeInterval = 60) -> Relays.Next {
        Relays.next(after: ending, failures: failures, ran: ran)
    }

    @Test func theRelaysOwnEndingsAreFollowedAtOnce() {
        #expect(next(.recheck) == .connect)
        #expect(next(.unauthorized) == .signIn)
        #expect(next(.gone) == .stop)
    }

    @Test func aFailureWaitsLongerEachTimeUntilAConnectionHolds() {
        #expect(next(.failed("dropped")) == .wait(delay: 30, failures: 1))
        #expect(next(.failed("dropped"), failures: 2) == .wait(delay: 120, failures: 3))
        // Five minutes connected was a working connection, so the count starts over.
        #expect(next(.failed("dropped"), failures: 6, ran: 300) == .wait(delay: 30, failures: 1))
    }

    @Test func aRecheckWithinSecondsWaitsLikeAFailure() {
        #expect(next(.recheck, ran: 1) == .wait(delay: 30, failures: 1))
        #expect(next(.recheck, failures: 1, ran: 1) == .wait(delay: 60, failures: 2))
    }

    @Test func aPublishedTenantIsOfferedUntilItIsJoinedOrTurnedDown() throws {
        let suite = "relays-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try #require(URL(string: "https://relay.example.invalid"))
        let joined = try #require(RelayTenant(server: server))
        let published = try #require(RelayTenant(server: server))
        defaults.set(try JSONEncoder().encode([RelayMembership(tenant: joined, app: nil)]), forKey: Relays.key)

        let relays = Relays(defaults: defaults)
        #expect(!relays.shouldOffer(joined))
        #expect(relays.shouldOffer(published))

        // Turned down once, it is not offered again, on this launch or the next.
        relays.decline(published)
        #expect(!relays.shouldOffer(published))
        #expect(!Relays(defaults: defaults).shouldOffer(published))
    }

    @Test func aBurstOfEventsLoadsAPullRequestOnceAndThenOnceMore() {
        var bursts = EventBursts()
        let key = ItemKey(repository: airway, number: 7)
        let other = ItemKey(repository: airway, number: 8)

        // The first event loads. The next three wait for that load, and another pull request is not held up.
        let loads = [
            bursts.shouldLoad(key, part: \.checks), bursts.shouldLoad(key, part: \.checks),
            bursts.shouldLoad(key, part: \.threads), bursts.shouldLoad(key, part: nil), bursts.shouldLoad(other, part: nil),
        ]
        #expect(loads == [true, false, false, false, true])

        // One more load covers all three, and names both parts once.
        let again = bursts.loaded(key)
        #expect(again == [\.checks, \.threads])
        // No event came during the second load, so the burst is over and the next event loads at once.
        let over = bursts.loaded(key)
        #expect(over == nil)
        let next = bursts.shouldLoad(key, part: nil)
        #expect(next)
    }

    @Test func eventsNameThePartOfAPullRequestTheyChange() {
        #expect(EventCounts.part(ofEvent: "pull_request_review_comment") == \.threads)
        #expect(EventCounts.part(ofEvent: "pull_request_review_thread") == \.threads)
        for name in ["check_run", "check_suite", "status"] {
            #expect(EventCounts.part(ofEvent: name) == \.checks)
        }
        #expect(EventCounts.part(ofEvent: "pull_request") == nil)
        #expect(EventCounts.part(ofEvent: "issue_comment") == nil)
    }
}

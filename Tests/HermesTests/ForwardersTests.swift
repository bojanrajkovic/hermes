import GitHubKit
import Testing
@testable import Hermes

@MainActor
struct ForwardersTests {
    private let theirs = RepositoryRef(owner: "acme", name: "api")

    @Test func onlyTheViewersOwnRepositoriesAreForwardedInOrderWithoutRepeats() {
        let wanted = Forwarders.repositories(watched: [repairScripts, theirs, airway, repairScripts], viewer: "bojan", waiting: [])

        #expect(wanted == [repairScripts, airway])
    }

    @Test func waitingRepositoriesAreLeftOutAndTheLimitHolds() {
        #expect(Forwarders.repositories(watched: [airway, repairScripts], viewer: "bojan", waiting: [airway]) == [repairScripts])
        #expect(Forwarders.repositories(watched: [airway, repairScripts], viewer: "bojan", waiting: [], limit: 1) == [airway])
    }

    @Test func theRetryDelayDoublesFromHalfAMinuteToHalfAnHour() {
        #expect([1, 2, 3, 7, 30].map(Forwarders.retryDelay) == [30, 60, 120, 1800, 1800])
    }
}

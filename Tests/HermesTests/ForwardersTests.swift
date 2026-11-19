import GitHubKit
import Testing
@testable import Hermes

@MainActor
struct ForwardersTests {
    private let theirs = RepositoryRef(owner: "acme", name: "api")

    private func targets(
        _ watched: [RepositoryRef], organizations: Set<String> = [], waiting: Set<Forwarders.Target> = [], limit: Int = 20
    ) -> [Forwarders.Target] {
        Forwarders.targets(watched: watched, viewer: "bojan", organizations: organizations, waiting: waiting, limit: limit)
    }

    @Test func onlyTheViewersOwnRepositoriesAreForwardedInOrderWithoutRepeats() {
        #expect(targets([repairScripts, theirs, airway, repairScripts]) == [.repository(repairScripts), .repository(airway)])
    }

    @Test func anOwnedOrganizationIsForwardedWholeAndFirst() {
        let other = RepositoryRef(owner: "acme", name: "web")

        #expect(targets([airway, theirs, other], organizations: ["acme"]) == [.organization("acme"), .repository(airway)])
        // The limit is on repositories: an organization is one forwarder however many it has.
        #expect(targets([airway, repairScripts, theirs], organizations: ["acme"], limit: 1) == [.organization("acme"), .repository(airway)])
    }

    @Test func waitingTargetsAreLeftOut() {
        #expect(targets([airway, repairScripts, theirs], organizations: ["acme"], waiting: [.repository(airway), .organization("acme")])
            == [.repository(repairScripts)])
    }

    @Test func repositoriesARelayCoversGetNoForwarder() {
        let web = RepositoryRef(owner: "acme", name: "web")
        func targets(covered: Set<RepositoryRef>) -> [Forwarders.Target] {
            Forwarders.targets(
                watched: [airway, repairScripts, theirs, web], viewer: "bojan", organizations: ["acme"], waiting: [], covered: covered
            )
        }

        #expect(targets(covered: [airway]) == [.organization("acme"), .repository(repairScripts)])
        // An organization keeps its forwarder while one watched repository of it is not covered.
        #expect(targets(covered: [theirs]) == [.organization("acme"), .repository(airway), .repository(repairScripts)])
        #expect(targets(covered: [theirs, web]) == [.repository(airway), .repository(repairScripts)])
    }

    @Test func theRetryDelayDoublesFromHalfAMinuteToHalfAnHour() {
        #expect([1, 2, 3, 7, 30].map(Forwarders.retryDelay) == [30, 60, 120, 1800, 1800])
    }
}

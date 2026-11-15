import GitHubKit
import Testing
@testable import Hermes

@MainActor
struct ForwardersTests {
    private let theirs = RepositoryRef(owner: "acme", name: "api")

    @Test func onlyTheViewersOwnRepositoriesAreForwardedInOrderWithoutRepeats() {
        let wanted = Forwarders.repositories(watched: [repairScripts, theirs, airway, repairScripts], viewer: "bojan", refused: [])

        #expect(wanted == [repairScripts, airway])
    }

    @Test func refusedRepositoriesAreLeftOutAndTheLimitHolds() {
        #expect(Forwarders.repositories(watched: [airway, repairScripts], viewer: "bojan", refused: [airway]) == [repairScripts])
        #expect(Forwarders.repositories(watched: [airway, repairScripts], viewer: "bojan", refused: [], limit: 1) == [airway])
    }
}

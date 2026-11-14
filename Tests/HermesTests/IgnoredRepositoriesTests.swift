import Foundation
import GitHubKit
import Testing
@testable import Hermes

@MainActor
@Suite struct IgnoredRepositoriesTests {
    @Test func theIgnoreListSurvivesARelaunch() throws {
        let suite = "hermes-ignored-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        AppStore(defaults: defaults).ignoredRepositories = [airway, RepositoryRef(owner: "bojan", name: "hermes-playground")]

        #expect(AppStore(defaults: defaults).ignoredRepositories == [airway, RepositoryRef(owner: "bojan", name: "hermes-playground")])
    }
}

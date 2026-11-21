import Foundation
import GitHubKit
import TestSupport
import Testing
@testable import StateKit

/// The open issue count has one home, the repository record, which both the repository list
/// and every issue page write.
@MainActor
struct IssueCountTests {
    private let stub = StubHTTP()
    private let store: GitHubStore

    init() {
        store = GitHubStore(client: stub.client)
    }

    @Test func anIssuePageUpdatesTheRepositorysCount() async {
        store.store(repository(airway, issues: 8), startedAt: .distantPast)
        stub.enqueue(issuesPage([], total: 0))

        await store.loadMoreIssues(of: airway)

        #expect(store.openIssueCount(of: airway) == 0)
        #expect(store.repositories[airway]?.value.openIssueCount == 0)
    }

    @Test func anIssuePageCountsARepositoryTheAccountListDoesNotHave() async {
        stub.enqueue(issuesPage([1, 2], total: 5))

        await store.loadMoreIssues(of: airway)

        #expect(store.openIssueCount(of: airway) == 5)
        #expect(store.listedIssues(of: airway).map(\.number) == [1, 2])
    }

    @Test func aRepositoryLoadThatStartedBeforeAnIssuePageDoesNotUndoItsCount() async {
        let repositoryLoadStarted = Date.now
        stub.enqueue(issuesPage([], total: 0))
        await store.loadMoreIssues(of: airway)

        // The repository list was asked first but answered last, with the old count.
        store.store(repository(airway, issues: 8), startedAt: repositoryLoadStarted)

        #expect(store.openIssueCount(of: airway) == 0)
    }
}

import Foundation
import GitHubKit
import TestSupport
import Testing
@testable import StateKit

/// The snapshot shows the last launch's lists at once, and every fetch after it wins.
@MainActor
struct StoreSnapshotTests {
    private let stub = StubHTTP()
    private let store: GitHubStore
    private let url = FileManager.default.temporaryDirectory.appending(path: "hermes-\(UUID().uuidString)/store.json")
    private let listed = ItemKey(repository: airway, number: 1)
    private let now = Date.now

    init() {
        store = GitHubStore(client: stub.client)
    }

    /// A store signed in as bojan, with one listed pull request and its checks, and one pull
    /// request opened by link. The account's lists loaded at `loadedAt`.
    private func filled(loadedAt: Date? = nil) -> GitHubStore {
        let filled = GitHubStore(client: stub.client)
        filled.signedIn(as: "bojan")
        let cached = pullRequest(1, title: "Cached", head: "h1")
        filled.store(.pullRequest(cached), for: listed)
        filled.store(.pullRequest(pullRequest(2)), for: ItemKey(repository: airway, number: 2))
        filled.accounts["bojan"] = AccountLists()
        filled.accounts["bojan"]?.openPullRequests = [listed]
        filled.accounts["bojan"]?.hasLoaded = true
        filled.accounts["bojan"]?.pullRequestsLoadedAt = loadedAt ?? now
        filled.accounts["bojan"]?.listError = "offline"
        filled.store(repository(airway, issues: 3), startedAt: Date(timeIntervalSince1970: 500))
        filled.checks[CommitKey(repository: airway, oid: "h1")] = CommitChecks(checks: [], isLoaded: true)
        filled.checks[CommitKey(repository: airway, oid: "old")] = CommitChecks(checks: [], isLoaded: true)
        return filled
    }

    @Test func aSavedSnapshotRestoresTheLists() throws {
        try filled().snapshot().write(to: url)

        store.restore(from: url)

        #expect(store.openPullRequests(of: "bojan").map(\.title) == ["Cached"])
        #expect(store.lists(of: "bojan").hasLoaded)
        #expect(store.lists(of: "bojan").pullRequestsLoadedAt == now)
        #expect(store.lists(of: "bojan").listError == nil)
        #expect(store.repositories[airway] == Stamped(repository(airway, issues: 3), fetchedAt: Date(timeIntervalSince1970: 500)))
    }

    @Test func theSnapshotKeepsOnlyWhatTheListsName() {
        let source = filled()
        source.issueLists[airway] = IssueList()
        let snapshot = source.snapshot()

        #expect(Set(snapshot.pullRequests.keys) == [listed])
        #expect(Set(snapshot.checks.keys) == [CommitKey(repository: airway, oid: "h1")])

        store.restore(snapshot, now: now)
        #expect(store.issueLists.isEmpty)
    }

    @Test func aFetchReplacesARestoredRecord() async {
        store.restore(filled().snapshot(), now: now)
        stub.enqueue(item(pullRequestJSON(1)))

        await store.refetch(listed)

        #expect(store.pullRequest(listed)?.title == "A pull request")
    }

    @Test func restoredChecksDoNotStopAScreensFirstLoad() async {
        store.restore(filled().snapshot(), now: now)
        stub.enqueue("""
            {"repository":{"object":{"statusCheckRollup":{"contexts":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
              {"__typename":"StatusContext","context":"ci/build","state":"SUCCESS","targetUrl":null,"description":null}
            ]}}}}}
            """)

        await store.pollChecks(CommitKey(repository: airway, oid: "h1"))

        #expect(store.checks[CommitKey(repository: airway, oid: "h1")]?.checks.map(\.name) == ["ci/build"])
    }

    @Test func aRepositoryFetchedThisLaunchBeatsTheSnapshotsCopy() {
        store.restore(filled().snapshot(), now: now)

        store.store(repository(airway, issues: 9), startedAt: .now)

        #expect(store.openIssueCount(of: airway) == 9)
    }

    @Test func restoringKeepsWhatAFetchAlreadyWrote() {
        store.store(.pullRequest(pullRequest(1, title: "Fetched")), for: listed)

        store.restore(filled().snapshot(), now: now)

        #expect(store.pullRequest(listed)?.title == "Fetched")
    }

    @Test func anUnreadableSnapshotIsDeleted() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"pullRequests":"none"}"#.utf8).write(to: url)

        store.restore(from: url)

        #expect(store.pullRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anAccountThatLoadedOverADayAgoIsNotRestored() {
        let snapshot = filled(loadedAt: now.addingTimeInterval(-25 * 60 * 60)).snapshot()

        store.restore(snapshot, now: now)

        #expect(store.accounts.isEmpty)
        #expect(store.pullRequests.isEmpty)
    }

    @Test func anotherUsersSnapshotIsDroppedAtSignIn() {
        store.restore(filled().snapshot(), now: now)

        store.signedIn(as: "someone-else")

        #expect(store.accounts.isEmpty)
        #expect(store.pullRequests.isEmpty)
        #expect(store.repositories.isEmpty)
    }

    @Test func theSameUsersSnapshotStaysAtSignIn() {
        store.restore(filled().snapshot(), now: now)

        store.signedIn(as: "bojan")

        #expect(store.openPullRequests(of: "bojan").map(\.title) == ["Cached"])
    }

    @Test func aQuitBeforeSignInKeepsTheSnapshotsOwner() {
        store.restore(filled().snapshot(), now: now)

        #expect(store.snapshot().viewer == "bojan")
    }
}

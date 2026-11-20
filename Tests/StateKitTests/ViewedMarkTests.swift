import Foundation
import GitHubKit
import TestSupport
import Testing
@testable import StateKit

/// Viewed marks show at once, and a revision fetch that started before a mark can't undo it.
@MainActor
struct ViewedMarkTests {
    private let stub = StubHTTP()
    private let store: GitHubStore
    private let key = ItemKey(repository: airway, number: 7)

    init() {
        store = GitHubStore(client: stub.client)
    }

    private func revision(viewed: Set<String>) -> PullRequestRevision {
        PullRequestRevision(headOID: "abc", updatedAt: .distantPast, viewedPaths: viewed)
    }

    @Test func aRevisionFetchedBeforeAMarkDoesNotUndoIt() async throws {
        store.take(revision(viewed: []), for: key, startedAt: .distantPast)
        let pollStarted = Date.now
        stub.enqueue(#"{"markFileAsViewed":{"clientMutationId":null}}"#)

        try await store.setViewed(true, path: "a.swift", of: pullRequest(7))
        // A poll that asked GitHub before the mark answers after it.
        store.take(revision(viewed: []), for: key, startedAt: pollStarted)

        #expect(store.viewedPaths(of: key) == ["a.swift"])
    }

    @Test func aRevisionFetchedWhileAMarkIsSentKeepsIt() async throws {
        store.take(revision(viewed: []), for: key, startedAt: .distantPast)
        stub.enqueue(#"{"markFileAsViewed":{"clientMutationId":null}}"#, delay: 0.2)

        let marking = Task { try await store.setViewed(true, path: "a.swift", of: pullRequest(7)) }
        for _ in 0..<100 where store.viewedPaths(of: key) != ["a.swift"] { await Task.yield() }
        // A poll that asked after the click, while GitHub hasn't taken the mark yet.
        store.take(revision(viewed: []), for: key, startedAt: .now)
        #expect(store.viewedPaths(of: key) == ["a.swift"])

        try await marking.value
    }

    @Test func aMarkGitHubRefusesIsTakenBack() async {
        store.take(revision(viewed: []), for: key, startedAt: .distantPast)
        // No answer queued, so the request fails.

        await #expect(throws: (any Error).self) { try await store.setViewed(true, path: "a.swift", of: pullRequest(7)) }

        #expect(store.viewedPaths(of: key) == [])
    }
}

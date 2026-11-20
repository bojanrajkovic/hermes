import Foundation
import GitHubKit
import TestSupport
import Testing
@testable import StateKit

/// Webhook payloads arrive out of order and race with loads. These keep a record from going back in time.
@MainActor
struct AppliedPayloadsTests {
    private func fields(title: String = "A pull request", updated: TimeInterval) -> PullRequestFields {
        PullRequestFields(
            title: title, body: "", state: .open, isDraft: false, labels: [], headOID: "abc", headRefName: "branch-7",
            baseRefName: "main", additions: 1, deletions: 1, changedFileCount: 1, autoMergeMethod: nil,
            requestedReviewers: [], updatedAt: Date(timeIntervalSinceReferenceDate: updated)
        )
    }

    @Test func aPayloadOlderThanTheLastOneARowTookIsNotApplied() {
        let store = GitHubStore(client: GitHubClient(token: { "" }))
        let key = ItemKey(repository: airway, number: 7)
        store.store(.pullRequest(pullRequest(7)), for: key)

        // Two edits arrive reversed: the later one first.
        #expect(store.apply(fields(title: "Second edit", updated: 20), to: key))
        #expect(!store.apply(fields(title: "First edit", updated: 10), to: key))
        #expect(store.pullRequest(key)?.title == "Second edit")

        // One from the same second is not older.
        #expect(store.apply(fields(title: "Third edit", updated: 20), to: key))
        #expect(store.pullRequest(key)?.title == "Third edit")
    }

    @Test func aLoadSeesWhichRowsTookAPayloadWhileItRan() {
        var applied = AppliedPayloads()
        let key = ItemKey(repository: airway, number: 7)
        let other = ItemKey(repository: airway, number: 8)
        _ = applied.take(fields(updated: 10), for: key)

        // What a load reads before it asks GitHub. Nothing came yet, so its answer is kept.
        let before = applied
        #expect(applied.rows(since: before).isEmpty)

        // Payloads that come while GitHub answers. The answer would undo them, so their rows load once more.
        _ = applied.take(fields(updated: 20), for: key)
        _ = applied.take(fields(updated: 20), for: other)
        #expect(applied.rows(since: before) == [key, other])

        // A payload that was not applied changed no row.
        let after = applied
        _ = applied.take(fields(updated: 5), for: key)
        #expect(applied.rows(since: after).isEmpty)
    }
}

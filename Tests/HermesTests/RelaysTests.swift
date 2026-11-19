import Foundation
import GitHubKit
import Testing
@testable import Hermes

@MainActor
struct RelaysTests {
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

    /// The fields of a `pull_request` payload that GitHub last changed `updated` seconds in.
    private func fields(title: String = "A pull request", updated: TimeInterval) -> PullRequestFields {
        PullRequestFields(
            title: title, body: "", state: .open, isDraft: false, labels: [], headOID: "abc", headRefName: "branch-7",
            baseRefName: "main", additions: 1, deletions: 1, changedFileCount: 1, autoMergeMethod: nil,
            requestedReviewers: [], updatedAt: Date(timeIntervalSinceReferenceDate: updated)
        )
    }

    @Test func aPayloadOlderThanTheLastOneARowTookIsNotApplied() {
        let data = AccountData(login: "bojan", client: GitHubClient(token: { "" }))
        let key = ItemKey(repository: airway, number: 7)
        data.store(.pullRequest(pullRequest(7)), for: key)

        // Two edits arrive reversed: the later one first.
        #expect(data.apply(fields(title: "Second edit", updated: 20), to: key))
        #expect(!data.apply(fields(title: "First edit", updated: 10), to: key))
        #expect(data.pullRequest(key)?.title == "Second edit")

        // One from the same second is not older.
        #expect(data.apply(fields(title: "Third edit", updated: 20), to: key))
        #expect(data.pullRequest(key)?.title == "Third edit")
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

import Foundation
import GitHubKit
import Testing
@testable import Hermes

@Suite struct AttentionTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let viewer = "bojan"

    private func reason(_ pullRequest: PullRequest, _ signals: AttentionSignals = AttentionSignals()) -> AttentionReason? {
        attentionReason(for: pullRequest, viewer: viewer, signals: signals, now: now)
    }

    // MARK: Reviewer

    @Test func directAndTeamRequestsAreTold() {
        let theirs = pullRequest(1, author: user("alice"))

        #expect(reason(theirs, AttentionSignals(directRequests: [theirs.id])) == .reviewRequested)
        #expect(reason(theirs, AttentionSignals(teamRequests: [theirs.id])) == .teamReviewRequested)
    }

    @Test func newCommitsSinceYourReview() {
        let theirs = pullRequest(1, author: user("alice"), head: "new")

        #expect(reason(theirs, AttentionSignals(reviewedCommits: [theirs.id: "old"])) == .newCommits)
        #expect(reason(theirs, AttentionSignals(reviewedCommits: [theirs.id: "new"])) == nil)
    }

    @Test func mentions() {
        let theirs = pullRequest(1, author: user("alice"))

        #expect(reason(theirs, AttentionSignals(mentions: [theirs.id])) == .mentioned)
    }

    @Test func someoneElsesPullRequestWithNoSignalIsNotListed() {
        #expect(reason(pullRequest(1, author: user("alice"), checks: .failure, review: .changesRequested)) == nil)
    }

    // MARK: Author

    @Test func yourPullRequestNeedsAction() {
        #expect(reason(pullRequest(1, author: user("bojan"), review: .changesRequested)) == .changesRequested)
        #expect(reason(pullRequest(1, author: user("bojan"), checks: .failure)) == .failingChecks)
        #expect(reason(pullRequest(1, author: user("bojan"), checks: .error)) == .failingChecks)
        #expect(reason(pullRequest(1, author: user("bojan"), mergeable: .conflicting)) == .conflicts)
    }

    @Test func yourPullRequestOnAMergedBranchNeedsARebase() {
        let stacked = pullRequest(2, author: user("bojan"), base: "feature-a")

        #expect(reason(stacked, AttentionSignals(mergedBranches: [ItemBranch(repository: airway, name: "feature-a")])) == .needsRebase)
        #expect(reason(stacked) == nil)
    }

    @Test func readyToMergeNeedsApprovalGreenChecksAndNoConflicts() {
        #expect(reason(pullRequest(1, author: user("bojan"), review: .approved)) == .readyToMerge)
        #expect(reason(pullRequest(1, author: user("bojan"), checks: nil, review: .approved)) == .readyToMerge)
        #expect(reason(pullRequest(1, author: user("bojan"), checks: .pending, review: .approved)) == nil)
        #expect(reason(pullRequest(1, author: user("bojan"), draft: true, review: .approved)) == nil)
        #expect(reason(pullRequest(1, author: user("bojan"), review: .approved, mergeable: .unknown)) == nil)
    }

    @Test func yoursOpenedInTheLastDayIsListed() {
        #expect(reason(pullRequest(1, author: user("bojan"), created: now.addingTimeInterval(-23 * 3600))) == .openedRecently)
        #expect(reason(pullRequest(1, author: user("bojan"), created: now.addingTimeInterval(-25 * 3600))) == nil)
    }

    // MARK: Ranking

    @Test func theStrongestReasonWins() {
        let mine = pullRequest(1, author: user("bojan"), checks: .failure, created: now, review: .changesRequested)

        #expect(reason(mine, AttentionSignals(mentions: [mine.id])) == .changesRequested)
    }

    @Test func listIsRankedThenNewestFirst() {
        // Equal update times fall back to the higher number, the newer pull request.
        let older = pullRequest(1, author: user("alice"))
        let newer = pullRequest(2, author: user("alice"))
        let failing = pullRequest(3, author: user("bojan"), checks: .failure)
        let mentioned = pullRequest(4, author: user("alice"))
        let quiet = pullRequest(5, author: user("alice"))
        let signals = AttentionSignals(directRequests: [older.id, newer.id], mentions: [mentioned.id])

        let ranked = attentionList([mentioned, quiet, failing, older, newer], viewer: viewer, signals: signals, now: now)

        #expect(ranked.map(\.pullRequest.number) == [2, 1, 3, 4])
        #expect(ranked.map(\.reason) == [.reviewRequested, .reviewRequested, .failingChecks, .mentioned])
    }
}

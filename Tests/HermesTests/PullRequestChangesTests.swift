import Foundation
import GitHubKit
import Testing
@testable import Hermes

struct PullRequestChangesTests {
    private let day: TimeInterval = 86_400

    @Test func changedPullRequestsReplaceTheirCopyAndNewOnesSortByCreation() {
        let old = pullRequest(1, created: Date(timeIntervalSince1970: day))
        let newer = pullRequest(2, created: Date(timeIntervalSince1970: 3 * day))
        let retitled = pullRequest(1, title: "Retitled", created: Date(timeIntervalSince1970: day))
        let middle = pullRequest(3, created: Date(timeIntervalSince1970: 2 * day))

        let merged = PullRequestChanges.apply(to: [newer, old], changed: [retitled, middle], closed: [])

        #expect(merged.map(\.number) == [2, 3, 1])
        #expect(merged.last?.title == "Retitled")
    }

    @Test func closedPullRequestsLeaveTheList() {
        let staying = pullRequest(1)
        let closing = pullRequest(2)

        let merged = PullRequestChanges.apply(to: [staying, closing], changed: [], closed: [closing.id])

        #expect(merged.map(\.number) == [1])
    }

    @Test func aPullRequestBothChangedAndClosedLeaves() {
        let reopenedThenClosed = pullRequest(1)

        #expect(PullRequestChanges.apply(to: [], changed: [reopenedThenClosed], closed: [reopenedThenClosed.id]).isEmpty)
    }
}

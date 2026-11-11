import Foundation
import GitHubKit
import HermesUI
import Testing
@testable import Hermes

@Suite struct InboxFilterTests {
    private let mine = pullRequest(1, author: user("bojan"))
    private let theirs = pullRequest(2, author: user("alice"), draft: true)
    private let failing = pullRequest(3, author: user("alice"), checks: .failure)
    private let quietBot = pullRequest(4, author: user("renovate", bot: true))
    private let failingBot = pullRequest(5, author: user("renovate", bot: true), checks: .error)

    private func numbers(_ filter: InboxFilter, showingAllBots: Bool = false) -> [Int] {
        [mine, theirs, failing, quietBot, failingBot]
            .filter { filter.matches($0, viewer: "bojan", reviewRequested: [theirs.id, quietBot.id], showingAllBots: showingAllBots) }
            .map(\.number)
    }

    @Test func filters() {
        #expect(numbers(.yours) == [1])
        #expect(numbers(.drafts) == [2])
        #expect(numbers(.failing) == [3, 5])
        #expect(numbers(.all) == [1, 2, 3, 5])
    }

    @Test func needsReviewLeavesOutQuietBots() {
        #expect(numbers(.needsReview) == [2])
        #expect(numbers(.needsReview, showingAllBots: true) == [2, 4])
    }

    @Test func botsListsEveryBotWhateverTheSetting() {
        #expect(numbers(.bots) == [4, 5])
        #expect(numbers(.bots, showingAllBots: true) == [4, 5])
    }
}

@Suite struct RepositorySectionTests {
    private let issuesOnly = RepositoryRef(owner: "bojan", name: "notes")
    private let empty = RepositoryRef(owner: "bojan", name: "empty")

    @Test func repositoriesWithPullRequestsComeFirstAndIssueOnlyOnesStay() {
        let sections = repositorySections(
            repositories: [repository(issuesOnly, issues: 3), repository(empty), repository(airway, issues: 2)],
            pullRequests: [pullRequest(1)], showingAllBots: false
        )
        #expect(sections.map(\.ref) == [airway, issuesOnly])
        #expect(sections.map(\.openIssueCount) == [2, 3])
    }

    @Test func countsHiddenBots() throws {
        let bot = user("renovate", bot: true)
        let pullRequests = [pullRequest(1), pullRequest(2, author: bot), pullRequest(3, author: bot, checks: .failure)]

        let hidden = try #require(repositorySections(repositories: [], pullRequests: pullRequests, showingAllBots: false).first)
        #expect(hidden.shownPullRequestCount == 2)
        #expect(hidden.hiddenBotCount == 1)

        let shown = try #require(repositorySections(repositories: [], pullRequests: pullRequests, showingAllBots: true).first)
        #expect(shown.shownPullRequestCount == 3)
        #expect(shown.hiddenBotCount == 0)
    }

    @Test func aRepositoryWithOnlyHiddenBotsIsStillListed() {
        let sections = repositorySections(
            repositories: [repository(airway)], pullRequests: [pullRequest(2, author: user("renovate", bot: true))],
            showingAllBots: false
        )
        #expect(sections.map(\.hiddenBotCount) == [1])
        #expect(sections.first?.groups.isEmpty == true)
    }

    @Test func foldsAStackIntoOneGroup() throws {
        func entry(_ position: Int) -> StackEntry {
            StackEntry(stackID: "S", stackNumber: 1, size: 2, baseRefName: "main", position: position)
        }
        let section = try #require(repositorySections(
            repositories: [], pullRequests: [pullRequest(2, stack: entry(2)), pullRequest(9), pullRequest(1, stack: entry(1))],
            showingAllBots: false
        ).first)
        guard case .stack(let stack) = section.groups.first else {
            Testing.Issue.record("expected a stack first")
            return
        }
        #expect(stack.pullRequests.map(\.number) == [1, 2])
        #expect(section.groups.count == 2)
    }

    @Test func filteredListsLeaveOutRepositoriesWithoutMatches() {
        let sections = repositorySections(
            repositories: [repository(issuesOnly, issues: 3), repository(airway)], pullRequests: [pullRequest(1)],
            showingAllBots: true, includingEmpty: false
        )
        #expect(sections.map(\.ref) == [airway])
    }
}

@Suite struct TimelineTests {
    @Test func mergesCommentsAndReviewsByDateAndDropsEmptyOnes() {
        func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: offset) }
        let detail = PullRequestDetail(
            id: "PR", body: "",
            comments: [Comment(id: "c1", author: user("alice"), body: "First", createdAt: date(10))],
            reviews: [
                Review(id: "r1", author: user("bob"), state: .approved, body: "", submittedAt: date(30)),
                Review(id: "r2", author: user("bob"), state: .commented, body: "", submittedAt: date(5)),
                Review(id: "r3", author: user("bob"), state: .commented, body: "A summary", submittedAt: date(20)),
                Review(id: "r4", author: user("bojan"), state: .pending, body: "Draft", submittedAt: nil),
            ],
            requestedReviewers: [], commits: [], reviewThreads: []
        )
        #expect(timeline(of: detail).map(\.id) == ["c1", "r3", "r1"])
    }
}

@Suite struct SharedViewLogicTests {
    @Test(arguments: [
        (30.0, "now"), (5 * 60, "5m"), (3 * 3600, "3h"), (2 * 86400, "2d"), (20 * 86400, "2w"),
        (100 * 86400, "3mo"), (800 * 86400, "2y"),
    ] as [(Double, String)])
    func compactAges(seconds: Double, expected: String) {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(compactAge(of: now.addingTimeInterval(-seconds), now: now) == expected)
    }

    @Test func parsesHexColors() {
        #expect(RGB(hex: "ff0000") == RGB(red: 1, green: 0, blue: 0))
        #expect(RGB(hex: "#00FF00") == RGB(red: 0, green: 1, blue: 0))
        #expect(RGB(hex: "fff") == nil)
        #expect(RGB(hex: "zzzzzz") == nil)
    }

    @Test func labelTextReadsOnBothBackgrounds() throws {
        let navy = try #require(RGB(hex: "0e2a5c"))
        let yellow = try #require(RGB(hex: "fbca04"))

        #expect(navy.legible(onDark: true).luminance > 0.7)
        #expect(navy.legible(onDark: false) == navy)
        #expect(yellow.legible(onDark: false).luminance < 0.4)
        #expect(yellow.legible(onDark: true) == yellow)
    }
}

@Suite struct MergeSetTests {
    private func stacked(_ number: Int, position: Int, stack: String = "S1") -> PullRequest {
        pullRequest(number, stack: StackEntry(stackID: stack, stackNumber: 9, size: 3, baseRefName: "main", position: position))
    }

    @Test func aStackedPullRequestMergesWithTheOnesBelowIt() {
        let all = [stacked(12, position: 3), stacked(10, position: 1), stacked(11, position: 2), stacked(20, position: 1, stack: "S2"), pullRequest(30)]
        #expect(all[2].mergeSet(among: all).map(\.number) == [10, 11])
        #expect(all[0].mergeSet(among: all).map(\.number) == [10, 11, 12])
        #expect(all[1].mergeSet(among: all).map(\.number) == [10])
    }

    @Test func aPullRequestOutsideAStackMergesAlone() {
        let single = pullRequest(30)
        #expect(single.mergeSet(among: [single, stacked(10, position: 1)]).map(\.number) == [30])
    }
}

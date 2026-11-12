import Foundation
import Testing
@testable import GitHubKit

private func pullRequest(
    _ number: Int,
    bot: Bool = false,
    checkState: StatusState? = .success,
    mergeable: MergeableState = .mergeable,
    stack: StackEntry? = nil
) -> PullRequest {
    PullRequest(
        id: "PR_\(number)", number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/o/r/pull/\(number)")!,
        repository: RepositoryRef(owner: "o", name: "r"),
        author: User(login: bot ? "renovate" : "octocat", avatarURL: URL(string: "https://example.com/a.png")!, isBot: bot),
        isDraft: false, createdAt: .distantPast, updatedAt: .distantPast, headRefName: "head", baseRefName: "main",
        headOID: "abc", reviewDecision: nil, additions: 1, deletions: 1, changedFileCount: 1, mergeable: mergeable,
        labels: [], checkState: checkState, stack: stack, closingIssueNumbers: []
    )
}

private func entry(_ stackID: String, position: Int) -> StackEntry {
    StackEntry(stackID: stackID, stackNumber: 1, size: 3, baseRefName: "main", position: position)
}

@Suite struct BotFilterTests {
    @Test func pullRequestsByPeopleAreAlwaysShown() {
        #expect(pullRequest(1).isShown(showingAllBots: false))
        #expect(pullRequest(1, checkState: .failure).isShown(showingAllBots: false))
    }

    @Test(arguments: [StatusState.success, .pending, .expected, nil])
    func healthyBotPullRequestsAreHidden(checkState: StatusState?) {
        #expect(!pullRequest(1, bot: true, checkState: checkState).isShown(showingAllBots: false))
    }

    @Test func botPullRequestsWithUnknownMergeabilityAreHidden() {
        #expect(!pullRequest(1, bot: true, mergeable: .unknown).isShown(showingAllBots: false))
    }

    @Test(arguments: [StatusState.failure, .error])
    func botPullRequestsWithFailedChecksAreShown(checkState: StatusState) {
        #expect(pullRequest(1, bot: true, checkState: checkState).isShown(showingAllBots: false))
    }

    @Test func botPullRequestsWithConflictsAreShown() {
        #expect(pullRequest(1, bot: true, mergeable: .conflicting).isShown(showingAllBots: false))
    }

    @Test func showingAllBotsShowsHealthyBotPullRequests() {
        #expect(pullRequest(1, bot: true).isShown(showingAllBots: true))
    }

    @Test func pullRequestsByDeletedAccountsAreShown() {
        let ghost = PullRequest(
            id: "PR_1", number: 1, title: "PR", url: URL(string: "https://github.com/o/r/pull/1")!,
            repository: RepositoryRef(owner: "o", name: "r"), author: nil, isDraft: false, createdAt: .distantPast,
            updatedAt: .distantPast, headRefName: "head", baseRefName: "main", headOID: "abc", reviewDecision: nil,
            additions: 0, deletions: 0, changedFileCount: 0, mergeable: .mergeable, labels: [], checkState: nil,
            stack: nil, closingIssueNumbers: []
        )
        #expect(ghost.isShown(showingAllBots: false))
    }

    @Test func fixtureHidesTheHealthyBotAndShowsTheFailingOne() throws {
        let pullRequests = try graphQLFixture("pull_requests", as: SearchData<PullRequest>.self).search.nodes
        let shown = pullRequests.filter { $0.isShown(showingAllBots: false) }
        #expect(shown.map(\.number) == [96, 95, 94, 27])
    }
}

@Suite struct StackGroupingTests {
    @Test func stackMembersAreOrderedByPositionWhereTheFirstOneAppeared() {
        let groups = PullRequest.grouped([
            pullRequest(10),
            pullRequest(13, stack: entry("A", position: 3)),
            pullRequest(11, stack: entry("A", position: 1)),
            pullRequest(20),
            pullRequest(12, stack: entry("A", position: 2)),
        ])

        #expect(groups.count == 3)
        #expect(groups[0] == .single(pullRequest(10)))
        guard case .stack(let stack) = groups[1] else {
            Issue.record("Expected a stack")
            return
        }
        #expect(stack.id == "A")
        #expect(stack.size == 3)
        #expect(stack.baseRefName == "main")
        #expect(stack.pullRequests.map(\.number) == [11, 12, 13])
        #expect(groups[2] == .single(pullRequest(20)))
    }

    @Test func differentStacksStaySeparate() {
        let groups = PullRequest.grouped([
            pullRequest(2, stack: entry("A", position: 2)),
            pullRequest(3, stack: entry("B", position: 1)),
            pullRequest(1, stack: entry("A", position: 1)),
        ])

        #expect(groups.map(\.id) == ["A", "B"])
    }

    @Test func aLoneVisibleMemberIsStillAStack() {
        let groups = PullRequest.grouped([pullRequest(2, stack: entry("A", position: 2))])

        guard case .stack(let stack) = groups.first else {
            Issue.record("Expected a stack")
            return
        }
        #expect(stack.pullRequests.map(\.number) == [2])
        #expect(stack.size == 3)
    }

    @Test func noPullRequestsGiveNoGroups() {
        #expect(PullRequest.grouped([]).isEmpty)
    }

    @Test func fixtureGroupsTheAirwayStackBottomFirst() throws {
        let pullRequests = try graphQLFixture("pull_requests", as: SearchData<PullRequest>.self).search.nodes
        let groups = PullRequest.grouped(pullRequests)

        #expect(groups.count == 3)
        guard case .stack(let stack) = groups[0] else {
            Issue.record("Expected a stack")
            return
        }
        #expect(stack.number == 97)
        #expect(stack.pullRequests.map(\.number) == [94, 95, 96])
    }
}

@Suite struct MergeReadinessTests {
    private func readiness(_ state: MergeStateStatus, methods: [MergeMethod] = [.squash], canPush: Bool = true) -> MergeReadiness {
        MergeReadiness(state: state, allowedMethods: methods, defaultMethod: methods.first ?? .merge, viewerCanPush: canPush)
    }

    @Test(arguments: [MergeStateStatus.clean, .hasHooks, .unstable])
    func mergesWhenGitHubSaysItCan(state: MergeStateStatus) {
        #expect(readiness(state).canMerge)
    }

    @Test(arguments: [MergeStateStatus.behind, .blocked, .dirty, .draft, .unknown])
    func doesNotMergeOtherwise(state: MergeStateStatus) {
        #expect(readiness(state).blocker != nil)
    }

    @Test func needsPushAccessAndAnAllowedMethod() {
        #expect(!readiness(.clean, canPush: false).canMerge)
        #expect(!readiness(.clean, methods: []).canMerge)
        // GitHub reports a draft as clean.
        #expect(!MergeReadiness(state: .clean, allowedMethods: [.squash], defaultMethod: .squash, viewerCanPush: true, isDraft: true).canMerge)
    }

    @Test(arguments: [MergeStateStatus.blocked, .behind])
    func bypassesAMissingRequirementWhenGitHubAllows(state: MergeStateStatus) {
        let bypassing = MergeReadiness(state: state, allowedMethods: [.squash], defaultMethod: .squash, viewerCanPush: true, viewerCanBypass: true)

        #expect(!bypassing.canMerge)
        #expect(bypassing.canBypass)
        #expect(!readiness(state).canBypass)
    }

    @Test(arguments: [MergeStateStatus.dirty, .draft, .unknown, .clean])
    func neverBypassesConflictsDraftsOrWhatAlreadyMerges(state: MergeStateStatus) {
        #expect(!MergeReadiness(state: state, allowedMethods: [.squash], defaultMethod: .squash, viewerCanPush: true, viewerCanBypass: true).canBypass)
    }

    @Test func neverBypassesADraftReportedAsBlocked() {
        #expect(!MergeReadiness(
            state: .blocked, allowedMethods: [.squash], defaultMethod: .squash, viewerCanPush: true, isDraft: true, viewerCanBypass: true
        ).canBypass)
    }
}

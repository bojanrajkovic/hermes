import Foundation
import GitHubKit
import Testing
@testable import Hermes

/// Which held pull request an event is about. With none, Hermes loads the account.
@MainActor
struct EventTargetTests {
    private func status(on commit: String, in repository: RepositoryRef = airway) -> WebhookEvent {
        WebhookEvent(repository: repository, pullRequest: nil, commit: commit)
    }

    @Test func anEventThatNamesAPullRequestFindsItByNumber() {
        let held = [pullRequest(7, head: "aaa"), pullRequest(8, head: "bbb")]

        #expect(WebhookEvent(repository: airway, pullRequest: 8).pullRequest(among: held)?.number == 8)
        // The number wins over the commit, which a check on an older commit of the pull request also carries.
        #expect(WebhookEvent(repository: airway, pullRequest: 8, commit: "aaa").pullRequest(among: held)?.number == 8)
        #expect(WebhookEvent(repository: airway, pullRequest: 9).pullRequest(among: held) == nil)
    }

    @Test func aStatusFindsThePullRequestWhoseHeadItIsOn() {
        let held = [pullRequest(7, head: "aaa"), pullRequest(7, in: repairScripts, head: "bbb")]

        #expect(status(on: "aaa").pullRequest(among: held)?.key == ItemKey(repository: airway, number: 7))
        // The same commit ID in another repository is another commit.
        #expect(status(on: "bbb").pullRequest(among: held) == nil)
    }

    @Test func aStatusFindsAPullRequestHeldOnlyByNumber() {
        // Opened by its number, or in a repository the viewer can only read: not in the open list.
        let data = AccountData(login: "bojan", client: GitHubClient(token: { "" }))
        let opened = pullRequest(7, head: "aaa")
        data.store(.pullRequest(opened), for: opened.key)
        #expect(data.pullRequests.isEmpty)

        #expect(status(on: "aaa").pullRequest(among: data.heldPullRequests) == opened)
    }

    @Test func aStatusOnACommitNoHeldPullRequestHeadsFindsNone() {
        // Right after a push, the held head is still the old commit, so the account loads.
        let held = [pullRequest(7, head: "old-head")]

        #expect(status(on: "new-head").pullRequest(among: held) == nil)
        #expect(WebhookEvent(repository: airway, pullRequest: nil).pullRequest(among: held) == nil)
    }
}

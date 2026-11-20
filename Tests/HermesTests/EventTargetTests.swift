import Foundation
import GitHubKit
import TestSupport
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

    @Test func aStatusOnACommitNoHeldPullRequestHeadsFindsNone() {
        // Right after a push, the held head is still the old commit, so the account loads.
        let held = [pullRequest(7, head: "old-head")]

        #expect(status(on: "new-head").pullRequest(among: held) == nil)
        #expect(WebhookEvent(repository: airway, pullRequest: nil).pullRequest(among: held) == nil)
    }
}

@MainActor
struct LoaderTests {
    @Test func aChangeIsAppliedToWhatIsLoadedAndNotBeforeAnythingIs() async {
        let loader = Loader<[Int]>()
        // Nothing is loaded yet, so there is nothing to change and the caller loads.
        #expect(!loader.apply { $0 + [3] })

        await loader.load { [1, 2] }
        #expect(loader.apply { $0 + [3] })
        #expect(loader.value == [1, 2, 3])

        // A change that can't be applied leaves the value alone.
        #expect(!loader.apply { _ in nil })
        #expect(loader.value == [1, 2, 3])
    }

    @Test func aChangeAppliedDuringALoadMakesTheLoadRunAgain() async {
        let loader = Loader<[Int]>()
        await loader.load { [1] }

        var runs = 0
        await loader.load {
            runs += 1
            // The first answer was asked for before the change, so it lacks it.
            guard runs == 1 else { return [1, 2] }
            _ = loader.apply { $0 + [2] }
            return [1]
        }

        #expect(runs == 2)
        #expect(loader.value == [1, 2])
    }
}

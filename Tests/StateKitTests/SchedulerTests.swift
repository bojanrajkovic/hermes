import Foundation
import Testing
@testable import StateKit

@MainActor
struct SchedulerTests {
    @MainActor final class Polls {
        var count = 0
    }

    /// Waits for the main actor to run the tasks the test started.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func twoScreensShowingOneInterestShareOnePoll() async {
        let polls = Polls()
        let scheduler = Scheduler(tick: { _ in .milliseconds(10) }) { _ in polls.count += 1 }

        let first = Task { await scheduler.showing(.account("bojan")) }
        let second = Task { await scheduler.showing(.account("bojan")) }
        await settle()
        #expect(scheduler.polling == [.account("bojan")])

        try? await Task.sleep(for: .milliseconds(55))
        // One loop ticks about five times in 55 ms. Two loops would tick about ten. A busy machine ticks fewer.
        #expect((1...7).contains(polls.count))

        // The poll keeps running while one screen still shows the interest.
        first.cancel()
        await settle()
        #expect(scheduler.polling == [.account("bojan")])

        second.cancel()
        await settle()
        #expect(scheduler.polling.isEmpty)
    }

    @Test func eachInterestGetsItsOwnPoll() async {
        let scheduler = Scheduler(tick: { _ in .seconds(60) }) { _ in }

        let mine = Task { await scheduler.showing(.account("bojan")) }
        let theirs = Task { await scheduler.showing(.account("hermes-org")) }
        await settle()
        #expect(scheduler.polling == [.account("bojan"), .account("hermes-org")])

        mine.cancel()
        await settle()
        #expect(scheduler.polling == [.account("hermes-org")])
        theirs.cancel()
    }

    @Test func aTickRefreshesWhileActiveAndWaitsForTheIntervalInTheBackground() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)

        #expect(shouldRefresh(isActive: true, lastAttempt: now.addingTimeInterval(-1), backgroundInterval: 60, now: now))
        #expect(!shouldRefresh(isActive: false, lastAttempt: now.addingTimeInterval(-30), backgroundInterval: 60, now: now))
        #expect(shouldRefresh(isActive: false, lastAttempt: now.addingTimeInterval(-60), backgroundInterval: 60, now: now))
        // An account that never loaded loads at the first tick.
        #expect(shouldRefresh(isActive: false, lastAttempt: nil, backgroundInterval: 60, now: now))
    }
}

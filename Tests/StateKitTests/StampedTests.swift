import Foundation
import Testing
@testable import StateKit

struct StampedTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    @Test func aFetchThatStartedLaterWinsWhicheverArrivesFirst() {
        var count = Stamped(8, fetchedAt: at(0))

        // The later fetch arrives first, then the earlier one's answer comes in.
        let tookLater = count.write(0, startedAt: at(20))
        let tookEarlier = count.write(8, startedAt: at(10))
        #expect(tookLater)
        #expect(!tookEarlier)
        #expect(count.value == 0)
        #expect(count.fetchedAt == at(20))
    }

    @Test func aFetchFromTheSameMomentReplacesTheValue() {
        var count = Stamped(8, fetchedAt: at(10))

        let took = count.write(3, startedAt: at(10))
        #expect(took)
        #expect(count.value == 3)
    }
}

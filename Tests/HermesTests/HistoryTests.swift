import Foundation
import GitHubKit
import TestSupport
import Testing
@testable import Hermes

@Suite struct HistoryTests {
    private func place(_ number: Int?, scope: Scope = .filter(.needsAttention), tab: PullRequestTab = .files) -> Place {
        Place(
            scope: scope, list: .pullRequests,
            destination: number.map { .pullRequest(ItemKey(repository: airway, number: $0)) }, tab: tab
        )
    }

    private func history(_ numbers: Int?...) -> NavigationHistory {
        var history = NavigationHistory()
        for number in numbers { history.record(place(number)) }
        return history
    }

    @Test func backAndForwardRetraceRecordedPlaces() {
        var history = history(nil, 1, 2)

        #expect(history.back { _ in true } == place(1))
        #expect(history.back { _ in true } == place(nil))
        #expect(history.back { _ in true } == nil)
        #expect(history.current == place(nil))
        #expect(history.forward { _ in true } == place(1))
        #expect(history.current == place(1))
    }

    @Test func recordingAfterGoingBackClearsTheForwardPlaces() {
        var history = history(1, 2)
        _ = history.back { _ in true }

        history.record(place(3))

        #expect(!history.canGoForward { _ in true })
        #expect(history.back { _ in true } == place(1))
    }

    @Test func aTabSwitchUpdatesTheCurrentPlace() {
        var history = history(1, 2)

        history.record(place(2, tab: .checks))

        #expect(history.current == place(2, tab: .checks))
        #expect(history.back { _ in true } == place(1))
        #expect(history.forward { _ in true } == place(2, tab: .checks))
    }

    @Test func aScopeChangeAddsAnEntry() {
        var history = history(1)

        history.record(place(1, scope: .filter(.drafts)))

        #expect(history.back { _ in true } == place(1))
    }

    @Test func recordingTheCurrentPlaceAgainKeepsTheForwardPlaces() {
        var history = history(1, 2)
        _ = history.back { _ in true }

        history.record(place(1))

        #expect(history.canGoForward { _ in true })
    }

    @Test func goingBackSkipsAndDropsPlacesThatCannotBeShown() {
        var history = history(1, 2, 3, 4)
        let shown = { (place: Place) in place != self.place(2) && place != self.place(3) }

        #expect(history.canGoBack(shown))
        #expect(history.back(shown) == place(1))
        #expect(history.forward { _ in true } == place(4))
        #expect(history.back { _ in true } == place(1))
    }

    @Test func goingForwardSkipsAndDropsPlacesThatCannotBeShown() {
        var history = history(1, 2, 3)
        _ = history.back { _ in true }
        _ = history.back { _ in true }

        #expect(history.forward { $0 != place(2) } == place(3))
        #expect(history.back { _ in true } == place(1))
    }

    @Test func backReturnsNilAndDropsPlacesWhenEveryEarlierPlaceIsRejected() {
        var history = history(1, 2)

        #expect(!history.canGoBack { $0 != place(1) })
        #expect(history.back { $0 != place(1) } == nil)
        #expect(history.current == place(2))
        #expect(!history.canGoBack { _ in true })
    }

    @Test func keepsTheLatestPlacesUpToTheLimit() {
        var history = NavigationHistory()
        for number in 1...NavigationHistory.limit + 10 { history.record(place(number)) }

        var oldest = history.current
        while let earlier = history.back({ _ in true }) { oldest = earlier }

        // The test records places 1 to 110. Place 110 is current, so the 100 places behind it are 10 to 109.
        #expect(oldest == place(10))
    }
}

import Foundation

/// What a window shows: the sidebar scope, the repository list, the open item, and the pull request tab.
struct Place: Hashable, Sendable {
    var scope: Scope
    var list: RepositoryList
    var destination: Destination?
    var tab: PullRequestTab
}

/// A window's back and forward history, like a browser's.
///
/// `record(_:)` replaces the current place when the new place has the same scope and destination.
/// Switching tabs or lists updates the current entry, so going back reopens an item on the tab you
/// left it on. Any other place becomes current, and `record(_:)` clears the forward places.
struct NavigationHistory {
    /// At most this many places stay behind the current one.
    static let limit = 100

    /// The place on screen. Nil until the first call to `record(_:)`.
    private(set) var current: Place?
    /// Places behind the current one, nearest last.
    private var backward: [Place] = []
    /// Places ahead of the current one, nearest last.
    private var forward: [Place] = []

    mutating func record(_ place: Place) {
        if let current, current.scope != place.scope || current.destination != place.destination {
            backward.append(current)
            if backward.count > Self.limit { backward.removeFirst() }
            forward = []
        }
        current = place
    }

    /// Moves to the nearest earlier place that `canShow` accepts, and removes the places it rejected on the way.
    ///
    /// - Returns: The place to show, or nil if `canShow` rejects every earlier place.
    mutating func back(_ canShow: (Place) -> Bool) -> Place? {
        Self.step(&current, from: &backward, to: &forward, canShow)
    }

    /// Moves to the nearest later place that `canShow` accepts, and removes the places it rejected on the way.
    mutating func forward(_ canShow: (Place) -> Bool) -> Place? {
        Self.step(&current, from: &forward, to: &backward, canShow)
    }

    func canGoBack(_ canShow: (Place) -> Bool) -> Bool { backward.contains(where: canShow) }
    func canGoForward(_ canShow: (Place) -> Bool) -> Bool { forward.contains(where: canShow) }

    /// Static, so it can take `current`, `backward`, and `forward` `inout` in one call.
    private static func step(
        _ current: inout Place?, from source: inout [Place], to target: inout [Place], _ canShow: (Place) -> Bool
    ) -> Place? {
        guard let leaving = current else { return nil }
        while let place = source.popLast() {
            guard canShow(place) else { continue }
            target.append(leaving)
            current = place
            return place
        }
        return nil
    }
}

extension WindowModel {
    var place: Place { Place(scope: scope, list: repositoryList, destination: destination, tab: pullRequestTab) }

    /// Records the current `place` in the window's history. `WindowRoot` calls this whenever `place` changes.
    func recordPlace() { history.record(place) }

    /// Clears the history and makes the current place its first entry.
    func startHistory() {
        history = NavigationHistory()
        recordPlace()
    }

    var canGoBack: Bool { history.canGoBack(canShow) }
    var canGoForward: Bool { history.canGoForward(canShow) }

    func goBack() { if let place = history.back(canShow) { restore(place) } }
    func goForward() { if let place = history.forward(canShow) { restore(place) } }

    /// Checks whether the window can still show a place. A place passes when the sidebar lists its
    /// repository and its session, if any, is still running. A pull request or issue always passes,
    /// because the detail pane can load an item that left the lists.
    private var canShow: (Place) -> Bool {
        let listed = Set(sections.map(\.ref))
        let hasLoaded = hasLoaded
        let running = Set(sessions.sessions.map(\.id))
        return { place in
            switch place.scope {
            case .repository(let repository): guard listed.contains(repository) || !hasLoaded else { return false }
            case .sessions: guard !running.isEmpty else { return false }
            case .filter: break
            }
            if case .session(let id) = place.destination { return running.contains(id) }
            return true
        }
    }

    private func restore(_ place: Place) {
        scope = place.scope
        repositoryList = place.list
        destination = place.destination
        pullRequestTab = place.tab
        if let destination = place.destination { bringIntoView(destination) }
    }
}

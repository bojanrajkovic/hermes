import GitHubKit

/// How often a relay has said a part of a pull request changed. A screen that shows the part
/// reloads it when its count rises, ahead of its own polling.
struct EventCounts: Equatable {
    typealias Part = WritableKeyPath<EventCounts, Int>

    var threads = 0
    var checks = 0

    /// The count an event raises, by GitHub's name for the event. Nil for an event that
    /// changes neither part.
    static func part(ofEvent name: String) -> Part? {
        switch name {
        case "pull_request_review_comment", "pull_request_review_thread": \.threads
        case "check_run", "check_suite", "status": \.checks
        default: nil
        }
    }
}

/// Keeps a burst of events about one pull request from loading it once per event. A CI run
/// sends two events per job, and a relay sends them for every pull request in an account.
///
/// The first event loads at once. Events that arrive while that load runs, and for a few
/// seconds after, become one more load.
struct EventBursts {
    /// The pull requests with a load running, whether an event came since it started, and
    /// the parts those events named.
    private var running: [ItemKey: (again: Bool, parts: Set<EventCounts.Part>)] = [:]

    /// Records an event.
    ///
    /// - Returns: Whether to load the pull request now. False when a load is running, which
    ///   then runs once more.
    mutating func shouldLoad(_ key: ItemKey, part: EventCounts.Part?) -> Bool {
        guard running[key] != nil else {
            running[key] = (false, [])
            return true
        }
        running[key]?.again = true
        if let part { running[key]?.parts.insert(part) }
        return false
    }

    /// Records that a load finished.
    ///
    /// - Returns: The parts named by the events that came during it, when the pull request
    ///   should load again. Nil when none came, which ends the burst.
    mutating func loaded(_ key: ItemKey) -> Set<EventCounts.Part>? {
        guard let state = running[key], state.again else {
            running[key] = nil
            return nil
        }
        running[key] = (false, [])
        return state.parts
    }
}

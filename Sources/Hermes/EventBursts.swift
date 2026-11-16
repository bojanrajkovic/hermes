import Foundation
import GitHubKit

/// What deliveries have said about each part of a pull request. A screen that shows a part
/// applies or reloads when the part's count rises, ahead of its own polling.
struct EventCounts: Equatable {
    typealias Part = WritableKeyPath<EventCounts, WebhookChanges>

    /// The description, the conversation, and the reviews.
    var detail = WebhookChanges()
    var threads = WebhookChanges()
    var checks = WebhookChanges()

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

extension WebhookEvent {
    /// The pull request this event is about, among the ones Hermes holds. Nil when it holds
    /// none: a new pull request, or a commit that is no held pull request's head, which a
    /// push makes true until the pull request is loaded again.
    ///
    /// A status names only a commit, and a check often does, so those find the pull request
    /// by its head. `held` has one copy of each pull request, the one its row shows, so a
    /// status on an older commit finds none.
    func pullRequest(among held: [PullRequest]) -> PullRequest? {
        held.first { candidate in
            guard candidate.repository == repository else { return false }
            if let number = pullRequest { return candidate.number == number }
            return commit != nil && candidate.headOID == commit
        }
    }
}

/// The `pull_request` payloads that have been put into an account's rows.
struct AppliedPayloads {
    /// How many payloads each row took.
    private var counts: [ItemKey: Int] = [:]
    /// The update time of the payload each row took last.
    private var updatedAt: [ItemKey: Date] = [:]

    /// Records a payload for a row.
    ///
    /// - Returns: Whether to apply it. False when it is older than the last one the row
    ///   took: deliveries can arrive out of order, and the older one would undo the newer.
    mutating func take(_ fields: PullRequestFields, for key: ItemKey) -> Bool {
        if let last = updatedAt[key], fields.updatedAt < last { return false }
        updatedAt[key] = fields.updatedAt
        counts[key, default: 0] += 1
        return true
    }

    /// The rows that took a payload since `earlier`. A load that ran meanwhile may have
    /// asked GitHub before the payload's change, so its answer would undo the change.
    func rows(since earlier: AppliedPayloads) -> Set<ItemKey> {
        Set(counts.filter { $0.value != earlier.counts[$0.key] }.keys)
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

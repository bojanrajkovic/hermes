import Foundation
import GitHubKit
import StateKit

/// What one webhook event makes Hermes load. Events share a load when they name the same one.
enum EventLoad: Hashable {
    /// An account's lists, for a pull request Hermes doesn't hold yet.
    case account(String)
    /// One pull request's or issue's record.
    case record(ItemKey)
    /// A pull request's detail: its conversation, reviews, and review threads.
    case detail(ItemKey)
    case checks(CommitKey)
    /// A repository's loaded issue list.
    case issues(RepositoryRef)
}

/// Which part of a pull request an event changed, by GitHub's name for the event, for a
/// payload Hermes can't apply. A forwarder's deliveries carry no name.
enum EventPart {
    case threads, checks

    init?(event name: String?) {
        switch name {
        case "pull_request_review_comment", "pull_request_review_thread": self = .threads
        case "check_run", "check_suite", "status": self = .checks
        default: return nil
        }
    }
}

extension WebhookEvent {
    /// The pull request this event is about, among the ones Hermes holds. Nil when it holds
    /// none: a new pull request, or a commit that is no held pull request's head, which a
    /// push makes true until the pull request is loaded again.
    ///
    /// A status names only a commit, and a check often does, so those find the pull request
    /// by its head. `held` has one copy of each pull request, open ones first, so a status
    /// on a commit that a closed and an open pull request share finds the open one.
    func pullRequest(among held: [PullRequest]) -> PullRequest? {
        held.first { candidate in
            guard candidate.repository == repository else { return false }
            if let number = pullRequest { return candidate.number == number }
            return commit != nil && candidate.headOID == commit
        }
    }
}

/// Keeps a burst of events from loading the same thing once per event. A CI run sends two
/// events per job, and a relay sends them for every pull request in an account.
///
/// The first event loads at once. Events that arrive while that load runs, and for a few
/// seconds after, become one more load.
struct EventBursts {
    /// The loads running, and whether an event came since each started.
    private var running: [EventLoad: Bool] = [:]

    /// Records an event.
    ///
    /// - Returns: Whether to load now. False when the load is running, which then runs once more.
    mutating func shouldLoad(_ load: EventLoad) -> Bool {
        guard running[load] != nil else {
            running[load] = false
            return true
        }
        running[load] = true
        return false
    }

    /// Records that a load finished.
    ///
    /// - Returns: Whether to load again, for the events that came during it. False ends the burst.
    mutating func loaded(_ load: EventLoad) -> Bool {
        guard running[load] == true else {
            running[load] = nil
            return false
        }
        running[load] = false
        return true
    }
}

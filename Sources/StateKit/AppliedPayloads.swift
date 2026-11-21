import Foundation
import GitHubKit

/// The `pull_request` payloads that have been put into an account's rows.
struct AppliedPayloads: Sendable {
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

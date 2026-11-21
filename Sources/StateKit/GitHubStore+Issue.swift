import Foundation
import GitHubKit

extension GitHubStore {
    /// Loads an issue's description and comments unless the last load saw the issue's
    /// current record. The issue view calls it when it opens and when the record's update
    /// time moves, which the account's refresh and webhooks make happen.
    public func loadIssueDetailIfStale(_ key: ItemKey) async {
        if let loadedFor = issueDetailLoadedFor[key], loadedFor == issues[key]?.updatedAt { return }
        await loadIssueDetail(key)
    }

    /// Loads an issue's description and first 100 comments. The comment count goes into the
    /// issue's record, which every view reads it from.
    public func loadIssueDetail(_ key: ItemKey) async {
        let updatedAt = issues[key]?.updatedAt
        do {
            let loaded = try await client.issueDetail(repository: key.repository, number: key.number)
            issueDetails[key] = loaded.detail
            issues[key]?.commentCount = loaded.commentCount
            issueDetailErrors[key] = nil
            issueDetailLoadedFor[key] = updatedAt
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            // Unrecorded, so opening the issue again tries again.
            issueDetailErrors[key] = describe(error)
        }
    }
}

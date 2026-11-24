import Foundation
import GitHubKit

extension GitHubStore {
    /// Adds a comment to a pull request's or an issue's conversation, outside any review, and
    /// shows it in the loaded conversation at once.
    ///
    /// A webhook may deliver the comment first, or an issue reload may bring it, so it is
    /// added only when it is not there yet.
    ///
    /// - Parameters:
    ///   - body: Markdown.
    ///   - subjectID: The node ID of the pull request or issue.
    ///   - key: The pull request or issue, for finding its loaded conversation.
    /// - Throws: What GitHub answered. Nothing in the store changes then.
    public func addComment(_ body: String, subjectID: String, to key: ItemKey) async throws {
        let comment = try await client.addComment(subjectID: subjectID, body: body)

        if applyToDetail(.comment(comment, deleted: false), for: key) { return }
        guard let detail = issueDetails[key], !detail.comments.contains(where: { $0.id == comment.id }) else { return }
        issueDetails[key] = IssueDetail(body: detail.body, comments: detail.comments + [comment])
        issues[key]?.commentCount += 1
    }
}

import Foundation

extension GitHubClient {
    /// Adds a comment to the conversation of a pull request or an issue, outside any review.
    ///
    /// - Parameters:
    ///   - subjectID: The node ID of the pull request or issue (`PullRequest.id`, `Issue.id`).
    ///   - body: Markdown.
    /// - Returns: The comment as GitHub stored it.
    /// - Throws: `GitHubError.graphQL` when GitHub refuses the comment, such as on a locked
    ///   conversation. Other `GitHubError` cases as for any request.
    public func addComment(subjectID: String, body: String) async throws -> Comment {
        let query = """
            mutation($input: AddCommentInput!) {
              addComment(input: $input) { commentEdge { node { \(commentFields) } } }
            }
            """
        let input: JSONValue = .object(["subjectId": .string(subjectID), "body": .string(body)])
        return try await graphQL(query, variables: ["input": input], as: Added.self).addComment.commentEdge.node
    }

    private struct Added: Decodable, Sendable {
        struct Result: Decodable, Sendable {
            struct Edge: Decodable, Sendable { let node: Comment }
            let commentEdge: Edge
        }
        let addComment: Result
    }
}

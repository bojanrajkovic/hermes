import Foundation

/// A pull request or issue: its repository and number.
public struct ItemKey: Hashable, Sendable, CustomStringConvertible {
    public let repository: RepositoryRef
    public let number: Int

    public init(repository: RepositoryRef, number: Int) {
        self.repository = repository
        self.number = number
    }

    public var description: String { "\(repository)#\(number)" }
}

extension PullRequest {
    public var key: ItemKey { ItemKey(repository: repository, number: number) }
}

/// A pull request or an issue, whichever a number names.
public enum FetchedItem: Decodable, Sendable {
    case pullRequest(PullRequest)
    case issue(Issue)

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .typename) == "PullRequest" {
            self = .pullRequest(try PullRequest(from: decoder))
        } else {
            self = .issue(try Issue(from: decoder))
        }
    }
}

extension GitHubClient {
    /// Loads the pull request or issue with a number, in any state.
    ///
    /// The field lists repeat the ones `GitHubKit` uses for its list queries,
    /// because `PullRequest` and `Issue` decode exactly those fields.
    public func item(_ key: ItemKey) async throws -> FetchedItem {
        struct Data: Decodable, Sendable {
            struct Repository: Decodable, Sendable { let issueOrPullRequest: FetchedItem }
            let repository: Repository
        }
        let user = "__typename login avatarUrl"
        let query = """
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                issueOrPullRequest(number: $number) {
                  __typename
                  ... on PullRequest {
                    \(PullRequest.fields)
                  }
                  ... on Issue {
                    id number title url state createdAt updatedAt
                    author { \(user) }
                    labels(first: 20) { nodes { name color } }
                    comments { totalCount }
                    assignees(first: 20) { nodes { \(user) } }
                    closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
                      nodes { number title state headRefName }
                    }
                  }
                }
              }
            }
            """
        return try await graphQL(
            query,
            variables: ["owner": .string(key.repository.owner), "name": .string(key.repository.name), "number": .int(key.number)],
            as: Data.self
        ).repository.issueOrPullRequest
    }
}

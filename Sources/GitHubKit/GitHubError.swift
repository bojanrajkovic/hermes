import Foundation

/// Everything `GitHubKit` throws, apart from `URLError` (no network, timeout)
/// and `CancellationError`, which pass through unchanged.
public enum GitHubError: Error, Sendable, Equatable {
    /// The `gh` command line tool was not found in the usual install
    /// locations or on the login shell's `PATH`.
    case ghNotInstalled
    /// `gh auth token` failed or printed nothing. `message` is what `gh` wrote
    /// to standard error.
    case ghNotLoggedIn(message: String)
    /// GitHub answered with a non-success status that has no more specific
    /// case. `message` is GitHub's own error message, or empty.
    case http(status: Int, message: String)
    /// A GraphQL response carried errors. Partial data is discarded.
    case graphQL([GraphQLError])
    /// The primary or secondary rate limit is used up. Requests succeed again
    /// after `resetAt`.
    case rateLimited(resetAt: Date)
    /// The response did not have the expected shape. `description` names the
    /// failing key.
    case decoding(description: String)
    /// GitHub refused to render the diff because it is too large (HTTP 406).
    /// Compute the diff from a local clone instead.
    case diffTooLarge
    /// The job has no downloadable log: it expired, has not started, was
    /// skipped, or the check is not a GitHub Actions job.
    case logsUnavailable
    /// A `gh` command Hermes ran exited with an error. `message` is what it printed.
    case commandFailed(message: String)
}

/// One entry of a GraphQL response's `errors` array.
public struct GraphQLError: Sendable, Equatable, Decodable {
    /// Human-readable description.
    public let message: String
    /// GitHub's error code, such as `NOT_FOUND` or `FORBIDDEN`. Not every
    /// error has one.
    public let type: String?

    /// Creates an error value.
    public init(message: String, type: String?) {
        self.message = message
        self.type = type
    }
}

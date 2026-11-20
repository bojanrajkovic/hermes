import Foundation

/// A sentence for an error a list or a pane failed with.
public func describe(_ error: any Error) -> String {
    switch error {
    case GitHubError.rateLimited(let resetAt):
        "GitHub's rate limit is used up until \(resetAt.formatted(date: .omitted, time: .shortened))."
    case GitHubError.http(let status, let message):
        message.isEmpty ? "GitHub answered with HTTP \(status)." : message
    case GitHubError.graphQL(let errors):
        errors.first?.message ?? "GitHub could not answer the query."
    case GitHubError.decoding(let description):
        "GitHub's answer had an unexpected shape: \(description)"
    case GitHubError.commandFailed(let message):
        message
    case GitHubError.ghNotInstalled:
        "The GitHub CLI (gh) is not installed."
    case GitHubError.ghNotLoggedIn:
        "The GitHub CLI (gh) is not logged in."
    default:
        error.localizedDescription
    }
}

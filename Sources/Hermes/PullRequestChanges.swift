import GitHubKit

/// Folds a refresh's changes into an account's open pull request list.
enum PullRequestChanges {
    /// The list after a refresh: changed pull requests replace their copy or
    /// join the list, closed ones leave, and the list is newest first.
    ///
    /// - Parameters:
    ///   - list: The open pull requests held now.
    ///   - changed: Open pull requests loaded by this refresh.
    ///   - closed: Node IDs of pull requests that closed or merged.
    static func apply(to list: [PullRequest], changed: [PullRequest], closed: Set<String>) -> [PullRequest] {
        var byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for pullRequest in changed { byID[pullRequest.id] = pullRequest }
        for id in closed { byID[id] = nil }
        return byID.values.sorted { ($0.createdAt, $0.number) > ($1.createdAt, $1.number) }
    }
}

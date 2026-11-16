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

    /// Every pull request held, one copy each, as its row shows it: the open list, then the
    /// ones loaded by number that are not in it. A pull request opened by number can join the
    /// open list later, and its copy loaded by number then keeps an old head commit.
    static func held(listed: [PullRequest], fetched: [ItemKey: PullRequest]) -> [PullRequest] {
        let keys = Set(listed.map(\.key))
        return listed + fetched.values.filter { !keys.contains($0.key) }
    }

    /// The most a refresh loads again by ID: 4 requests, so about 4 points and 5 seconds.
    static let watchLimit = 100

    /// The node IDs of the watched pull requests that are in `list`, in the order of `keys`,
    /// without repeats, up to `limit`. The rest wait for the search to report a change.
    static func watched(_ keys: [ItemKey], among list: [PullRequest], limit: Int = watchLimit) -> [String] {
        let ids = Dictionary(list.map { ($0.key, $0.id) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return Array(keys.compactMap { ids[$0] }.filter { seen.insert($0).inserted }.prefix(limit))
    }
}

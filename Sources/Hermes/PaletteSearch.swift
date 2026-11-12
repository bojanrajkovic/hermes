import Foundation
import GitHubKit

/// What the text in the command palette asks for.
enum PaletteQuery: Equatable {
    case empty
    /// `repo#123`, `owner/repo#123`, or `#123` (no repository named).
    case reference(repository: String?, number: Int)
    /// A pasted github.com or hermes:// link.
    case link(DeepLink)
    case text(String)

    init(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            self = .empty
        } else if trimmed.contains("://"), let url = URL(string: trimmed), let link = DeepLink(url: url) {
            self = .link(link)
        } else if let match = trimmed.wholeMatch(of: /([\w.\-]+(?:\/[\w.\-]+)?)?\s*#(\d+)/), let number = Int(match.2) {
            self = .reference(repository: match.1.map(String.init), number: number)
        } else {
            self = .text(trimmed)
        }
    }
}

/// Scores how well `query` matches `candidate`, ignoring case. Every word of
/// the query must appear in the candidate as a subsequence.
///
/// Matches at the start of a word and runs of consecutive letters score
/// higher, and a shorter candidate wins a tie, so "air" ranks "airway" above
/// "repair-scripts".
///
/// - Returns: Nil when the query does not match. Higher is better.
func fuzzyScore(_ query: String, in candidate: String) -> Int? {
    let text = Array(candidate.lowercased())
    var total = 0
    for word in query.lowercased().split(separator: " ") {
        guard let score = bestSubsequenceScore(Array(word), in: text) else { return nil }
        total += score
    }
    return total * 100 - text.count
}

/// The best score over every position the word's first letter matches at,
/// taking the earliest match for each later letter.
private func bestSubsequenceScore(_ word: [Character], in text: [Character]) -> Int? {
    var best: Int?
    for start in text.indices where text[start] == word[0] {
        var score = 0
        var next = 0
        var previous = -2
        for index in start..<text.count where next < word.count && text[index] == word[next] {
            score += 1
            if index == previous + 1 { score += 5 }
            if index == 0 || !(text[index - 1].isLetter || text[index - 1].isNumber) { score += 8 }
            previous = index
            next += 1
        }
        if next == word.count { best = max(best ?? 0, score) }
    }
    return best
}

/// What choosing a palette row does.
enum PaletteAction: Hashable {
    case show(Destination)
    case repository(RepositoryRef)
    /// Load a pull request or issue that is not in the lists.
    case open(ItemKey)
    /// Go where a pasted link points.
    case link(DeepLink)
    case account(login: String)
    case refresh
    case toggleBots
    case settings
}

struct PaletteItem: Identifiable, Hashable {
    let title: String
    let subtitle: String
    let symbol: String
    let action: PaletteAction

    var id: PaletteAction { action }
}

/// Everything the palette searches.
struct PaletteContext {
    struct Session {
        let id: UUID
        let title: String
        let subtitle: String
    }

    var repositories: [RepositoryRef] = []
    var pullRequests: [PullRequest] = []
    var issues: [(repository: RepositoryRef, issue: Issue)] = []
    var sessions: [Session] = []
    var accounts: [Account] = []
    var currentAccount: String?
    /// The repository `#123` refers to.
    var currentRepository: RepositoryRef?
    var showingAllBots = false
}

/// The palette's rows for the typed text, best first.
func paletteItems(for input: String, in context: PaletteContext, limit: Int = 40) -> [PaletteItem] {
    switch PaletteQuery(input) {
    case .empty:
        return Array((commands(in: context) + context.repositories.map(repositoryItem)).prefix(limit))

    case .link(let link):
        return [PaletteItem(title: "Open \(link.title)", subtitle: "Go to the linked page", symbol: "link", action: .link(link))]

    case .reference(let name, let number):
        return referencedRepositories(name, in: context).map { repository in
            let key = ItemKey(repository: repository, number: number)
            if let pullRequest = context.pullRequests.first(where: { $0.key == key }) {
                return pullRequestItem(pullRequest)
            }
            if let issue = context.issues.first(where: { $0.repository == repository && $0.issue.number == number }) {
                return issueItem(issue.issue, in: repository)
            }
            return PaletteItem(
                title: "Open \(key)", subtitle: "Load the pull request or issue from GitHub",
                symbol: "arrow.down.circle", action: .open(key)
            )
        }

    case .text(let query):
        var scored: [(score: Int, item: PaletteItem)] = []
        func add(_ item: PaletteItem, matching text: String, bonus: Int = 0) {
            if let score = fuzzyScore(query, in: text) { scored.append((score + bonus, item)) }
        }
        // A repository or command outranks a title that matches equally well.
        for repository in context.repositories { add(repositoryItem(repository), matching: repository.name, bonus: 300) }
        for command in commands(in: context) { add(command, matching: command.title, bonus: 200) }
        for session in context.sessions { add(sessionItem(session), matching: session.title, bonus: 100) }
        for pullRequest in context.pullRequests { add(pullRequestItem(pullRequest), matching: pullRequest.title) }
        for entry in context.issues { add(issueItem(entry.issue, in: entry.repository), matching: entry.issue.title) }
        // The sort is stable, so equal scores keep the order above.
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.item)
    }
}

/// The repositories a reference's name can mean, best match first.
private func referencedRepositories(_ name: String?, in context: PaletteContext) -> [RepositoryRef] {
    guard let name else { return context.currentRepository.map { [$0] } ?? [] }

    let parts = name.split(separator: "/")
    if parts.count == 2 { return [RepositoryRef(owner: String(parts[0]), name: String(parts[1]))] }
    return context.repositories
        .compactMap { repository in fuzzyScore(name, in: repository.name).map { (score: $0, repository: repository) } }
        .sorted { $0.score > $1.score }
        .prefix(5)
        .map(\.repository)
}

private func commands(in context: PaletteContext) -> [PaletteItem] {
    var items = [
        PaletteItem(title: "Refresh", subtitle: "Reload pull requests and issues", symbol: "arrow.clockwise", action: .refresh),
        PaletteItem(
            title: context.showingAllBots ? "Hide Quiet Bot Pull Requests" : "Show All Bot Pull Requests",
            subtitle: "Bot pull requests that need attention always show", symbol: "gearshape.2", action: .toggleBots
        ),
    ]
    items += context.accounts.filter { $0.login != context.currentAccount }.map {
        PaletteItem(
            title: "Switch to \($0.name ?? $0.login)", subtitle: "Account \($0.login)",
            symbol: $0.kind == .personal ? "person.crop.circle" : "building.2.crop.circle", action: .account(login: $0.login)
        )
    }
    items.append(PaletteItem(title: "Settings…", subtitle: "Refresh interval, bots, sessions", symbol: "gearshape", action: .settings))
    return items
}

private func repositoryItem(_ repository: RepositoryRef) -> PaletteItem {
    PaletteItem(title: repository.name, subtitle: "Repository · \(repository.owner)", symbol: "book.closed", action: .repository(repository))
}

private func pullRequestItem(_ pullRequest: PullRequest) -> PaletteItem {
    PaletteItem(
        title: pullRequest.title, subtitle: "Pull request · \(pullRequest.key)", symbol: "arrow.triangle.pull",
        action: .show(.pullRequest(pullRequest.key))
    )
}

private func issueItem(_ issue: Issue, in repository: RepositoryRef) -> PaletteItem {
    let key = ItemKey(repository: repository, number: issue.number)
    return PaletteItem(title: issue.title, subtitle: "Issue · \(key)", symbol: "smallcircle.filled.circle", action: .show(.issue(key)))
}

private func sessionItem(_ session: PaletteContext.Session) -> PaletteItem {
    PaletteItem(title: session.title, subtitle: "Session · \(session.subtitle)", symbol: "terminal", action: .show(.session(session.id)))
}

import Foundation
import GitHubKit
@testable import Hermes

let airway = RepositoryRef(owner: "bojan", name: "airway")
let repairScripts = RepositoryRef(owner: "bojan", name: "repair-scripts")

func user(_ login: String, bot: Bool = false) -> User {
    User(login: login, avatarURL: URL(string: "https://example.com/\(login).png")!, isBot: bot)
}

func pullRequest(
    _ number: Int, in repository: RepositoryRef = airway, title: String = "A pull request", author: User? = user("bojan"),
    draft: Bool = false, checks: StatusState? = .success, stack: StackEntry? = nil, created: Date = .distantPast
) -> PullRequest {
    PullRequest(
        id: "PR_\(repository.name)_\(number)", number: number, title: title,
        url: URL(string: "https://github.com/\(repository)/pull/\(number)")!, repository: repository, author: author,
        isDraft: draft, createdAt: created, updatedAt: .distantPast, headRefName: "branch-\(number)",
        baseRefName: "main", headOID: "abc", reviewDecision: nil, additions: 1, deletions: 1, changedFileCount: 1,
        mergeable: .mergeable, labels: [], checkState: checks, stack: stack, closingIssueNumbers: []
    )
}

func issue(_ number: Int, title: String) -> Issue {
    Issue(
        id: "I_\(number)", number: number, title: title, url: URL(string: "https://github.com/bojan/airway/issues/\(number)")!,
        state: .open, author: user("bojan"), labels: [], commentCount: 0, createdAt: .distantPast, updatedAt: .distantPast,
        assignees: [], linkedPullRequests: []
    )
}

func repository(_ ref: RepositoryRef, issues: Int = 0) -> Repository {
    Repository(
        ref: ref, url: URL(string: "https://github.com/\(ref)")!, isPrivate: false, openIssueCount: issues,
        openPullRequestCount: 0
    )
}

import Foundation
import GitHubKit

public let airway = RepositoryRef(owner: "bojan", name: "airway")
public let repairScripts = RepositoryRef(owner: "bojan", name: "repair-scripts")

public func user(_ login: String, bot: Bool = false) -> User {
    User(login: login, avatarURL: URL(string: "https://example.com/\(login).png")!, isBot: bot)
}

public func pullRequest(
    _ number: Int, in repository: RepositoryRef = airway, title: String = "A pull request", author: User? = user("bojan"),
    draft: Bool = false, checks: ChecksRollup? = .passed, stack: StackEntry? = nil, created: Date = .distantPast,
    review: ReviewDecision? = nil, mergeable: MergeableState = .mergeable, head: String = "abc", base: String = "main",
    requested: [Reviewer] = [], reviewed: String? = nil
) -> PullRequest {
    PullRequest(
        id: "PR_\(repository.name)_\(number)", number: number, title: title,
        url: URL(string: "https://github.com/\(repository)/pull/\(number)")!, repository: repository, author: author,
        isDraft: draft, createdAt: created, updatedAt: .distantPast, headRefName: "branch-\(number)",
        baseRefName: base, headOID: head, reviewDecision: review, additions: 1, deletions: 1, changedFileCount: 1,
        mergeable: mergeable, labels: [], checkState: checks, stack: stack, closingIssueNumbers: [],
        requestedReviewers: requested, viewerReviewedCommit: reviewed
    )
}

public func issue(_ number: Int, title: String) -> Issue {
    Issue(
        id: "I_\(number)", number: number, title: title, url: URL(string: "https://github.com/bojan/airway/issues/\(number)")!,
        state: .open, author: user("bojan"), labels: [], commentCount: 0, createdAt: .distantPast, updatedAt: .distantPast,
        assignees: [], linkedPullRequests: []
    )
}

public func repository(_ ref: RepositoryRef, issues: Int = 0) -> Repository {
    Repository(
        ref: ref, url: URL(string: "https://github.com/\(ref)")!, isPrivate: false, openIssueCount: issues
    )
}

// MARK: GraphQL answers

/// The `data` of an answer to `GitHubClient.item(_:)`.
public func item(_ fields: String) -> String {
    #"{"repository":{"issueOrPullRequest":\#(fields)}}"#
}

public func pullRequestJSON(_ number: Int, state: String = "OPEN", head: String = "aaa") -> String {
    """
    {"__typename":"PullRequest","id":"PR_\(number)","number":\(number),"title":"A pull request",
     "url":"https://github.com/bojan/airway/pull/\(number)","state":"\(state)","isDraft":false,
     "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","headRefName":"branch","baseRefName":"main",
     "headRefOid":"\(head)","additions":1,"deletions":1,"changedFiles":1,"mergeable":"MERGEABLE",
     "repository":{"name":"airway","owner":{"login":"bojan"}},"labels":{"nodes":[]},"commits":{"nodes":[]},
     "closingIssuesReferences":{"nodes":[]}}
    """
}

public func issueJSON(_ number: Int, state: String = "OPEN") -> String {
    """
    {"__typename":"Issue","id":"I_\(number)","number":\(number),"title":"An issue",
     "url":"https://github.com/bojan/airway/issues/\(number)","state":"\(state)",
     "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","labels":{"nodes":[]},
     "comments":{"totalCount":0},"assignees":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[]}}
    """
}

/// A page of airway's issues. `total` is the open issue count across all pages, the page's size by default.
public func issuesPage(_ numbers: [Int], total: Int? = nil) -> String {
    let nodes = numbers.map { issueJSON($0) }.joined(separator: ",")
    return """
        {"repository":{"name":"airway","owner":{"login":"bojan"},"url":"https://github.com/bojan/airway","isPrivate":false,
         "issues":{"totalCount":\(total ?? numbers.count),"pageInfo":{"hasNextPage":false,"endCursor":"c"},"nodes":[\(nodes)]}}}
        """
}

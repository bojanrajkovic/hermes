import Foundation

private let userFields = "__typename login avatarUrl"
private let commentFields = "id databaseId author { \(userFields) } body createdAt"

// MARK: Profile

extension GitHubClient {
    /// Loads the signed-in user's profile and organizations.
    ///
    /// The profile comes from REST because GraphQL's `email` field needs a
    /// token scope that `gh` does not request.
    public func viewer() async throws -> ViewerProfile {
        let user = try await get("/user", as: RESTUser.self)
        let organizations = try await graphQL(
            "{ viewer { organizations(first: 100) { nodes { login name avatarUrl } } } }",
            as: OrganizationsData.self
        )
        return ViewerProfile(user: user, organizations: organizations)
    }
}

// MARK: Pull requests

extension GitHubClient {
    // GitHub spends about 100 ms on each pull request's fields, and the pages
    // of a search load one after another. So the search asks for IDs only, and
    // the fields load by ID in small requests that run at the same time.
    private static let pullRequestIDsQuery = """
        query($q: String!, $after: String) {
          search(query: $q, type: ISSUE, first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on PullRequest { id repository { viewerPermission } } }
          }
        }
        """

    private static let pullRequestsQuery = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on PullRequest {
              id number title url isDraft createdAt updatedAt headRefName baseRefName headRefOid
              reviewDecision additions deletions changedFiles mergeable
              repository { name owner { login } }
              author { \(userFields) }
              labels(first: 20) { nodes { name color } }
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              stack { id number size baseRefName }
              stackEntry { position }
              closingIssuesReferences(first: 20) { nodes { number } }
            }
          }
        }
        """

    /// Loads every open pull request in the non-archived repositories of a
    /// user or an organization, most recently created first.
    ///
    /// GitHub's search returns at most 1,000 results, so an account with more
    /// open pull requests gets the first 1,000. No pull request appears twice.
    ///
    /// - Parameter owner: The login of the user or organization.
    public func openPullRequests(owner: String) async throws -> [PullRequest] {
        try await pullRequests(ids: pullRequestIDs(matching: PullRequestSearch.open(owner: owner)))
    }

    /// The node IDs of the pull requests a search finds, in its order, without
    /// repeats. Stops at GitHub's limit of 1,000 results.
    ///
    /// - Parameter query: A search query, usually from `PullRequestSearch`.
    public func pullRequestIDs(matching query: String) async throws -> [String] {
        try await pullRequestHits(matching: query).map(\.id)
    }

    /// The pull requests a search finds, in its order, without repeats, each
    /// with whether the viewer can push to its repository. Stops at GitHub's
    /// limit of 1,000 results.
    ///
    /// - Parameter query: A search query, usually from `PullRequestSearch`.
    public func pullRequestHits(matching query: String) async throws -> [PullRequestHit] {
        var hits: [PullRequestHit] = []
        var seen: Set<String> = []
        var cursor: String?
        repeat {
            let variables: [String: JSONValue] = ["q": .string(query), "after": JSONValue(cursor)]
            let page = try await retryingReads {
                try await self.graphQL(Self.pullRequestIDsQuery, variables: variables, as: SearchData<PullRequestHit>.self).search
            }
            // A pull request opened while the pages load shifts the results by
            // one, so the next page repeats the last entry of this one.
            hits += page.nodes.filter { seen.insert($0.id).inserted }
            cursor = page.nextCursor
        } while cursor != nil
        return hits
    }

    /// The commit each pull request's latest review by `viewer` was on, by pull request node ID.
    /// A pull request with no review by the viewer is left out. 50 to a request, one at a time.
    public func latestReviewCommits(pullRequestIDs ids: [String], viewer: String) async throws -> [String: String] {
        struct Data: Decodable, Sendable {
            struct Node: Decodable, Sendable {
                struct Review: Decodable, Sendable {
                    struct Commit: Decodable, Sendable { let oid: String }
                    let commit: Commit?
                }
                let id: String?
                let reviews: Connection<Review>?
            }
            let nodes: [Node?]
        }
        let query = """
            query($ids: [ID!]!, $viewer: String!) {
              nodes(ids: $ids) { ... on PullRequest { id reviews(last: 1, author: $viewer) { nodes { commit { oid } } } } }
            }
            """
        var commits: [String: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = ids[start..<min(start + 50, ids.count)].map(JSONValue.string)
            let nodes = try await retryingReads {
                try await self.graphQL(query, variables: ["ids": .array(chunk), "viewer": .string(viewer)], as: Data.self).nodes
            }
            for case let node? in nodes {
                if let id = node.id, let oid = node.reviews?.nodes.last?.commit?.oid { commits[id] = oid }
            }
        }
        return commits
    }

    /// Loads pull requests by node ID, in the order of `ids`. An ID that no
    /// longer names a pull request is left out.
    public func pullRequests(ids: [String]) async throws -> [PullRequest] {
        // 10 to a request keeps each under 2 seconds. At most 2 run at once: more
        // in a large organization trips GitHub's secondary rate limit on bursts.
        let chunks = stride(from: 0, to: ids.count, by: 10).map { Array(ids[$0..<min($0 + 10, ids.count)]) }
        var byID: [String: PullRequest] = [:]
        try await withThrowingTaskGroup(of: [PullRequest].self) { group in
            for (index, chunk) in chunks.enumerated() {
                if index >= 2, let loaded = try await group.next() {
                    for pullRequest in loaded { byID[pullRequest.id] = pullRequest }
                }
                group.addTask {
                    try await self.retryingReads {
                        try await self.graphQL(
                            Self.pullRequestsQuery, variables: ["ids": .array(chunk.map(JSONValue.string))], as: NodesData.self
                        ).nodes
                    }
                }
            }
            for try await loaded in group {
                for pullRequest in loaded { byID[pullRequest.id] = pullRequest }
            }
        }
        return ids.compactMap { byID[$0] }
    }

    /// Runs a read again, up to two more times, when GitHub answers HTTP 502
    /// or 504, which is how a GraphQL query that ran too long fails, or asks
    /// Hermes to back off for at most a minute, which is how a burst trips the
    /// secondary rate limit. Not for mutations: one may have been applied
    /// before the gateway gave up.
    private func retryingReads<T: Sendable>(_ read: () async throws -> T) async throws -> T {
        for _ in 1...2 {
            do {
                return try await read()
            } catch GitHubError.http(status: 502, _), GitHubError.http(status: 504, _) {
                continue
            } catch GitHubError.rateLimited(let resetAt) where resetAt.timeIntervalSinceNow <= 60 {
                try await Task.sleep(for: .seconds(max(1, resetAt.timeIntervalSinceNow)))
            }
        }
        return try await read()
    }

    /// Loads a pull request's description, conversation, reviews, requested
    /// reviewers, commits, and review threads.
    ///
    /// Comments, reviews, and review threads are complete. The other lists
    /// hold at most their first entries: 50 requested reviewers, 250 commits,
    /// and 100 comments in one thread.
    ///
    /// - Throws: `GitHubError.graphQL` with type `NOT_FOUND` when the
    ///   repository or pull request does not exist or is not visible.
    public func pullRequestDetail(repository: RepositoryRef, number: Int) async throws -> PullRequestDetail {
        let reviewFields = "id author { \(userFields) } state body submittedAt"
        // shortcut: the first 100 comments of a thread; page them when a real
        // thread has more.
        let threadFields = """
            id path line startLine diffSide startDiffSide isResolved isOutdated
            comments(first: 100) { nodes { \(commentFields) } }
            """
        let query = """
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  id body
                  comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { \(commentFields) } }
                  reviews(first: 100) { pageInfo { hasNextPage endCursor } nodes { \(reviewFields) } }
                  reviewRequests(first: 50) {
                    nodes { requestedReviewer { __typename ... on Actor { login avatarUrl } ... on Team { name slug } } }
                  }
                  commits(first: 250) { nodes { commit { oid messageHeadline } } }
                  reviewThreads(first: 100) { pageInfo { hasNextPage endCursor } nodes { \(threadFields) } }
                }
              }
            }
            """
        let first: PullRequestDetailPage = try await pullRequestField(query, repository: repository, number: number)

        // Most pull requests fit in the first page, and then these make no request.
        func rest<Node: Decodable & Sendable>(of list: String, _ fields: String, after cursor: String?) async throws -> [Node] {
            try await remainingPages(of: list, fields: fields, after: cursor, repository: repository, number: number)
        }
        return PullRequestDetail(
            id: first.detail.id,
            body: first.detail.body,
            comments: first.detail.comments + (try await rest(of: "comments", commentFields, after: first.commentsCursor)),
            reviews: first.detail.reviews + (try await rest(of: "reviews", reviewFields, after: first.reviewsCursor)),
            requestedReviewers: first.detail.requestedReviewers,
            commits: first.detail.commits,
            reviewThreads: first.detail.reviewThreads
                + (try await rest(of: "reviewThreads", threadFields, after: first.reviewThreadsCursor))
        )
    }

    /// Loads the pages of one of a pull request's lists that follow `cursor`.
    ///
    /// - Parameters:
    ///   - list: The name of the connection on `PullRequest`, such as `comments`.
    ///   - fields: The GraphQL selection for each entry.
    ///   - cursor: Where the next page starts. Nil when the list is complete.
    private func remainingPages<Node: Decodable & Sendable>(
        of list: String, fields: String, after cursor: String?, repository: RepositoryRef, number: Int
    ) async throws -> [Node] {
        let query = """
            query($owner: String!, $name: String!, $number: Int!, $after: String) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  page: \(list)(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { \(fields) } }
                }
              }
            }
            """

        var nodes: [Node] = []
        var cursor = cursor
        while let after = cursor {
            let page = try await graphQL(
                query,
                variables: [
                    "owner": .string(repository.owner), "name": .string(repository.name),
                    "number": .int(number), "after": .string(after),
                ],
                as: RepositoryData<PullRequestField<PageField<Node>>>.self
            ).repository.pullRequest.page
            nodes += page.nodes
            cursor = page.nextCursor
        }
        return nodes
    }

    /// Loads a pull request's head commit and last update time. This is the
    /// cheap call for polling whether an open pull request changed.
    ///
    /// - Throws: `GitHubError.graphQL` with type `NOT_FOUND` when the
    ///   repository or pull request does not exist or is not visible.
    public func pullRequestRevision(repository: RepositoryRef, number: Int) async throws -> PullRequestRevision {
        let query = """
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) { pullRequest(number: $number) { headRefOid updatedAt } }
            }
            """
        return try await pullRequestField(query, repository: repository, number: number)
    }

    private func pullRequestField<T: Decodable & Sendable>(
        _ query: String, repository: RepositoryRef, number: Int
    ) async throws -> T {
        try await graphQL(
            query,
            variables: ["owner": .string(repository.owner), "name": .string(repository.name), "number": .int(number)],
            as: RepositoryData<PullRequestField<T>>.self
        ).repository.pullRequest
    }

    /// Loads a pull request's changes as unified diff text.
    ///
    /// - Throws: `GitHubError.diffTooLarge` when GitHub refuses to render the
    ///   diff. Compute it from a local clone instead.
    public func pullRequestDiff(repository: RepositoryRef, number: Int) async throws -> String {
        do {
            let data = try await get(
                "/repos/\(repository.owner)/\(repository.name)/pulls/\(number)",
                accept: "application/vnd.github.diff"
            )
            return String(decoding: data, as: UTF8.self)
        } catch GitHubError.http(status: 406, _) {
            throw GitHubError.diffTooLarge
        }
    }
}

// MARK: Repositories and issues

extension GitHubClient {
    /// Loads the non-archived repositories a user or an organization owns that
    /// the viewer can push to, most recently pushed first, with open issue counts.
    ///
    /// The list pages through every repository with only its ID and the
    /// viewer's permission, which is cheap. Issue counts load only for the
    /// repositories kept, 100 to a request: counting for hundreds of read-only
    /// repositories in a large organization trips GitHub's secondary rate limit.
    ///
    /// - Parameter owner: The login of the user or organization.
    /// - Throws: `GitHubError.decoding` when no account has that login.
    public func repositories(owner: String) async throws -> [Repository] {
        let listQuery = """
            query($login: String!, $after: String) {
              repositoryOwner(login: $login) {
                repositories(
                  first: 100, after: $after, isArchived: false, ownerAffiliations: OWNER,
                  orderBy: { field: PUSHED_AT, direction: DESC }
                ) {
                  pageInfo { hasNextPage endCursor }
                  nodes { id viewerPermission }
                }
              }
            }
            """
        let countsQuery = """
            query($ids: [ID!]!) {
              nodes(ids: $ids) {
                ... on Repository { name owner { login } url isPrivate issues(states: OPEN) { totalCount } }
              }
            }
            """

        var ids: [String] = []
        var cursor: String?
        repeat {
            let variables: [String: JSONValue] = ["login": .string(owner), "after": JSONValue(cursor)]
            let page = try await retryingReads {
                try await self.graphQL(listQuery, variables: variables, as: OwnerData.self).repositoryOwner.repositories
            }
            ids += page.nodes.filter { $0.viewerPermission?.canPush == true }.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil

        var repositories: [Repository] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = ids[start..<min(start + 100, ids.count)].map(JSONValue.string)
            repositories += try await retryingReads {
                try await self.graphQL(countsQuery, variables: ["ids": .array(chunk)], as: RepositoryNodes.self).nodes
            }
        }
        return repositories
    }

    /// Loads one page of a repository's open issues, most recently updated first.
    ///
    /// - Parameters:
    ///   - pageSize: How many issues to load, from 1 to 100.
    ///   - after: `IssuePage.endCursor` of the previous page. Nil loads the first page.
    /// - Throws: `GitHubError.graphQL` with type `NOT_FOUND` when the
    ///   repository does not exist or is not visible.
    public func issues(repository: RepositoryRef, pageSize: Int, after: String? = nil) async throws -> IssuePage {
        let query = """
            query($owner: String!, $name: String!, $first: Int!, $after: String) {
              repository(owner: $owner, name: $name) {
                issues(first: $first, after: $after, states: OPEN, orderBy: { field: UPDATED_AT, direction: DESC }) {
                  totalCount
                  pageInfo { hasNextPage endCursor }
                  nodes {
                    id number title url state createdAt updatedAt
                    author { \(userFields) }
                    labels(first: 20) { nodes { name color } }
                    comments { totalCount }
                    assignees(first: 20) { nodes { \(userFields) } }
                    closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
                      nodes { number title state headRefName }
                    }
                  }
                }
              }
            }
            """

        let page = try await graphQL(
            query,
            variables: [
                "owner": .string(repository.owner), "name": .string(repository.name),
                "first": .int(pageSize), "after": JSONValue(after),
            ],
            as: RepositoryData<IssuesField>.self
        ).repository.issues
        return IssuePage(
            items: page.nodes,
            endCursor: page.pageInfo?.endCursor,
            hasNextPage: page.pageInfo?.hasNextPage ?? false,
            totalCount: page.totalCount ?? page.nodes.count
        )
    }

    /// Loads an issue's description and its first 100 comments.
    ///
    /// - Throws: `GitHubError.graphQL` with type `NOT_FOUND` when the
    ///   repository or issue does not exist or is not visible.
    public func issueDetail(repository: RepositoryRef, number: Int) async throws -> IssueDetail {
        let query = """
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                issue(number: $number) { body comments(first: 100) { nodes { \(commentFields) } } }
              }
            }
            """
        return try await graphQL(
            query,
            variables: ["owner": .string(repository.owner), "name": .string(repository.name), "number": .int(number)],
            as: RepositoryData<IssueField>.self
        ).repository.issue
    }
}

// MARK: Checks

extension GitHubClient {
    /// Loads every check on a commit: check runs and legacy commit statuses.
    ///
    /// - Parameter commitOID: The commit's full SHA.
    /// - Returns: The checks in GitHub's order. Empty when the commit has
    ///   none, or does not exist.
    /// - Throws: `GitHubError.graphQL` with type `NOT_FOUND` when the
    ///   repository does not exist or is not visible.
    public func checks(repository: RepositoryRef, commitOID: String) async throws -> [Check] {
        let query = """
            query($owner: String!, $name: String!, $oid: GitObjectID!, $after: String) {
              repository(owner: $owner, name: $name) {
                object(oid: $oid) {
                  ... on Commit {
                    statusCheckRollup {
                      contexts(first: 100, after: $after) {
                        pageInfo { hasNextPage endCursor }
                        nodes {
                          __typename
                          ... on CheckRun {
                            databaseId name status conclusion startedAt completedAt detailsUrl
                            checkSuite { app { name } workflowRun { databaseId workflow { name } } }
                          }
                          ... on StatusContext { context state targetUrl description }
                        }
                      }
                    }
                  }
                }
              }
            }
            """

        var checks: [Check] = []
        var cursor: String?
        repeat {
            let page = try await graphQL(
                query,
                variables: [
                    "owner": .string(repository.owner), "name": .string(repository.name),
                    "oid": .string(commitOID), "after": JSONValue(cursor),
                ],
                as: RepositoryData<ChecksField>.self
            ).repository.object?.statusCheckRollup?.contexts
            checks += page?.nodes ?? []
            cursor = page?.nextCursor
        } while cursor != nil
        return checks
    }

    /// The pull request numbers of a stack, from its bottom up.
    ///
    /// - Parameter number: The stack's number in the repository, as in `github.com/<owner>/<repo>/stack/<number>`.
    /// - Throws: `GitHubError.http` with status 404 when the repository has no such stack.
    public func stackPullRequests(repository: RepositoryRef, number: Int) async throws -> [Int] {
        struct Stack: Decodable, Sendable {
            struct Member: Decodable, Sendable { let number: Int }
            let pull_requests: [Member]
        }
        return try await get("/repos/\(repository.owner)/\(repository.name)/stacks/\(number)", as: Stack.self).pull_requests.map(\.number)
    }

    /// Runs one GitHub Actions job again, with the jobs that depend on it.
    ///
    /// - Parameter jobID: `CheckRun.databaseID` of a run whose `workflow` is not nil.
    /// - Throws: `GitHubError.http` with GitHub's reason, for example when the
    ///   viewer may not run workflows in the repository or the run is too old.
    public func rerunJob(repository: RepositoryRef, jobID: Int) async throws {
        try await post("/repos/\(repository.owner)/\(repository.name)/actions/jobs/\(jobID)/rerun")
    }

    /// Runs the failed and cancelled jobs of a workflow run again, with the jobs that depend on them.
    ///
    /// - Parameter runID: `CheckRun.Workflow.runID`.
    /// - Throws: As `rerunJob(repository:jobID:)`.
    public func rerunFailedJobs(repository: RepositoryRef, runID: Int) async throws {
        try await post("/repos/\(repository.owner)/\(repository.name)/actions/runs/\(runID)/rerun-failed-jobs")
    }

    /// Downloads the log of a GitHub Actions job as text.
    ///
    /// - Parameter jobID: `CheckRun.databaseID` of a run whose `workflow` is not nil.
    /// - Throws: `GitHubError.logsUnavailable` when the job has no log: it has
    ///   not started, was skipped, the log expired, or the ID is not an
    ///   Actions job.
    public func jobLogs(repository: RepositoryRef, jobID: Int) async throws -> String {
        do {
            let data = try await get("/repos/\(repository.owner)/\(repository.name)/actions/jobs/\(jobID)/logs")
            // The log starts with a byte order mark.
            return String(String(decoding: data, as: UTF8.self).trimmingPrefix("\u{FEFF}"))
        } catch GitHubError.http(status: 404, _), GitHubError.http(status: 410, _) {
            throw GitHubError.logsUnavailable
        }
    }
}

// MARK: Response shapes

struct RESTUser: Decodable, Sendable {
    let login: String
    let name: String?
    let avatar_url: URL
    let bio: String?
    let company: String?
    let location: String?
    let email: String?
    let html_url: URL
}

struct OrganizationsData: Decodable, Sendable {
    struct Viewer: Decodable, Sendable { let organizations: Connection<Organization> }
    struct Organization: Decodable, Sendable {
        let login: String
        let name: String?
        let avatarUrl: URL
    }
    let viewer: Viewer
}

extension ViewerProfile {
    init(user: RESTUser, organizations: OrganizationsData) {
        self.init(
            login: user.login, name: user.name, avatarURL: user.avatar_url, bio: user.bio,
            company: user.company, location: user.location, email: user.email, profileURL: user.html_url,
            organizations: organizations.viewer.organizations.nodes.map {
                Account(kind: .organization, login: $0.login, name: $0.name, avatarURL: $0.avatarUrl)
            }
        )
    }
}

struct SearchData<Node: Decodable & Sendable>: Decodable, Sendable {
    let search: Connection<Node>
}

struct NodeID: Decodable, Sendable {
    let id: String
}

/// A pull request a search found.
public struct PullRequestHit: Sendable, Hashable {
    public let id: String
    /// Whether the viewer can push to the pull request's repository.
    public let canPush: Bool

    public init(id: String, canPush: Bool) {
        self.id = id
        self.canPush = canPush
    }
}

extension PullRequestHit: Decodable {
    private enum CodingKeys: String, CodingKey { case id, repository }
    private struct Repository: Decodable { let viewerPermission: RepositoryPermission? }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        canPush = try container.decodeIfPresent(Repository.self, forKey: .repository)?.viewerPermission?.canPush ?? false
    }
}

struct NodesData: Decodable, Sendable {
    let nodes: [PullRequest]
}

struct OwnerData: Decodable, Sendable {
    struct Listing: Decodable, Sendable {
        let id: String
        /// Nil when GitHub does not say, which Hermes treats as read only.
        let viewerPermission: RepositoryPermission?
    }
    struct Owner: Decodable, Sendable { let repositories: Connection<Listing> }
    let repositoryOwner: Owner
}

struct RepositoryNodes: Decodable, Sendable {
    let nodes: [Repository]
}

struct RepositoryData<Fields: Decodable & Sendable>: Decodable, Sendable {
    let repository: Fields
}

struct PullRequestField<Value: Decodable & Sendable>: Decodable, Sendable {
    let pullRequest: Value
}

struct PageField<Node: Decodable & Sendable>: Decodable, Sendable {
    let page: Connection<Node>
}

/// The first page of a pull request's detail, with where each list that can
/// have more pages continues. A cursor is nil when its list is complete.
struct PullRequestDetailPage: Decodable, Sendable {
    let detail: PullRequestDetail
    let commentsCursor: String?
    let reviewsCursor: String?
    let reviewThreadsCursor: String?

    private enum CodingKeys: String, CodingKey { case comments, reviews, reviewThreads }
    private struct Ignored: Decodable, Sendable { init(from decoder: any Decoder) {} }

    init(from decoder: any Decoder) throws {
        detail = try PullRequestDetail(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commentsCursor = try container.decode(Connection<Ignored>.self, forKey: .comments).nextCursor
        reviewsCursor = try container.decode(Connection<Ignored>.self, forKey: .reviews).nextCursor
        reviewThreadsCursor = try container.decode(Connection<Ignored>.self, forKey: .reviewThreads).nextCursor
    }
}

struct IssuesField: Decodable, Sendable {
    let issues: Connection<Issue>
}

struct IssueField: Decodable, Sendable {
    let issue: IssueDetail
}

struct ChecksField: Decodable, Sendable {
    struct Commit: Decodable, Sendable {
        struct Rollup: Decodable, Sendable { let contexts: Connection<Check> }
        let statusCheckRollup: Rollup?
    }
    let object: Commit?
}

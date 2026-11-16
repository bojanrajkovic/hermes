import Foundation

/// What a webhook delivery's payload says changed, in a form Hermes can apply to what it
/// holds without asking GitHub.
///
/// A delivery whose payload Hermes can't read this way has no change, and Hermes loads
/// what the delivery names instead.
public enum WebhookChange: Sendable, Hashable {
    /// A pull request's own fields.
    ///
    /// - Parameter reloads: Whether the event also changed something the payload does not
    ///   carry, such as the mergeability and checks of a new head commit.
    case pullRequest(PullRequestFields, reloads: Bool)
    /// A comment in a pull request's conversation was written, edited, or deleted.
    case comment(Comment, deleted: Bool)
    /// A review was submitted, edited, or dismissed.
    case review(Review)
    /// A line comment that answers the comment with this REST ID, so it joins that comment's thread.
    case reply(Comment, to: Int)
    /// A review thread was resolved, or opened again.
    case threadResolved(id: String, resolved: Bool)
    /// The review threads changed in a way the payload can't place: a new thread, whose ID
    /// the payload does not carry, or a line comment that was edited or deleted.
    case threads
    /// A commit status was set.
    case status(StatusContext)
    /// A check run was created or changed. The run has no workflow: the payload does not
    /// carry the workflow's name.
    ///
    /// - Parameter runID: The GitHub Actions workflow run the check is a job of, read from
    ///   its details URL. Nil for another app's check.
    case checkRun(CheckRun, runID: Int?)
    /// The checks changed in a way the payload does not say: a check suite finished.
    case checks

    /// Reads one delivery's JSON body. The kind of event is told from the body's keys,
    /// because a forwarder's deliveries carry no event name.
    init?(payload: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let keys = try? decoder.decode(Keys.self, from: payload) else { return nil }

        if keys.check_run != nil {
            guard let run = (try? decoder.decode(CheckRunEvent.self, from: payload))?.check_run,
                  let status = CheckRun.Status(rawValue: run.status.uppercased()) else { return nil }
            let detailsURL = run.details_url.flatMap(URL.init(string:))
            self = .checkRun(
                CheckRun(
                    databaseID: run.id, name: run.name, status: status,
                    conclusion: run.conclusion.flatMap { CheckRun.Conclusion(rawValue: $0.uppercased()) },
                    startedAt: run.started_at, completedAt: run.completed_at, detailsURL: detailsURL,
                    appName: run.app?.name, workflow: nil
                ),
                runID: Self.workflowRunID(in: detailsURL)
            )
            return
        }
        if keys.check_suite != nil {
            self = .checks
            return
        }
        if keys.context != nil, keys.sha != nil {
            guard let event = try? decoder.decode(StatusEvent.self, from: payload),
                  let state = StatusState(rawValue: event.state.uppercased()) else { return nil }
            self = .status(StatusContext(
                context: event.context, state: state, targetURL: event.target_url.flatMap(URL.init(string:)),
                description: event.description
            ))
            return
        }

        switch (keys.pull_request != nil, keys.issue != nil, keys.comment != nil, keys.review != nil, keys.thread != nil) {
        case (true, false, false, false, false):
            guard let event = try? decoder.decode(PullRequestEvent.self, from: payload) else { return nil }
            self = .pullRequest(
                PullRequestFields(event.pull_request),
                reloads: Self.reloads(action: event.action, changesBase: event.changes?.base != nil)
            )
        case (false, true, true, false, false):
            guard let event = try? decoder.decode(IssueCommentEvent.self, from: payload) else { return nil }
            self = .comment(Comment(event.comment), deleted: event.action == "deleted")
        case (true, false, false, true, false):
            guard let event = try? decoder.decode(ReviewEvent.self, from: payload),
                  let state = Review.State(rawValue: event.review.state.uppercased()) else { return nil }
            self = .review(Review(
                id: event.review.node_id, author: event.review.user?.user, state: state,
                body: event.review.body ?? "", submittedAt: event.review.submitted_at
            ))
        case (true, false, true, false, false):
            guard let event = try? decoder.decode(ReviewCommentEvent.self, from: payload) else { return nil }
            if event.action == "created", let parent = event.comment.in_reply_to_id {
                self = .reply(Comment(event.comment), to: parent)
            } else {
                self = .threads
            }
        case (true, false, false, false, true):
            guard let event = try? decoder.decode(ThreadEvent.self, from: payload) else { return nil }
            switch event.action {
            case "resolved": self = .threadResolved(id: event.thread.node_id, resolved: true)
            case "unresolved": self = .threadResolved(id: event.thread.node_id, resolved: false)
            default: self = .threads
            }
        default:
            return nil
        }
    }

    /// The `pull_request` actions whose payload carries everything they changed.
    private static let completeActions: Set<String> = [
        "edited", "labeled", "unlabeled", "converted_to_draft", "ready_for_review", "closed",
        "review_requested", "review_request_removed", "auto_merge_enabled", "auto_merge_disabled",
    ]

    /// Whether a `pull_request` event changed something its payload does not carry.
    ///
    /// New commits and a new base branch change the mergeability, the checks, and the
    /// review decision. Reopening has GitHub work the mergeability out again. An action
    /// Hermes does not know, such as joining a stack, reloads too.
    static func reloads(action: String, changesBase: Bool) -> Bool {
        !completeActions.contains(action) || changesBase
    }

    /// The workflow run in the details URL of a GitHub Actions job:
    /// `https://github.com/<owner>/<name>/actions/runs/<run>/job/<job>`. Nil for any other URL.
    static func workflowRunID(in detailsURL: URL?) -> Int? {
        guard let parts = detailsURL?.pathComponents, let runs = parts.firstIndex(of: "runs"),
              runs > 0, parts[runs - 1] == "actions", parts.indices.contains(runs + 1) else { return nil }
        return Int(parts[runs + 1])
    }
}

/// The fields of a pull request that a `pull_request` webhook payload carries and a row or
/// the description shows.
public struct PullRequestFields: Sendable, Hashable {
    public let title: String
    /// Markdown. Empty when the pull request has no description.
    public let body: String
    public let state: LinkedPullRequest.State
    public let isDraft: Bool
    public let labels: [GitHubLabel]
    public let headOID: String
    public let headRefName: String
    public let baseRefName: String
    public let additions: Int
    public let deletions: Int
    public let changedFileCount: Int
    public let autoMergeMethod: MergeMethod?
    public let requestedReviewers: [RequestedReviewer]
    /// When GitHub last changed the pull request. It orders payloads that arrive out of
    /// order, and is not applied to the row.
    public let updatedAt: Date

    public init(
        title: String, body: String, state: LinkedPullRequest.State, isDraft: Bool, labels: [GitHubLabel],
        headOID: String, headRefName: String, baseRefName: String, additions: Int, deletions: Int,
        changedFileCount: Int, autoMergeMethod: MergeMethod?, requestedReviewers: [RequestedReviewer], updatedAt: Date
    ) {
        self.title = title
        self.body = body
        self.state = state
        self.isDraft = isDraft
        self.labels = labels
        self.headOID = headOID
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.additions = additions
        self.deletions = deletions
        self.changedFileCount = changedFileCount
        self.autoMergeMethod = autoMergeMethod
        self.requestedReviewers = requestedReviewers
        self.updatedAt = updatedAt
    }

    init(_ pullRequest: RESTPullRequest) {
        self.init(
            title: pullRequest.title, body: pullRequest.body ?? "",
            state: pullRequest.merged ? .merged : pullRequest.state == "closed" ? .closed : .open,
            isDraft: pullRequest.draft, labels: pullRequest.labels,
            headOID: pullRequest.head.sha, headRefName: pullRequest.head.ref, baseRefName: pullRequest.base.ref,
            additions: pullRequest.additions, deletions: pullRequest.deletions,
            changedFileCount: pullRequest.changed_files,
            autoMergeMethod: pullRequest.auto_merge.flatMap { MergeMethod(rawValue: $0.merge_method.uppercased()) },
            requestedReviewers: pullRequest.requested_reviewers.map { .user($0.user) }
                + pullRequest.requested_teams.map { .team(name: $0.name, slug: $0.slug) },
            updatedAt: pullRequest.updated_at
        )
    }
}

extension PullRequest {
    /// This pull request with the fields a webhook payload carries replaced. What the
    /// payload does not carry stays: the review decision, mergeability, checks, and stack.
    public func applying(_ fields: PullRequestFields) -> PullRequest {
        let requestedReviewers = fields.requestedReviewers.map { reviewer -> Reviewer in
            switch reviewer {
            case .user(let user): .user(login: user.login)
            // A requested team belongs to the organization that owns the repository.
            case .team(_, let slug): .team(organization: repository.owner, slug: slug)
            }
        }
        return PullRequest(
            id: id, number: number, title: fields.title, url: url, repository: repository, author: author,
            isDraft: fields.isDraft, createdAt: createdAt, updatedAt: updatedAt,
            headRefName: fields.headRefName, baseRefName: fields.baseRefName, headOID: fields.headOID,
            reviewDecision: reviewDecision, additions: fields.additions, deletions: fields.deletions,
            changedFileCount: fields.changedFileCount, mergeable: mergeable, labels: fields.labels,
            checkState: checkState, stack: stack, closingIssueNumbers: closingIssueNumbers,
            autoMergeMethod: fields.autoMergeMethod, requestedReviewers: requestedReviewers,
            viewerReviewedCommit: viewerReviewedCommit, state: fields.state
        )
    }
}

extension PullRequestDetail {
    /// This detail with a change applied. Nil for a change that is not about the
    /// description, the requested reviewers, the conversation, or the reviews.
    public func applying(_ change: WebhookChange) -> PullRequestDetail? {
        var (body, comments, reviews, requestedReviewers) = (body, comments, reviews, requestedReviewers)
        switch change {
        case .pullRequest(let fields, _):
            body = fields.body
            requestedReviewers = fields.requestedReviewers
        case .comment(let comment, let deleted):
            let index = comments.firstIndex { $0.id == comment.id }
            switch (index, deleted) {
            case (let index?, true): comments.remove(at: index)
            case (let index?, false): comments[index] = comment
            case (nil, true): break
            case (nil, false): comments.append(comment)
            }
        case .review(let review):
            if let index = reviews.firstIndex(where: { $0.id == review.id }) {
                reviews[index] = review
            } else {
                reviews.append(review)
            }
        case .reply, .threadResolved, .threads, .status, .checkRun, .checks:
            return nil
        }
        return PullRequestDetail(
            id: id, body: body, comments: comments, reviews: reviews, requestedReviewers: requestedReviewers,
            commits: commits, reviewThreads: reviewThreads
        )
    }
}

extension ReviewThread {
    /// The threads with a change applied. Nil when they have to load instead: the change is
    /// not one a payload can place, or it is about a thread that is not among `threads`.
    public static func applying(_ change: WebhookChange, to threads: [ReviewThread]) -> [ReviewThread]? {
        var threads = threads
        switch change {
        case .reply(let comment, let parent):
            guard let index = threads.firstIndex(where: { $0.comments.contains { $0.databaseID == parent } }) else { return nil }
            // Hermes loads the threads after sending a review, so its own reply can be there already.
            guard !threads[index].comments.contains(where: { $0.id == comment.id }) else { return threads }
            threads[index] = threads[index].with(comments: threads[index].comments + [comment])
        case .threadResolved(let id, let resolved):
            guard let index = threads.firstIndex(where: { $0.id == id }) else { return nil }
            threads[index] = threads[index].with(isResolved: resolved)
        case .pullRequest, .comment, .review, .threads, .status, .checkRun, .checks:
            return nil
        }
        return threads
    }

    private func with(isResolved: Bool? = nil, comments: [Comment]? = nil) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, startLine: startLine, diffSide: diffSide, startDiffSide: startDiffSide,
            isResolved: isResolved ?? self.isResolved, isOutdated: isOutdated, comments: comments ?? self.comments
        )
    }
}

extension Check {
    /// A commit's checks with a change applied. Nil when they have to load instead: the
    /// change is not about one check, or it is a job of a workflow run none of `checks`
    /// belongs to, so its workflow's name is not known.
    ///
    /// A check run for an earlier attempt of a job than the one in `checks` changes nothing.
    public static func applying(_ change: WebhookChange, to checks: [Check]) -> [Check]? {
        var checks = checks
        switch change {
        case .status(let status):
            if let index = checks.firstIndex(where: { $0.id == Check.status(status).id }) {
                checks[index] = .status(status)
            } else {
                checks.append(.status(status))
            }
        case .checkRun(let run, let runID):
            let runs = checks.compactMap { check in if case .run(let run) = check { run } else { nil } }
            // The run itself, or the attempt of the same job that a re-run replaces.
            let replaced = runs.first { $0.databaseID == run.databaseID }
                ?? runs.first { runID != nil && $0.workflow?.runID == runID && $0.name == run.name }
            // Each attempt of a job is a new check run with a higher ID. A delivery about an
            // earlier attempt can arrive after the newer attempt's.
            if let replaced, replaced.databaseID > run.databaseID { return checks }
            let workflow = replaced?.workflow ?? runs.first { runID != nil && $0.workflow?.runID == runID }?.workflow
            guard workflow != nil || runID == nil else { return nil }
            let applied = Check.run(CheckRun(
                databaseID: run.databaseID, name: run.name, status: run.status, conclusion: run.conclusion,
                startedAt: run.startedAt, completedAt: run.completedAt, detailsURL: run.detailsURL,
                appName: run.appName, workflow: workflow
            ))
            if let replaced, let index = checks.firstIndex(of: .run(replaced)) {
                checks[index] = applied
            } else {
                checks.append(applied)
            }
        case .pullRequest, .comment, .review, .reply, .threadResolved, .threads, .checks:
            return nil
        }
        return checks
    }
}

/// What deliveries have said about one part of a pull request: how many there were, and the
/// latest one's change. A screen showing the part watches the count.
public struct WebhookChanges: Sendable, Equatable {
    public private(set) var count = 0
    /// Nil when the latest delivery's payload could not be applied.
    public private(set) var latest: WebhookChange?

    public init() {}

    public mutating func note(_ change: WebhookChange?) {
        count += 1
        latest = change
    }

    /// The change to apply now that the count has risen from `seen`. Nil when the part has
    /// to load: the latest change can't be applied, or more than one came since `seen` and
    /// the ones before the latest are gone.
    public func only(since seen: Int) -> WebhookChange? {
        count == seen + 1 ? latest : nil
    }
}

/// Whether to load for a delivery that can't be applied. A review with ten line comments
/// sends ten such deliveries, and a new workflow run sends one per job.
///
/// The first delivery loads at once. The ones that come while that load runs, and for
/// `BurstLoader.spacing` after it, become one more load.
struct LoadBurst {
    /// Nil when no load is running. Otherwise, whether a delivery came since it started.
    private var again: Bool?

    /// Records a delivery.
    ///
    /// - Returns: Whether to load now. False when a load is running, which then runs once more.
    mutating func shouldLoad() -> Bool {
        guard again == nil else {
            again = true
            return false
        }
        again = false
        return true
    }

    /// Records that a load finished and the wait after it passed.
    ///
    /// - Returns: Whether to load again. False ends the burst.
    mutating func loaded() -> Bool {
        guard again == true else {
            again = nil
            return false
        }
        again = false
        return true
    }
}

/// Runs the loads of a `LoadBurst` for one screen.
@MainActor
public final class BurstLoader {
    /// How long after a load a delivery still counts as part of that load's burst.
    public static let spacing: Duration = .seconds(5)
    private var burst = LoadBurst()

    public init() {}

    /// Runs `operation` now when no load is running. Otherwise the running load runs its
    /// own operation once more, `spacing` after it finishes.
    public func load(_ operation: @escaping @MainActor () async -> Void) {
        guard burst.shouldLoad() else { return }
        Task { [weak self] in
            repeat {
                await operation()
                try? await Task.sleep(for: Self.spacing)
            } while self?.burst.loaded() == true
        }
    }
}

// MARK: Payload shapes

// GitHub's REST objects, with only the fields Hermes reads. A payload GitHub changes in a
// way these can't read decodes to no change, and the delivery is handled by loading.

/// Which objects a delivery has. The names are GitHub's.
private struct Keys: Decodable {
    struct Present: Decodable {}

    let pull_request: Present?
    let issue: Present?
    let comment: Present?
    let review: Present?
    let thread: Present?
    let check_run: Present?
    let check_suite: Present?
    /// A `status` delivery's name for the status, and its commit.
    let context: String?
    let sha: String?
}

private struct CheckRunEvent: Decodable {
    struct Run: Decodable {
        struct App: Decodable { let name: String }

        let id: Int
        let name: String
        /// Lowercase, where GraphQL's is uppercase. So is `conclusion`.
        let status: String
        let conclusion: String?
        let started_at: Date?
        let completed_at: Date?
        let details_url: String?
        let app: App?
    }

    let check_run: Run
}

private struct StatusEvent: Decodable {
    let context: String
    let state: String
    let target_url: String?
    let description: String?
}

struct RESTAuthor: Decodable {
    let login: String
    let avatar_url: URL
    let type: String?

    /// GraphQL, which the rest of Hermes reads, names a bot without the `[bot]` REST adds.
    var user: User {
        let isBot = type == "Bot"
        return User(
            login: isBot && login.hasSuffix("[bot]") ? String(login.dropLast(5)) : login, avatarURL: avatar_url, isBot: isBot
        )
    }
}

/// A conversation comment or a review comment.
struct RESTComment: Decodable {
    let id: Int
    let node_id: String
    /// Null when the author's account was deleted.
    let user: RESTAuthor?
    let body: String
    let created_at: Date
    /// On a line comment that answers another: the REST ID of the comment it answers.
    let in_reply_to_id: Int?
}

extension Comment {
    init(_ comment: RESTComment) {
        self.init(
            id: comment.node_id, databaseID: comment.id, author: comment.user?.user, body: comment.body,
            createdAt: comment.created_at
        )
    }
}

private struct IssueCommentEvent: Decodable {
    struct Issue: Decodable {
        struct Present: Decodable {}
        /// Only an issue that is a pull request has it. A comment on a plain issue is not read.
        let pull_request: Present
    }

    let action: String
    let issue: Issue
    let comment: RESTComment
}

private struct ReviewCommentEvent: Decodable {
    let action: String
    let comment: RESTComment
}

private struct ThreadEvent: Decodable {
    struct Thread: Decodable {
        /// The same ID GraphQL gives the thread.
        let node_id: String
    }

    let action: String
    let thread: Thread
}

private struct ReviewEvent: Decodable {
    struct Review: Decodable {
        let node_id: String
        let user: RESTAuthor?
        /// Null for a review that has only line comments.
        let body: String?
        /// Lowercase, where GraphQL's is uppercase.
        let state: String
        let submitted_at: Date?
    }

    let review: Review
}

struct RESTPullRequest: Decodable {
    struct Ref: Decodable {
        let ref: String
        /// Only the head's is read.
        let sha: String
    }
    struct AutoMerge: Decodable { let merge_method: String }
    struct Team: Decodable {
        let name: String
        let slug: String
    }

    let title: String
    let body: String?
    let state: String
    let merged: Bool
    let draft: Bool
    let labels: [GitHubLabel]
    let head: Ref
    let base: Ref
    let additions: Int
    let deletions: Int
    let changed_files: Int
    let auto_merge: AutoMerge?
    let requested_reviewers: [RESTAuthor]
    let requested_teams: [Team]
    let updated_at: Date
}

private struct PullRequestEvent: Decodable {
    struct Changes: Decodable {
        struct Present: Decodable {}
        let base: Present?
    }

    let action: String
    let changes: Changes?
    let pull_request: RESTPullRequest
}

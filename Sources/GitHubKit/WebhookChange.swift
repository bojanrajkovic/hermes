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

    /// Reads one delivery's JSON body. The kind of event is told from the body's keys,
    /// because a forwarder's deliveries carry no event name.
    init?(payload: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let keys = try? decoder.decode(Keys.self, from: payload) else { return nil }

        if keys.pull_request != nil, keys.comment == nil, keys.review == nil, keys.thread == nil {
            guard let event = try? decoder.decode(PullRequestEvent.self, from: payload) else { return nil }
            self = .pullRequest(
                PullRequestFields(event.pull_request, owner: event.repository.owner.login),
                reloads: Self.reloads(action: event.action, changesBase: event.changes?.base != nil)
            )
        } else {
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
    public let requestedReviewers: [Reviewer]

    public init(
        title: String, body: String, state: LinkedPullRequest.State, isDraft: Bool, labels: [GitHubLabel],
        headOID: String, headRefName: String, baseRefName: String, additions: Int, deletions: Int,
        changedFileCount: Int, autoMergeMethod: MergeMethod?, requestedReviewers: [Reviewer]
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
    }

    /// - Parameter owner: The repository's owner. A requested team belongs to it.
    init(_ pullRequest: RESTPullRequest, owner: String) {
        self.init(
            title: pullRequest.title, body: pullRequest.body ?? "",
            state: pullRequest.merged ? .merged : pullRequest.state == "closed" ? .closed : .open,
            isDraft: pullRequest.draft, labels: pullRequest.labels,
            headOID: pullRequest.head.sha, headRefName: pullRequest.head.ref, baseRefName: pullRequest.base.ref,
            additions: pullRequest.additions, deletions: pullRequest.deletions,
            changedFileCount: pullRequest.changed_files,
            autoMergeMethod: pullRequest.auto_merge.flatMap { MergeMethod(rawValue: $0.merge_method.uppercased()) },
            requestedReviewers: pullRequest.requested_reviewers.map { .user(login: $0.login) }
                + pullRequest.requested_teams.map { .team(organization: owner, slug: $0.slug) }
        )
    }
}

extension PullRequest {
    /// This pull request with the fields a webhook payload carries replaced. What the
    /// payload does not carry stays: the review decision, mergeability, checks, and stack.
    public func applying(_ fields: PullRequestFields) -> PullRequest {
        PullRequest(
            id: id, number: number, title: fields.title, url: url, repository: repository, author: author,
            isDraft: fields.isDraft, createdAt: createdAt, updatedAt: updatedAt,
            headRefName: fields.headRefName, baseRefName: fields.baseRefName, headOID: fields.headOID,
            reviewDecision: reviewDecision, additions: fields.additions, deletions: fields.deletions,
            changedFileCount: fields.changedFileCount, mergeable: mergeable, labels: fields.labels,
            checkState: checkState, stack: stack, closingIssueNumbers: closingIssueNumbers,
            autoMergeMethod: fields.autoMergeMethod, requestedReviewers: fields.requestedReviewers,
            viewerReviewedCommit: viewerReviewedCommit, state: fields.state
        )
    }
}

// MARK: Payload shapes

// GitHub's REST objects, with only the fields Hermes reads. A payload GitHub changes in a
// way these can't read decodes to no change, and the delivery is handled by loading.

/// Which objects a delivery has. The names are GitHub's.
private struct Keys: Decodable {
    struct Present: Decodable {}

    let pull_request: Present?
    let comment: Present?
    let review: Present?
    let thread: Present?
}

struct RESTRepository: Decodable {
    struct Owner: Decodable { let login: String }
    let owner: Owner
}

struct RESTPullRequest: Decodable {
    struct Ref: Decodable {
        let ref: String
        /// Only the head's is read.
        let sha: String
    }
    struct AutoMerge: Decodable { let merge_method: String }
    struct Login: Decodable { let login: String }
    struct Slug: Decodable { let slug: String }

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
    let requested_reviewers: [Login]
    let requested_teams: [Slug]
}

private struct PullRequestEvent: Decodable {
    struct Changes: Decodable {
        struct Present: Decodable {}
        let base: Present?
    }

    let action: String
    let changes: Changes?
    let pull_request: RESTPullRequest
    let repository: RESTRepository
}

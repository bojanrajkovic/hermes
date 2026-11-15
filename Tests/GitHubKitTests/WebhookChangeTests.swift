import Foundation
import Testing
@testable import GitHubKit

/// A `pull_request` delivery about pull request 7 of `acme/site`, with the given action, and
/// `fields` replacing the pull request's defaults.
private func pullRequestDelivery(action: String, changes: [String: Any]? = nil, _ fields: [String: Any] = [:]) -> Data {
    let pullRequest: [String: Any] = [
        "number": 7, "title": "Add a sitemap", "body": NSNull(), "state": "open", "merged": false, "draft": false,
        "labels": [["name": "site", "color": "ededed", "node_id": "LA_1"]],
        "head": ["sha": "new-head", "ref": "sitemap"], "base": ["sha": "base", "ref": "main"],
        "additions": 17, "deletions": 4, "changed_files": 3, "auto_merge": NSNull(),
        "requested_reviewers": [Any](), "requested_teams": [Any](),
    ]
    let delivery: [String: Any] = [
        "action": action, "number": 7, "changes": changes ?? NSNull(),
        "pull_request": pullRequest.merging(fields) { _, new in new },
        "repository": ["name": "site", "owner": ["login": "acme"]],
    ]
    return (try? JSONSerialization.data(withJSONObject: delivery)) ?? Data()
}

private func fields(of delivery: Data) -> PullRequestFields? {
    guard case .pullRequest(let fields, _)? = WebhookEvent(payload: delivery)?.change else { return nil }
    return fields
}

private func held() -> PullRequest {
    PullRequest(
        id: "PR_7", number: 7, title: "Old title", url: URL(string: "https://github.com/acme/site/pull/7")!,
        repository: RepositoryRef(owner: "acme", name: "site"),
        author: User(login: "octocat", avatarURL: URL(string: "https://example.com/a.png")!, isBot: false),
        isDraft: true, createdAt: .distantPast, updatedAt: .distantPast, headRefName: "sitemap", baseRefName: "main",
        headOID: "old-head", reviewDecision: .approved, additions: 1, deletions: 1, changedFileCount: 1,
        mergeable: .conflicting, labels: [], checkState: .failed,
        stack: StackEntry(stackID: "S", stackNumber: 1, size: 2, baseRefName: "main", position: 1),
        closingIssueNumbers: [3], viewerReviewedCommit: "old-head"
    )
}

struct WebhookChangeTests {
    @Test func aRealEditCarriesThePullRequestsFieldsAndNeedsNoLoad() throws {
        let event = try #require(WebhookEvent(payload: try fixture("webhook_pull_request_edited")))

        #expect(event.pullRequest == 53)
        #expect(event.change == .pullRequest(
            PullRequestFields(
                title: "Rendered Markdown repro (capture test)",
                body: "Two Markdown files, for reproducing a layout bug in Hermes' rendered view.",
                state: .open, isDraft: false, labels: [], headOID: "a1ced9bde73d65baa594b25a466a2acb508d7a68",
                headRefName: "md-repro", baseRefName: "md-repro-base", additions: 3, deletions: 1,
                changedFileCount: 2, autoMergeMethod: nil, requestedReviewers: []
            ),
            reloads: false
        ))
    }

    @Test func aPushCarriesTheNewHeadAndStillNeedsALoad() throws {
        let event = try #require(WebhookEvent(payload: pullRequestDelivery(action: "synchronize")))
        guard case .pullRequest(let fields, let reloads)? = event.change else {
            Issue.record("no change read")
            return
        }

        #expect(reloads)
        #expect(fields.headOID == "new-head")
        #expect((fields.additions, fields.deletions, fields.changedFileCount) == (17, 4, 3))
        #expect(fields.body.isEmpty)
        #expect(fields.labels == [GitHubLabel(name: "site", color: "ededed")])
    }

    @Test func theStateIsMergedClosedOrOpen() {
        #expect(fields(of: pullRequestDelivery(action: "closed", ["state": "closed", "merged": true]))?.state == .merged)
        #expect(fields(of: pullRequestDelivery(action: "closed", ["state": "closed"]))?.state == .closed)
        #expect(fields(of: pullRequestDelivery(action: "edited"))?.state == .open)
    }

    @Test func autoMergeAndRequestedReviewersAreRead() {
        let fields = fields(of: pullRequestDelivery(action: "review_requested", [
            "auto_merge": ["merge_method": "squash"],
            "requested_reviewers": [["login": "hubot"]], "requested_teams": [["slug": "web"]],
        ]))

        #expect(fields?.autoMergeMethod == .squash)
        // A team belongs to the organization that owns the repository.
        #expect(fields?.requestedReviewers == [.user(login: "hubot"), .team(organization: "acme", slug: "web")])
    }

    @Test(arguments: [
        "edited", "labeled", "unlabeled", "converted_to_draft", "ready_for_review", "closed",
        "review_requested", "review_request_removed", "auto_merge_enabled", "auto_merge_disabled",
    ])
    func anActionWhosePayloadCarriesItsWholeChangeNeedsNoLoad(action: String) {
        #expect(!WebhookChange.reloads(action: action, changesBase: false))
    }

    @Test(arguments: ["synchronize", "reopened", "opened", "stacked", "an_action_added_later"])
    func anActionThatChangesMoreThanItsPayloadCarriesNeedsALoad(action: String) {
        #expect(WebhookChange.reloads(action: action, changesBase: false))
    }

    @Test func anEditThatMovesTheBaseBranchNeedsALoad() throws {
        #expect(WebhookChange.reloads(action: "edited", changesBase: true))

        let moved = pullRequestDelivery(action: "edited", changes: ["base": ["ref": ["from": "main"]]])
        guard case .pullRequest(_, let reloads)? = WebhookEvent(payload: moved)?.change else {
            Issue.record("no change read")
            return
        }
        #expect(reloads)
    }

    @Test func applyingReplacesWhatThePayloadCarriesAndKeepsTheRest() throws {
        let old = held()
        let fields = try #require(fields(of: pullRequestDelivery(action: "synchronize")))
        let new = old.applying(fields)

        #expect(new.title == "Add a sitemap")
        #expect(new.headOID == "new-head")
        #expect(!new.isDraft)
        #expect(new.labels == [GitHubLabel(name: "site", color: "ededed")])
        #expect((new.additions, new.deletions, new.changedFileCount) == (17, 4, 3))

        // GitHub has to be asked for these.
        #expect(new.reviewDecision == .approved)
        #expect(new.mergeable == .conflicting)
        #expect(new.checkState == .failed)
        #expect(new.stack == old.stack)
        #expect(new.viewerReviewedCommit == "old-head")
        #expect((new.id, new.url, new.author, new.createdAt, new.updatedAt) == (old.id, old.url, old.author, old.createdAt, old.updatedAt))
        #expect(new.closingIssueNumbers == [3])
    }

    @Test func aPayloadHermesCannotReadStillNamesItsPullRequest() {
        // No title: GitHub changed the payload, or the delivery was cut short.
        let body = #"{"action": "edited", "pull_request": {"number": 7}, "repository": {"name": "site", "owner": {"login": "acme"}}}"#
        let event = WebhookEvent(payload: Data(body.utf8))

        #expect(event == WebhookEvent(repository: RepositoryRef(owner: "acme", name: "site"), pullRequest: 7))
        #expect(event?.change == nil)
    }
}

import Foundation
import os
import Testing
@testable import GitHubKit

struct WebhookForwarderTests {
    private let repository = #""repository": {"name": "airway", "owner": {"login": "bojan"}}"#
    private let airway = RepositoryRef(owner: "bojan", name: "airway")

    private func event(_ body: String) -> WebhookEvent? {
        WebhookEvent(payload: Data("{\(body)}".utf8))
    }

    @Test func aPullRequestEventNamesItsPullRequest() {
        #expect(event(#""action": "synchronize", "pull_request": {"number": 7}, \#(repository)"#)
            == WebhookEvent(repository: airway, pullRequest: 7))
    }

    @Test func aCommentCountsOnlyOnAPullRequest() {
        #expect(event(#""issue": {"number": 7, "pull_request": {"url": "u"}}, "comment": {}, \#(repository)"#)?.pullRequest == 7)
        #expect(event(#""issue": {"number": 8}, "comment": {}, \#(repository)"#) == WebhookEvent(repository: airway, pullRequest: nil))
    }

    @Test func aCheckSuiteNamesItsFirstPullRequest() {
        #expect(event(#""check_suite": {"pull_requests": [{"number": 7}, {"number": 9}]}, \#(repository)"#)?.pullRequest == 7)
        #expect(event(#""check_suite": {"pull_requests": []}, \#(repository)"#) == WebhookEvent(repository: airway, pullRequest: nil))
    }

    @Test func aStatusNamesOnlyItsRepository() {
        #expect(event(#""state": "success", "sha": "abc", \#(repository)"#) == WebhookEvent(repository: airway, pullRequest: nil))
    }

    @Test func aPingAndABodyThatIsNotADeliveryAreNotEvents() {
        #expect(event(#""zen": "Accessible for all.", "hook_id": 1, \#(repository)"#) == nil)
        #expect(event(#""action": "created""#) == nil)
        #expect(WebhookEvent(payload: Data("Forwarding".utf8)) == nil)
    }

    @Test func theFailureIsWhatTheExtensionPrintsBeforeItsUsage() {
        let refused = """
            Error: error creating webhook: HTTP 422: Validation Failed (https://api.github.com/repos/o/r/hooks)
            Hook already exists on this repository
            Usage:
              forward --events=<types> [--url=<url>] [flags]
            """

        #expect(WebhookForwarder.failure(in: refused) == """
            Error: error creating webhook: HTTP 422: Validation Failed (https://api.github.com/repos/o/r/hooks)
            Hook already exists on this repository
            """)
        #expect(WebhookForwarder.failure(in: "[LOG] received event \"ping\"\n") == "")
    }

    /// Forwards `bojanrajkovic/hermes-playground`, comments on its pull request 53, and deletes
    /// the comment. Needs the `cli/gh-webhook` extension and admin rights on the repository.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERMES_LIVE_WEBHOOKS"] == "1"))
    func aCommentArrivesAsAnEventAndStoppingEndsTheProcess() async throws {
        let playground = RepositoryRef(owner: "bojanrajkovic", name: "hermes-playground")
        let binary = try #require(WebhookForwarder.binary)
        let gh = try #require(await GitHubAuth.locateGH())
        let events = OSAllocatedUnfairLock<[WebhookEvent]>(initialState: [])
        let exited = OSAllocatedUnfairLock(initialState: false)

        let forwarder = try WebhookForwarder(
            repository: playground, binary: binary, token: try await GitHubAuth.token(),
            onEvent: { event in events.withLock { $0.append(event) } }, onExit: { _ in exited.withLock { $0 = true } }
        )
        try await Task.sleep(for: .seconds(4))
        #expect(!exited.withLock { $0 })

        let comments = "repos/\(playground)/issues/53/comments"
        let posted = try await GitHubAuth.run(gh, ["api", comments, "-f", "body=Webhook forwarder live test.", "--jq", ".id"])
        let id = posted.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<100 where events.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
        _ = try await GitHubAuth.run(gh, ["api", "-X", "DELETE", "repos/\(playground)/issues/comments/\(id)"])

        #expect(events.withLock { $0.first } == WebhookEvent(repository: playground, pullRequest: 53))
        forwarder.stop()
        for _ in 0..<50 where !exited.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(exited.withLock { $0 })
    }
}

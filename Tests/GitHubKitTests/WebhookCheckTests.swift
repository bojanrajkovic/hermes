import Foundation
import Testing
@testable import GitHubKit

private func delivery(_ body: [String: Any]) -> Data {
    let repository: [String: Any] = ["name": "site", "owner": ["login": "acme"]]
    return (try? JSONSerialization.data(withJSONObject: body.merging(["repository": repository]) { old, _ in old })) ?? Data()
}

/// A `check_run` delivery for a job of workflow run 5 of `acme/site`, with `fields` replacing its defaults.
private func checkRunDelivery(_ fields: [String: Any] = [:]) -> Data {
    let run: [String: Any] = [
        "id": 12, "name": "build", "status": "completed", "conclusion": "timed_out", "head_sha": "abc",
        "started_at": "2026-11-15T22:19:25Z", "completed_at": "2026-11-15T22:20:40Z",
        "details_url": "https://github.com/acme/site/actions/runs/5/job/12", "app": ["name": "GitHub Actions"],
        "pull_requests": [["number": 7]],
    ]
    return delivery(["action": "completed", "check_run": run.merging(fields) { _, new in new }])
}

private func run(_ id: Int, _ name: String, _ status: CheckRun.Status = .completed, workflow: CheckRun.Workflow?) -> CheckRun {
    CheckRun(
        databaseID: id, name: name, status: status, conclusion: status == .completed ? .success : nil,
        startedAt: nil, completedAt: nil, detailsURL: nil, appName: "GitHub Actions", workflow: workflow
    )
}

private func status(_ context: String, _ state: StatusState = .success) -> StatusContext {
    StatusContext(context: context, state: state, targetURL: nil, description: nil)
}

struct WebhookCheckTests {
    private let ci = CheckRun.Workflow(name: "CI", runID: 5)

    // MARK: Reading

    @Test func aStatusIsReadWithItsStateInTheModelsCase() {
        let event = WebhookEvent(payload: delivery([
            "sha": "abc", "context": "renovate/stability-days", "state": "success",
            "description": "Updates have met minimum release age requirement", "target_url": "https://example.com/status",
        ]))

        #expect(event?.commit == "abc")
        #expect(event?.change == .status(StatusContext(
            context: "renovate/stability-days", state: .success, targetURL: URL(string: "https://example.com/status"),
            description: "Updates have met minimum release age requirement"
        )))
    }

    @Test func aStatusWithNoLinkOrDescriptionIsStillRead() {
        let empty = delivery(["sha": "abc", "context": "ci", "state": "pending", "description": NSNull(), "target_url": ""])
        let absent = delivery(["sha": "abc", "context": "ci", "state": "error"])

        #expect(WebhookEvent(payload: empty)?.change == .status(status("ci", .pending)))
        #expect(WebhookEvent(payload: absent)?.change == .status(status("ci", .error)))
    }

    @Test func aCheckRunIsReadWithTheWorkflowRunItsLinkNames() {
        let event = WebhookEvent(payload: checkRunDelivery())
        guard case .checkRun(let run, let runID)? = event?.change else {
            Issue.record("no check run read")
            return
        }

        #expect((event?.pullRequest, event?.commit) == (7, "abc"))
        #expect(runID == 5)
        #expect((run.databaseID, run.name, run.appName) == (12, "build", "GitHub Actions"))
        #expect((run.status, run.conclusion) == (.completed, .timedOut))
        #expect(run.detailsURL == URL(string: "https://github.com/acme/site/actions/runs/5/job/12"))
        #expect(run.completedAt?.timeIntervalSince(run.startedAt ?? .distantPast) == 75)
        // The payload does not carry the workflow's name.
        #expect(run.workflow == nil)
    }

    @Test func aCheckRunThatHasNotFinishedOrComesFromAnotherAppIsRead() {
        let queued = checkRunDelivery(["status": "in_progress", "conclusion": NSNull(), "completed_at": NSNull()])
        let other = checkRunDelivery(["details_url": "https://vercel.com/acme/site/abc", "app": ["name": "Vercel"]])

        guard case .checkRun(let running, _)? = WebhookEvent(payload: queued)?.change,
              case .checkRun(let deployed, let runID)? = WebhookEvent(payload: other)?.change else {
            Issue.record("no check run read")
            return
        }
        #expect((running.status, running.conclusion, running.completedAt) == (.inProgress, nil, nil))
        #expect((deployed.appName, runID) == ("Vercel", nil))
    }

    @Test func aCheckSuiteSaysOnlyThatTheChecksChanged() {
        let event = WebhookEvent(payload: delivery(["action": "completed", "check_suite": ["head_sha": "abc", "pull_requests": [Any]()]]))

        #expect(event?.change == .checks)
        #expect(event?.commit == "abc")
    }

    @Test func aCheckRunHermesCannotReadFallsBackToLoading() {
        let event = WebhookEvent(payload: checkRunDelivery(["status": "a_status_added_later"]))

        #expect(event?.pullRequest == 7)
        #expect(event?.change == nil)
    }

    @Test func theWorkflowRunIsReadOnlyFromAnActionsJobLink() {
        func runID(_ url: String) -> Int? { WebhookChange.workflowRunID(in: URL(string: url)) }

        #expect(runID("https://github.com/bojanrajkovic/setlist/actions/runs/43768632613/job/132979322073") == 43_768_632_613)
        #expect(runID("https://github.com/acme/site/runs/12") == nil)
        #expect(runID("https://vercel.com/acme/actions/runs") == nil)
        #expect(WebhookChange.workflowRunID(in: nil) == nil)
    }

    // MARK: Applying

    @Test func aStatusReplacesTheOneWithItsNameOrJoinsTheList() {
        let checks: [Check] = [.run(run(11, "build", workflow: ci)), .status(status("ci/legacy", .pending))]

        #expect(Check.applying(.status(status("ci/legacy", .failure)), to: checks)
            == [checks[0], .status(status("ci/legacy", .failure))])
        #expect(Check.applying(.status(status("deploy")), to: checks) == checks + [.status(status("deploy"))])
    }

    @Test func aCheckRunHermesHoldsKeepsItsWorkflow() {
        let checks: [Check] = [.run(run(11, "build", .inProgress, workflow: ci)), .run(run(12, "test", workflow: ci))]
        let finished = run(11, "build", workflow: nil)

        #expect(Check.applying(.checkRun(finished, runID: 5), to: checks) == [.run(run(11, "build", workflow: ci)), checks[1]])
    }

    @Test func aJobThatRunsAgainReplacesItsEarlierAttempt() {
        let checks: [Check] = [.run(run(11, "build", workflow: ci)), .run(run(12, "test", workflow: ci))]
        let again = run(21, "build", .queued, workflow: nil)

        #expect(Check.applying(.checkRun(again, runID: 5), to: checks) == [.run(run(21, "build", .queued, workflow: ci)), checks[1]])
    }

    @Test func aLateDeliveryForAnEarlierAttemptLeavesTheNewerAttempt() {
        // The job ran again as check run 21. The first attempt's `completed` arrives after it.
        let checks: [Check] = [.run(run(21, "build", .queued, workflow: ci)), .run(run(12, "test", workflow: ci))]
        let earlier = run(11, "build", workflow: nil)

        #expect(Check.applying(.checkRun(earlier, runID: 5), to: checks) == checks)
    }

    @Test func aNewJobOfAKnownWorkflowRunTakesThatWorkflow() {
        let checks: [Check] = [.run(run(11, "build", workflow: ci))]
        let new = run(13, "deploy", .queued, workflow: nil)

        #expect(Check.applying(.checkRun(new, runID: 5), to: checks) == checks + [.run(run(13, "deploy", .queued, workflow: ci))])
    }

    @Test func aJobOfAWorkflowRunHermesHasNotSeenLoadsTheChecks() {
        // Its workflow's name is not in the payload, and no held check can lend it.
        let checks: [Check] = [.run(run(11, "build", workflow: ci))]

        #expect(Check.applying(.checkRun(run(31, "lint", .queued, workflow: nil), runID: 6), to: checks) == nil)
        #expect(Check.applying(.checkRun(run(31, "lint", .queued, workflow: nil), runID: 6), to: []) == nil)
    }

    @Test func anotherAppsNewCheckJoinsTheListWithNoWorkflow() {
        let checks: [Check] = [.run(run(11, "build", workflow: ci))]
        let deployed = run(41, "Vercel", workflow: nil)

        #expect(Check.applying(.checkRun(deployed, runID: nil), to: checks) == checks + [.run(deployed)])
    }

    @Test func aChangeThatIsNotAboutOneCheckLoadsTheChecks() {
        #expect(Check.applying(.checks, to: []) == nil)
        #expect(Check.applying(.threads, to: []) == nil)
    }
}

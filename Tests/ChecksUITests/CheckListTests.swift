import Foundation
import GitHubKit
import Testing
@testable import ChecksUI

func run(
    _ name: String, _ status: CheckRun.Status = .completed, _ conclusion: CheckRun.Conclusion? = .success,
    workflow: String? = "ci", id: Int = 0, started: Date? = nil, completed: Date? = nil, app: String? = "GitHub Actions"
) -> Check {
    .run(CheckRun(
        databaseID: id == 0 ? abs(name.hashValue) : id, name: name, status: status, conclusion: conclusion,
        startedAt: started, completedAt: completed, detailsURL: URL(string: "https://example.com/\(name)"),
        appName: app, workflow: workflow.map { .init(name: $0, runID: 1) }
    ))
}

@Suite struct CheckListTests {
    @Test func statesFromRunsAndStatuses() {
        #expect(run("a", .inProgress, nil).state == .running)
        #expect(run("a", .queued, nil).state == .queued)
        #expect(run("a", .waiting, nil).state == .queued)
        #expect(run("a", .completed, .timedOut).state == .failed)
        #expect(run("a", .completed, .cancelled).state == .cancelled)
        #expect(run("a", .completed, .actionRequired).state == .actionRequired)
        #expect(run("a", .completed, .skipped).state == .skipped)
        #expect(run("a", .completed, .neutral).state == .neutral)
        #expect(Check.status(.init(context: "c", state: .error, targetURL: nil, description: nil)).state == .failed)
        #expect(Check.status(.init(context: "c", state: .expected, targetURL: nil, description: nil)).state == .queued)
        // Every state has its own glyph shape.
        #expect(Set(CheckState.allCases.map(\.symbol)).count == CheckState.allCases.count)
    }

    @Test func groupsByWorkflowWithTheRestLast() {
        let status = Check.status(.init(context: "ci/legacy", state: .success, targetURL: nil, description: nil))
        let groups = CheckList.grouped([
            run("build"), status, run("title", workflow: "pr"), run("vercel", workflow: nil, app: "Vercel"), run("lint"),
        ])
        #expect(groups.map(\.title) == ["ci", "pr", "Other checks"])
        #expect(groups.map { $0.checks.map(\.name) } == [["build", "lint"], ["title"], ["ci/legacy", "vercel"]])
    }

    @Test func rollupAndAttentionOrder() {
        let checks = [
            run("a"), run("b", .inProgress, nil), run("c", .completed, .failure), run("d"),
            run("e", .completed, .skipped), run("f", .completed, .failure),
        ]
        #expect(CheckList.rollup(checks) == "2 passed, 2 failed, 1 running, 1 skipped")
        #expect(CheckList.rollup([]) == "No checks")
        #expect(CheckList.attentionFirst(checks).map(\.name) == ["c", "f", "b", "a", "d", "e"])
        #expect(CheckList.defaultSelection(checks) == checks[2].id)
        #expect(CheckList.defaultSelection([checks[0], checks[1]]) == checks[0].id)
    }

    @Test func pollsWhilePendingOrNewlyEmpty() {
        #expect(ChecksModel.keepsPolling([run("a"), run("b", .queued, nil)], elapsed: .seconds(3600)))
        #expect(!ChecksModel.keepsPolling([run("a")], elapsed: .zero))
        // Right after a push GitHub has not created the checks yet.
        #expect(ChecksModel.keepsPolling([], elapsed: .seconds(5)))
        #expect(!ChecksModel.keepsPolling([], elapsed: ChecksModel.emptyListPolling))
    }

    @Test func waitsForARateLimitToReset() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(ChecksModel.reloadDelay(after: nil, now: now) == ChecksModel.refreshInterval)
        #expect(ChecksModel.reloadDelay(after: URLError(.timedOut), now: now) == ChecksModel.refreshInterval)
        let limited = GitHubError.rateLimited(resetAt: now.addingTimeInterval(300))
        #expect(ChecksModel.reloadDelay(after: limited, now: now) == .seconds(300))
        // A reset time already passed does not make the loop spin.
        #expect(ChecksModel.reloadDelay(after: limited, now: now.addingTimeInterval(600)) == ChecksModel.refreshInterval)
    }

    @Test func durations() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(CheckList.duration(from: start, to: start.addingTimeInterval(130)) == "2m 10s")
        #expect(CheckList.duration(from: start, to: start.addingTimeInterval(34)) == "34s")
        #expect(CheckList.duration(from: start, to: start.addingTimeInterval(0.2)) == "0s")
    }

    @Test func jobStepsDecode() throws {
        let json = """
            {"status": "in_progress", "steps": [
              {"name": "Set up job", "status": "completed", "conclusion": "success", "number": 1,
               "started_at": "2026-11-11T02:46:28Z", "completed_at": "2026-11-11T02:46:29Z"},
              {"name": "Run tests", "status": "in_progress", "conclusion": null, "number": 2,
               "started_at": "2026-11-11T02:46:29Z", "completed_at": null},
              {"name": "Post", "status": "pending", "conclusion": null, "number": 3, "started_at": null, "completed_at": null}
            ]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(ActionsJob.self, from: Data(json.utf8))
        #expect(!job.isCompleted)
        #expect(job.steps?.map(\.state) == [.passed, .running, .queued])
    }
}

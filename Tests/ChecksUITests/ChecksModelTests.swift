import Foundation
import GitHubKit
import os
import Testing
@testable import ChecksUI

/// Answers every request with one commit's checks: a finished Actions job and a passed status.
private final class ChecksProtocol: URLProtocol {
    static let answer = """
        {"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
          {"__typename":"CheckRun","databaseId":11,"name":"build","status":"COMPLETED","conclusion":"SUCCESS",
           "startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:01:00Z",
           "detailsUrl":"https://github.com/o/r/actions/runs/5/job/11",
           "checkSuite":{"app":{"name":"GitHub Actions"},"workflowRun":{"databaseId":5,"workflow":{"name":"CI"}}}},
          {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","targetUrl":null,"description":null}
        ]}}}}}}
        """

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// How many requests a client whose token is `held` has made. Each waits for a signal
    /// of `gate`, so a test decides what happens while GitHub is asked.
    static let heldRequests = OSAllocatedUnfairLock(initialState: 0)
    static let gate = DispatchSemaphore(value: 0)

    override func startLoading() {
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer held" {
            Self.heldRequests.withLock { $0 += 1 }
            Self.gate.wait()
        }
        client?.urlProtocol(
            self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(Self.answer.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor struct ChecksModelTests {
    private let repository = RepositoryRef(owner: "o", name: "r")

    private func client(token: String = "token") -> GitHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChecksProtocol.self]
        return GitHubClient(session: URLSession(configuration: configuration), token: { token })
    }

    private func loadedModel() async -> ChecksModel {
        let model = ChecksModel()
        // Nothing is queued or running, so this loads once and returns.
        await model.run(repository: repository, commitOID: "abc", client: client())
        return model
    }

    private func queued(_ name: String, id: Int) -> CheckRun {
        CheckRun(
            databaseID: id, name: name, status: .queued, conclusion: nil, startedAt: nil, completedAt: nil,
            detailsURL: URL(string: "https://github.com/o/r/actions/runs/5/job/\(id)"), appName: "GitHub Actions", workflow: nil
        )
    }

    @Test func nothingIsAppliedBeforeTheChecksLoad() {
        let status = StatusContext(context: "ci/legacy", state: .failure, targetURL: nil, description: nil)

        #expect(!ChecksModel().apply(.status(status)))
    }

    @Test func aDeliverysChangeIsAppliedToTheLoadedChecks() async {
        let model = await loadedModel()
        #expect(model.checks.map(\.name) == ["build", "ci/legacy"])
        #expect(!model.needsPolling)

        let failed = StatusContext(context: "ci/legacy", state: .failure, targetURL: nil, description: "Broke")
        #expect(model.apply(.status(failed)))
        #expect(model.checks.last == .status(failed))
        #expect(!model.needsPolling)

        // A check suite that finished says nothing a payload can place, so the checks load.
        #expect(!model.apply(.checks))
        #expect(model.checks.count == 2)
    }

    @Test func aChangeAppliedWhileTheChecksLoadMakesThemLoadAgain() async {
        let model = await loadedModel()
        let held = client(token: "held")
        let load = Task { await model.run(repository: repository, commitOID: "abc", client: held) }
        while ChecksProtocol.heldRequests.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(5)) }

        // GitHub was asked before this change, so its answer is the older one, and the checks load again.
        let failed = StatusContext(context: "ci/legacy", state: .failure, targetURL: nil, description: nil)
        #expect(model.apply(.status(failed)))
        ChecksProtocol.gate.signal()
        ChecksProtocol.gate.signal()
        await load.value

        #expect(ChecksProtocol.heldRequests.withLock { $0 } == 2)
    }

    @Test func aCheckThatStartsAfterPollingEndedAsksForPollingAgain() async {
        let model = await loadedModel()

        // The job runs again: a new check run, for the same job of the same workflow run.
        #expect(model.apply(.checkRun(queued("build", id: 12), runID: 5)))
        #expect(model.checks.map(\.name) == ["build", "ci/legacy"])
        #expect(model.checks.first?.state == .queued)
        #expect(model.checks.first?.run?.workflow == CheckRun.Workflow(name: "CI", runID: 5))
        #expect(model.needsPolling)
    }
}

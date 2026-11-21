import Foundation
import GitHubKit
import os
import Testing
@testable import StateKit

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

    /// While true, requests from a client whose token is `held` wait for a signal of `gate`,
    /// so a test decides what happens while GitHub is asked.
    static let holding = OSAllocatedUnfairLock(initialState: false)
    static let heldRequests = OSAllocatedUnfairLock(initialState: 0)
    static let gate = DispatchSemaphore(value: 0)

    /// How many requests each token's client has made.
    static let requests = OSAllocatedUnfairLock(initialState: [String: Int]())

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        Self.requests.withLock { $0[token, default: 0] += 1 }
        if token == "Bearer offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if token == "Bearer held", Self.holding.withLock({ $0 }) {
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

@MainActor struct ChecksTests {
    private let commit = CommitKey(repository: RepositoryRef(owner: "o", name: "r"), oid: "abc")

    private func store(token: String = "token") -> GitHubStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChecksProtocol.self]
        return GitHubStore(client: GitHubClient(session: URLSession(configuration: configuration), token: { token }))
    }

    private func loadedStore(token: String = "token") async -> GitHubStore {
        let store = store(token: token)
        await store.loadChecks(commit)
        return store
    }

    private func checks(in store: GitHubStore) -> [Check] { store.checks[commit]?.checks ?? [] }

    private func queued(_ name: String, id: Int) -> CheckRun {
        CheckRun(
            databaseID: id, name: name, status: .queued, conclusion: nil, startedAt: nil, completedAt: nil,
            detailsURL: URL(string: "https://github.com/o/r/actions/runs/5/job/\(id)"), appName: "GitHub Actions", workflow: nil
        )
    }

    @Test func nothingIsAppliedBeforeTheChecksLoad() {
        let status = StatusContext(context: "ci/legacy", state: .failure, targetURL: nil, description: nil)

        #expect(!store().applyToChecks(.status(status), for: commit))
    }

    @Test func aDeliverysChangeIsAppliedToTheLoadedChecks() async {
        let store = await loadedStore()
        #expect(checks(in: store).map(\.name) == ["build", "ci/legacy"])

        let failed = StatusContext(context: "ci/legacy", state: .failure, targetURL: nil, description: "Broke")
        #expect(store.applyToChecks(.status(failed), for: commit))
        #expect(checks(in: store).last == .status(failed))

        // A check suite that finished says nothing a payload can place, so the checks load.
        #expect(!store.applyToChecks(.checks, for: commit))
        #expect(checks(in: store).count == 2)
    }

    @Test func aChangeAppliedWhileTheChecksLoadMakesThemLoadAgain() async {
        let store = await loadedStore(token: "held")
        ChecksProtocol.holding.withLock { $0 = true }
        defer { ChecksProtocol.holding.withLock { $0 = false } }
        let load = Task { await store.loadChecks(commit) }
        while ChecksProtocol.heldRequests.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(5)) }

        // GitHub was asked before this change, so its answer is the older one, and the checks load again.
        let failed = StatusContext(context: "ci/legacy", state: .failure, targetURL: nil, description: nil)
        #expect(store.applyToChecks(.status(failed), for: commit))
        ChecksProtocol.gate.signal()
        ChecksProtocol.gate.signal()
        await load.value

        #expect(ChecksProtocol.heldRequests.withLock { $0 } == 2)
    }

    @Test func aCheckThatStartsAfterPollingEndedMakesPollingResume() async {
        let store = await loadedStore()
        #expect(!keepsPolling(checks(in: store), elapsed: .seconds(3600)))

        // The job runs again: a new check run, for the same job of the same workflow run.
        #expect(store.applyToChecks(.checkRun(queued("build", id: 12), runID: 5), for: commit))
        #expect(checks(in: store).map(\.name) == ["build", "ci/legacy"])
        guard case .run(let rerun)? = checks(in: store).first else { return #expect(Bool(false), "build is a check run") }
        #expect(rerun.workflow == CheckRun.Workflow(name: "CI", runID: 5))
        // The commit's next poll loads it again.
        #expect(keepsPolling(checks(in: store), elapsed: .seconds(3600)))
    }

    @Test func aSettledListLoadsAgainWhenAScreenShowsItAgain() async {
        let token = "settled-\(UUID().uuidString)"
        let requests = { ChecksProtocol.requests.withLock { $0["Bearer \(token)", default: 0] } }
        let store = store(token: token)

        await store.pollChecks(commit)
        #expect(requests() == 1)
        // Nothing is queued or running, so later polls load nothing.
        await store.pollChecks(commit)
        #expect(requests() == 1)

        // The last screen went away. The next one to show the commit loads it.
        store.stoppedShowing(commit)
        await store.pollChecks(commit)
        #expect(requests() == 2)
    }

    @Test func aFailedFirstLoadWaitsForRetry() async {
        let store = store(token: "offline")
        let requests = { ChecksProtocol.requests.withLock { $0["Bearer offline", default: 0] } }
        let before = requests()

        await store.pollChecks(commit)
        #expect(store.checks[commit]?.errorMessage != nil)
        await store.pollChecks(commit)
        #expect(requests() == before + 1)

        await store.loadChecks(commit)
        #expect(requests() == before + 2)
    }

    @Test func pollsWhilePendingOrNewlyEmpty() async {
        let store = await loadedStore()
        let done = checks(in: store)
        #expect(!keepsPolling(done, elapsed: .zero))
        // Right after a push GitHub has not created the checks yet.
        #expect(keepsPolling([], elapsed: .seconds(5)))
        #expect(!keepsPolling([], elapsed: emptyChecksPolling))
    }

    @Test func waitsForARateLimitToReset() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(checksReloadDelay(after: URLError(.timedOut), now: now) == checksInterval)
        let limited = GitHubError.rateLimited(resetAt: now.addingTimeInterval(300))
        #expect(checksReloadDelay(after: limited, now: now) == .seconds(300))
        // A reset time already passed does not make the loop spin.
        #expect(checksReloadDelay(after: limited, now: now.addingTimeInterval(600)) == checksInterval)
    }
}

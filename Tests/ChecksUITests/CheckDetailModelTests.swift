import Foundation
import GitHubKit
import os
import Testing
@testable import ChecksUI

/// Accepts every request and never answers, so a load stays in flight until it is cancelled.
private final class SilentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// Answers each request from `script`: per path, the responses to give in
/// order. The last one repeats. A path without a script gets a 500.
private final class ScriptedProtocol: URLProtocol {
    struct Response: Sendable {
        var status = 200
        var body = ""
    }

    static let script = OSAllocatedUnfairLock<[String: [Response]]>(initialState: [:])
    static let requests = OSAllocatedUnfairLock<[String]>(initialState: [])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        Self.requests.withLock { $0.append(path) }
        let response = Self.script.withLock { script in
            guard let responses = script[path], let next = responses.first else { return Response(status: 500) }
            if responses.count > 1 { script[path]?.removeFirst() }
            return next
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// Serialized: the tests share `ScriptedProtocol`'s static state.
@Suite(.serialized) @MainActor struct CheckDetailModelTests {
    private let repository = RepositoryRef(owner: "o", name: "r")
    private let jobPath = "/repos/o/r/actions/jobs/7"
    private let logPath = "/repos/o/r/actions/jobs/7/logs"
    private let running = ScriptedProtocol.Response(
        body: #"{"status": "in_progress", "steps": [{"name": "Build", "status": "in_progress", "conclusion": null, "number": 1}]}"#
    )
    private let completed = ScriptedProtocol.Response(body: #"{"status": "completed", "steps": []}"#)

    private func client(_ protocolClass: AnyClass) -> GitHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return GitHubClient(session: URLSession(configuration: configuration), token: { "token" })
    }

    /// Loads job 7 with `script` as GitHub's answers, and returns the paths requested.
    private func load(
        _ status: CheckRun.Status, into model: CheckDetailModel, script: [String: [ScriptedProtocol.Response]]
    ) async -> [String] {
        ScriptedProtocol.script.withLock { $0 = script }
        ScriptedProtocol.requests.withLock { $0 = [] }
        (model.stepRefreshInterval, model.logRetryInterval) = (.milliseconds(1), .milliseconds(1))
        let check = run("build", status, status == .completed ? .success : nil, id: 7)
        await model.run(check: check, repository: repository, client: client(ScriptedProtocol.self))
        return ScriptedProtocol.requests.withLock { $0 }
    }

    @Test func cancelledLoadDoesNotReplaceTheNextChecksContent() async {
        let client = client(SilentProtocol.self)
        let model = CheckDetailModel()

        // The user selects an app's check, then a legacy status before the first has loaded.
        let first = Task { await model.run(check: run("Vercel", workflow: nil), repository: repository, client: client) }
        try? await Task.sleep(for: .milliseconds(50))
        first.cancel()
        let status = Check.status(.init(context: "codecov", state: .failure, targetURL: nil, description: "62% of diff hit"))
        await model.run(check: status, repository: repository, client: client)
        await first.value

        guard case .status("62% of diff hit") = model.content else {
            Issue.record("the cancelled load replaced the content: \(model.content)")
            return
        }
    }

    @Test func aFailedStepRefreshIsTriedAgain() async {
        let model = CheckDetailModel()
        let requests = await load(.inProgress, into: model, script: [
            jobPath: [running, .init(status: 502), completed],
            logPath: [.init(body: "all done")],
        ])

        #expect(requests == [jobPath, jobPath, jobPath, logPath])
        guard case .log = model.content else {
            Issue.record("the failed refresh ended the load: \(model.content)")
            return
        }
    }

    @Test func waitsForTheLogOfAJobItWatchedFinish() async {
        let model = CheckDetailModel()
        let requests = await load(.inProgress, into: model, script: [
            jobPath: [completed],
            logPath: [.init(status: 404), .init(status: 404), .init(body: "all done")],
        ])

        #expect(requests == [jobPath, logPath, logPath, logPath])
        guard case .log = model.content else {
            Issue.record("expected the log, got: \(model.content)")
            return
        }
    }

    @Test func givesUpOnALogThatNeverAppears() async {
        let model = CheckDetailModel()
        let requests = await load(.inProgress, into: model, script: [jobPath: [completed], logPath: [.init(status: 404)]])

        #expect(requests.count { $0 == logPath } == CheckDetailModel.logTriesAfterWatching)
        guard case .noLog = model.content else {
            Issue.record("expected no log, got: \(model.content)")
            return
        }
    }

    @Test func asksOnceForTheLogOfAJobThatHadFinished() async {
        let model = CheckDetailModel()
        let requests = await load(.completed, into: model, script: [logPath: [.init(status: 404)]])

        #expect(requests == [logPath])
        guard case .noLog = model.content else {
            Issue.record("expected no log, got: \(model.content)")
            return
        }
    }

    @Test func aFailedFirstStepLoadIsReported() async {
        let model = CheckDetailModel()
        let requests = await load(.inProgress, into: model, script: [jobPath: [.init(status: 502), completed]])

        #expect(requests == [jobPath])
        guard case .failed = model.content else {
            Issue.record("expected the error, got: \(model.content)")
            return
        }
    }
}

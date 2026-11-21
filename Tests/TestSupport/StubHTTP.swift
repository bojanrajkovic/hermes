import Foundation
import GitHubKit

/// Answers GraphQL requests with queued `data` objects, without the network.
///
/// Each `StubHTTP` has its own queue, keyed by the token its client sends, so suites that
/// run in parallel don't take each other's answers. Within one stub, requests take answers
/// in the order they were queued.
public final class StubHTTP: Sendable {
    public let client: GitHubClient
    private let token: String

    public init() {
        let token = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        self.token = token
        client = GitHubClient(session: URLSession(configuration: configuration), token: { token })
    }

    /// Queues the `data` object of the next answer, sent after `delay` seconds.
    public func enqueue(_ data: String, delay: TimeInterval = 0) {
        StubProtocol.lock.withLock { StubProtocol.answers[token, default: []].append((delay, data)) }
    }
}

private final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var answers: [String: [(delay: TimeInterval, data: String)]] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let answer = Self.lock.withLock { () -> (delay: TimeInterval, data: String)? in
            guard var queue = Self.answers[token], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            Self.answers[token] = queue
            return first
        }
        guard let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        Thread.sleep(forTimeInterval: answer.delay)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":\#(answer.data)}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

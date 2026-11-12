import Foundation
import os

/// A GitHub API client for github.com.
///
/// Create one at launch and share it. The token is read on first use and kept
/// until GitHub rejects it with HTTP 401; the next call reads it again.
///
/// Every method throws `GitHubError`, plus `URLError` for network failures and
/// `CancellationError` when its task is cancelled.
public actor GitHubClient {
    private static let api = URL(string: "https://api.github.com")!

    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String
    private var token: Task<String, any Error>?

    /// - Parameters:
    ///   - session: The session used for every request.
    ///   - token: Returns the token to authenticate with. Defaults to `gh auth token`.
    public init(
        session: URLSession = .shared,
        token: @escaping @Sendable () async throws -> String = GitHubAuth.token
    ) {
        self.session = session
        self.tokenProvider = token
    }

    // MARK: REST

    /// Sends a REST `GET` and returns the response body.
    ///
    /// - Parameters:
    ///   - path: Path and query below `https://api.github.com`, such as `/user`.
    ///   - accept: The `Accept` header, which selects the representation.
    /// - Throws: `GitHubError.rateLimited` when the rate limit is used up,
    ///   `GitHubError.http` for any other non-success status.
    public func get(_ path: String, accept: String = "application/vnd.github+json") async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.api) else {
            throw GitHubError.http(status: 400, message: "Invalid path: \(path)")
        }
        var request = URLRequest(url: url)
        // GitHub marks REST responses cacheable for 60 seconds, which would
        // make a caller that polls for a change see stale data.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return try await send(request).data
    }

    /// Sends a REST `GET` and decodes the JSON response.
    ///
    /// - Throws: As `get(_:accept:)`, plus `GitHubError.decoding` when the
    ///   response does not match `type`.
    public func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T {
        try Self.decode(type, from: try await get(path))
    }

    /// Sends a REST `POST` with no body and returns the response body.
    ///
    /// - Throws: As `get(_:accept:)`.
    @discardableResult
    public func post(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.api) else {
            throw GitHubError.http(status: 400, message: "Invalid path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try await send(request).data
    }

    // MARK: GraphQL

    /// Runs a GraphQL query or mutation and decodes its `data` object.
    ///
    /// - Parameters:
    ///   - query: The GraphQL document.
    ///   - variables: Values for the document's variables.
    ///   - type: The shape of the response's `data` object.
    /// - Throws: `GitHubError.graphQL` when the response has errors, even
    ///   alongside partial data. `GitHubError.rateLimited`, `GitHubError.http`,
    ///   and `GitHubError.decoding` as for REST.
    public func graphQL<T: Decodable & Sendable>(
        _ query: String,
        variables: [String: JSONValue] = [:],
        as type: T.Type
    ) async throws -> T {
        try await run(GraphQLRequest(query: query, variables: variables))
    }

    func run<T: Decodable & Sendable>(_ graphQLRequest: GraphQLRequest) async throws -> T {
        var request = URLRequest(url: Self.api.appending(path: "graphql"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sorted, so a request encodes to the same bytes every time: dictionary order varies between encodes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(graphQLRequest)

        let (data, response) = try await send(request)
        return try Self.decodeGraphQL(T.self, from: data, rateLimitReset: Self.rateLimitReset(response, now: .now))
    }

    // MARK: Transport

    private func send(_ original: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = original
        request.setValue("Bearer \(try await currentToken())", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Hermes", forHTTPHeaderField: "User-Agent")

        let started = ContinuousClock.now
        let data: Data, urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            Self.log.error("\(Self.describe(original), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let response = urlResponse as? HTTPURLResponse else {
            throw GitHubError.http(status: 0, message: "Not an HTTP response")
        }

        if response.statusCode == 401 { token = nil }
        let error = Self.error(for: response, body: data, now: .now)
        Self.logResponse(original, response, data: data, elapsed: ContinuousClock.now - started, error: error)
        if let error { throw error }
        return (data, response)
    }

    // MARK: Logging

    private static let log = Logger(subsystem: "com.coderinserepeat.hermes", category: "github")

    /// One line per request: what it was, its status, size, and time, and the rate limit headers.
    /// Watch with `log stream --predicate 'subsystem == "com.coderinserepeat.hermes" AND category == "github"'`.
    private static func logResponse(
        _ request: URLRequest, _ response: HTTPURLResponse, data: Data, elapsed: Duration, error: GitHubError?
    ) {
        func header(_ name: String) -> String { response.value(forHTTPHeaderField: name) ?? "-" }
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let line = "\(describe(request)) → \(response.statusCode), \(data.count) bytes, \(milliseconds) ms; "
            + "\(header("x-ratelimit-resource")) used \(header("x-ratelimit-used")), remaining \(header("x-ratelimit-remaining"))"
            + (response.value(forHTTPHeaderField: "retry-after").map { ", retry-after \($0)s" } ?? "")
        if let error {
            log.error("\(line, privacy: .public) — \(String(describing: error), privacy: .public)")
        } else {
            log.notice("\(line, privacy: .public)")
        }
    }

    /// The method and path, and for GraphQL the start of the query and its search string or IDs count.
    private static func describe(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        let path = request.url.map { $0.path + ($0.query.map { "?\($0)" } ?? "") } ?? "?"
        guard let body = request.httpBody, let graphQL = try? JSONDecoder().decode(LoggedGraphQL.self, from: body) else {
            return "\(method) \(path)"
        }
        let query = graphQL.query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var detail = String(query.prefix(70))
        if let search = graphQL.variables?.q { detail += " q=\"\(search)\"" }
        if let ids = graphQL.variables?.ids { detail += " ids=\(ids.count)" }
        if let after = graphQL.variables?.after { detail += " after=\(after)" }
        return "GraphQL \(detail)"
    }

    private struct LoggedGraphQL: Decodable {
        struct Variables: Decodable {
            let q: String?
            let ids: [String]?
            let after: String?
        }
        let query: String
        let variables: Variables?
    }

    /// Concurrent first calls share one read of the token: reading it starts
    /// `gh`, and maybe a login shell before it.
    private func currentToken() async throws -> String {
        if let token { return try await token.value }
        let read = Task { [tokenProvider] in try await tokenProvider() }
        token = read
        do {
            return try await read.value
        } catch {
            if token == read { token = nil }
            throw error
        }
    }

    // MARK: Response handling

    /// The error a response stands for, or nil when it succeeded.
    static func error(for response: HTTPURLResponse, body: Data, now: Date) -> GitHubError? {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return nil }

        let limited = response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            || response.value(forHTTPHeaderField: "retry-after") != nil
        if (status == 403 || status == 429) && limited {
            return .rateLimited(resetAt: rateLimitReset(response, now: now))
        }

        struct Message: Decodable { let message: String }
        let message = (try? JSONDecoder().decode(Message.self, from: body))?.message ?? ""
        return .http(status: status, message: message)
    }

    /// When requests succeed again: `retry-after` for a secondary limit,
    /// `x-ratelimit-reset` for the primary one, a minute from `now` when
    /// GitHub sent neither.
    static func rateLimitReset(_ response: HTTPURLResponse, now: Date) -> Date {
        if let seconds = response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init) {
            return now.addingTimeInterval(seconds)
        }
        if let epoch = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init) {
            return Date(timeIntervalSince1970: epoch)
        }
        return now.addingTimeInterval(60)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GitHubError.decoding(description: String(describing: error))
        }
    }

    /// Decodes the `data` object of a GraphQL response.
    ///
    /// - Parameter rateLimitReset: The reset time to report when the errors
    ///   say the rate limit is used up. GraphQL reports that with HTTP 200.
    static func decodeGraphQL<T: Decodable>(_ type: T.Type, from data: Data, rateLimitReset: Date) throws -> T {
        // Errors first: with partial data, decoding `T` would fail and hide them.
        if let errors = try decode(GraphQLErrors.self, from: data).errors, !errors.isEmpty {
            if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
                throw GitHubError.rateLimited(resetAt: rateLimitReset)
            }
            throw GitHubError.graphQL(errors)
        }
        return try decode(GraphQLData<T>.self, from: data).data
    }
}

/// A GraphQL document with its variables: the body of a GraphQL request.
struct GraphQLRequest: Sendable, Equatable, Encodable {
    let query: String
    let variables: [String: JSONValue]
}

private struct GraphQLErrors: Decodable { let errors: [GraphQLError]? }
private struct GraphQLData<T: Decodable>: Decodable { let data: T }

/// A GraphQL connection, with the parts the queries ask for.
struct Connection<Node: Decodable & Sendable>: Decodable, Sendable {
    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    let nodes: [Node]
    let pageInfo: PageInfo?
    let totalCount: Int?

    /// Where the next page starts. Nil on the last page.
    var nextCursor: String? { pageInfo?.hasNextPage == true ? pageInfo?.endCursor : nil }
}

import CryptoKit
import Foundation

/// An answer from the relay that is not the one a call expects.
public enum RelayError: Error, Sendable, Equatable {
    /// The invite code is not one the relay accepts.
    case inviteRefused
    /// The tenant ID is already registered with other values.
    case alreadyRegistered
    /// The relay refused the sign-in's grant: it was used already, or is more than ten minutes old.
    case grantRefused
    case unexpected(status: Int)
}

extension RelayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .inviteRefused: "The relay did not accept the invite code."
        case .alreadyRegistered: "The relay already has this tenant with other values."
        case .grantRefused: "The sign-in took too long. Sign in again."
        case .unexpected(let status): "The relay answered with status \(status)."
        }
    }
}

/// What registers a tenant: an invite code and the secrets of the App its owner made.
public struct RelayRegistration: Sendable, Equatable, Encodable {
    public let invite: String
    public let appID: Int
    public let clientID: String
    public let clientSecret: String
    public let webhookSecret: String

    public init(invite: String, appID: Int, clientID: String, clientSecret: String, webhookSecret: String) {
        self.invite = invite
        self.appID = appID
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.webhookSecret = webhookSecret
    }
}

/// The secret of one sign-in, which is PKCE's code verifier (RFC 7636). The browser carries
/// only its `challenge`, in the relay's login address. Hermes sends the verifier in the body
/// of the session request, and the relay exchanges the grant only when the two match. The
/// relay's operator can see a request's address but not its body.
public struct RelayVerifier: Sendable, Equatable {
    /// 43 characters of base64url.
    public let value: String

    /// A new verifier: 32 random bytes.
    public init() {
        value = Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    init(value: String) {
        self.value = value
    }

    /// The SHA-256 of the verifier, in base64url without padding.
    public var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(value.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}

/// The relay's HTTP calls. Each throws `RelayError` for an answer it does not expect, and
/// `URLError` when the relay can't be reached.
public struct RelayAPI: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The commit the relay at `server` was built from.
    public func version(of server: URL) async throws -> String {
        struct Version: Decodable { let commit: String }
        let data = try await send(URLRequest(url: server.appending(path: "version")), expecting: 200)
        return try decode(Version.self, from: data).commit
    }

    /// Registers a tenant. Sending the same registration again succeeds, so a call whose
    /// answer was lost can be repeated.
    public func register(_ registration: RelayRegistration, as tenant: RelayTenant) async throws {
        _ = try await send(
            try Self.registerRequest(registration, as: tenant), expecting: 201,
            refused: [403: .inviteRefused, 409: .alreadyRegistered]
        )
    }

    /// Exchanges the grant of a `hermes://relay.session` link for the member's refresh token.
    ///
    /// - Parameter verifier: The verifier whose challenge the sign-in's login address carried.
    public func refreshToken(grant: String, verifier: RelayVerifier, for tenant: RelayTenant) async throws -> String {
        struct Session: Decodable { let refreshToken: String }
        let data = try await send(
            try Self.sessionRequest(grant: grant, verifier: verifier, for: tenant), expecting: 200, refused: [403: .grantRefused]
        )
        return try decode(Session.self, from: data).refreshToken
    }

    /// The address a sign-in opens in the browser:
    /// `<server>/t/<tenant>/login?state=…&code_challenge=…`.
    public static func loginURL(for tenant: RelayTenant, state: String, verifier: RelayVerifier) -> URL {
        tenant.server.appending(path: "t/\(tenant.id)/login").appending(queryItems: [
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: verifier.challenge),
        ])
    }

    static func registerRequest(_ registration: RelayRegistration, as tenant: RelayTenant) throws -> URLRequest {
        try json(registration, method: "PUT", url: tenant.server.appending(path: "tenants/\(tenant.id)"))
    }

    static func sessionRequest(grant: String, verifier: RelayVerifier, for tenant: RelayTenant) throws -> URLRequest {
        try json(
            ["grant": grant, "verifier": verifier.value], method: "POST", url: tenant.server.appending(path: "t/\(tenant.id)/session")
        )
    }

    /// The error for an answer whose status is not the expected one.
    static func error(status: Int, expecting expected: Int, refused: [Int: RelayError] = [:]) -> RelayError? {
        status == expected ? nil : refused[status] ?? .unexpected(status: status)
    }

    private static func json(_ body: some Encodable, method: String, url: URL) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func send(_ request: URLRequest, expecting expected: Int, refused: [Int: RelayError] = [:]) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = Self.error(status: status, expecting: expected, refused: refused) { throw error }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubError.decoding(description: String(describing: error))
        }
    }
}

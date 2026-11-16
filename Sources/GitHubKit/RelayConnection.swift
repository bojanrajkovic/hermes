import Foundation
import Security

/// What the relay says first on a connection: who this is to it, and for how long.
public struct RelaySession: Sendable, Equatable {
    /// The token for the next connection. The one this connection used no longer works.
    public let refreshToken: String
    /// When the relay closes the connection to check the member's access again.
    public let expiresAt: Date
    /// The repositories the member can see through the tenant's App. Events come only for these.
    public let repositories: [RepositoryRef]
}

/// One webhook delivery, as GitHub sent it to the relay.
public struct RelayEvent: Sendable, Equatable {
    /// GitHub's name for the event, such as `pull_request` or `check_run`.
    public let name: String
    /// GitHub's ID for the delivery.
    public let delivery: String
    /// The delivery's JSON body.
    public let payload: Data
}

/// One message from the relay.
public enum RelayMessage: Sendable, Equatable {
    case session(RelaySession)
    case event(RelayEvent)

    /// Reads one WebSocket frame. Nil for a frame that is not a message Hermes knows.
    public init?(frame: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "session":
            guard let token = object["refreshToken"] as? String, let expiresAt = object["expiresAt"] as? Double,
                  let names = object["repositories"] as? [String] else { return nil }
            let repositories = names.compactMap { name -> RepositoryRef? in
                let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
                return parts.count == 2 ? RepositoryRef(owner: parts[0], name: parts[1]) : nil
            }
            self = .session(RelaySession(
                refreshToken: token, expiresAt: Date(timeIntervalSince1970: expiresAt), repositories: repositories
            ))
        case "event":
            guard let name = object["event"] as? String, let delivery = object["delivery"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            self = .event(RelayEvent(name: name, delivery: delivery, payload: body))
        default:
            return nil
        }
    }
}

/// One WebSocket to a tenant of the relay, open from `init` until it ends or `stop()` is called.
///
/// Hermes sends a hello with the member's refresh token. The relay answers with a
/// `RelaySession`, then sends a `RelayEvent` for each webhook delivery in a repository the
/// member can see.
public final class RelayConnection: Sendable {
    /// One thing a connection reports.
    public enum Event: Sendable, Equatable {
        case message(RelayMessage)
        /// The connection ended on its own. Nothing follows it.
        case ended(Ending)
    }

    /// Why a connection ended, which decides what happens next.
    public enum Ending: Sendable, Equatable {
        /// The relay wants the member's access checked again: connect again at once.
        case recheck
        /// GitHub refused the refresh token, or the relay got no hello: the member has to sign in again.
        case unauthorized
        /// The tenant is gone: its App was uninstalled, or its invite code withdrawn.
        case gone
        /// The network dropped, the relay failed, or the relay could not reach GitHub and
        /// left the refresh token unused: connect again after a wait.
        case failed(String)
    }

    /// How often the connection pings the relay. A Mac that slept, or changed networks, can
    /// hold a dead connection that reports no error until something is sent on it.
    static let pingInterval: Duration = .seconds(30)

    /// The connection's messages and then its ending, in the order they happened. The relay
    /// can send a session and close in the same instant, and the session's token has to be
    /// kept before the ending is acted on, so both come through this one stream. It finishes
    /// after the ending, or when `stop()` is called.
    public let events: AsyncStream<Event>

    private let task: URLSessionWebSocketTask
    private let receiving: Task<Void, Never>
    private let continuation: AsyncStream<Event>.Continuation

    /// Why a connection ended, from what the WebSocket reports.
    ///
    /// - Parameters:
    ///   - closeCode: The close code the relay sent, or 0 when it sent none.
    ///   - status: The HTTP status of the relay's answer to the connection request.
    ///   - error: What to report when the end is neither of the relay's own.
    static func ending(closeCode: Int, status: Int?, error: String) -> Ending {
        switch (closeCode, status) {
        case (4001, _): .recheck
        case (4003, _): .unauthorized
        case (4004, _), (_, 404): .gone
        // This includes 1011, which the relay sends when it could not reach GitHub.
        default: .failed(error)
        }
    }

    /// The address a tenant's connection opens: `wss://<server>/t/<tenant>/connect`.
    static func url(for tenant: RelayTenant) -> URL {
        var components = URLComponents(url: tenant.server.appending(path: "t/\(tenant.id)/connect"), resolvingAgainstBaseURL: false)!
        components.scheme = tenant.server.scheme == "http" ? "ws" : "wss"
        return components.url!
    }

    /// The connection's first frame: `{"type":"hello","refreshToken":"…"}`. The token goes
    /// here and not in a header of the connection request, because the relay's operator can
    /// see a request's address and headers but not a WebSocket's messages.
    static func hello(refreshToken: String) -> String {
        let frame = try? JSONEncoder().encode(["type": "hello", "refreshToken": refreshToken])
        return String(decoding: frame ?? Data(), as: UTF8.self)
    }

    /// Opens the connection and sends the hello.
    ///
    /// - Parameters:
    ///   - refreshToken: The member's token for this tenant. The relay replaces it in the
    ///     `RelaySession` it answers the hello with.
    public init(tenant: RelayTenant, refreshToken: String, session: URLSession = .shared) {
        let task = session.webSocketTask(with: Self.url(for: tenant))
        self.task = task
        task.resume()
        // URLSession holds the frame until the socket is open. A hello that can't be sent
        // ends the connection as a failure, which keeps the token: left open, the relay
        // would close it as unauthorized after its 60 seconds.
        task.send(.string(Self.hello(refreshToken: refreshToken))) { error in if error != nil { task.cancel() } }

        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.events = events
        self.continuation = continuation

        receiving = Task {
            let pinging = Task {
                while (try? await Task.sleep(for: Self.pingInterval)) != nil {
                    // A ping that fails ends the connection, which the receive below reports.
                    task.sendPing { error in if error != nil { task.cancel() } }
                }
            }
            defer { pinging.cancel() }

            do {
                while true {
                    switch try await task.receive() {
                    case .string(let text): RelayMessage(frame: Data(text.utf8)).map { _ = continuation.yield(.message($0)) }
                    case .data(let data): RelayMessage(frame: data).map { _ = continuation.yield(.message($0)) }
                    @unknown default: break
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                continuation.yield(.ended(Self.ending(
                    closeCode: task.closeCode.rawValue, status: (task.response as? HTTPURLResponse)?.statusCode,
                    error: error.localizedDescription
                )))
                continuation.finish()
            }
        }
    }

    /// Closes the connection. It reports no ending.
    public func stop() {
        receiving.cancel()
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }
}

/// The Keychain items that hold each tenant's refresh token.
public enum RelayKeychain {
    private static func query(_ tenant: RelayTenant) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.coderinserepeat.hermes.relay",
            kSecAttrAccount: "\(tenant.id)@\(tenant.server.host() ?? "")",
        ]
    }

    /// The member's refresh token for a tenant, or nil when they have not signed in to it.
    public static func refreshToken(for tenant: RelayTenant) -> String? {
        var item: CFTypeRef?
        let query = query(tenant).merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores a tenant's refresh token in place of the one before. Passing nil removes it.
    ///
    /// - Returns: False when the Keychain refused, which leaves the tenant without a token.
    @discardableResult
    public static func set(refreshToken: String?, for tenant: RelayTenant) -> Bool {
        SecItemDelete(query(tenant) as CFDictionary)
        guard let refreshToken else { return true }
        let item = query(tenant).merging([kSecValueData: Data(refreshToken.utf8)]) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

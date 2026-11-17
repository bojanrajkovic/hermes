import Foundation

/// One tenant of a relay: the server and the tenant's ID on it.
public struct RelayTenant: Sendable, Hashable, Codable {
    /// The hosted relay. An organization's owner can name another server at setup.
    public static let defaultServer = URL(string: "https://hermes-relay.services.coderinserepeat.com")!

    /// The relay's base URL, such as `https://relay.example.com`: lowercase scheme and host,
    /// and no trailing slash, query, or fragment, so one server has one spelling.
    public let server: URL
    /// 32 lowercase hex characters.
    public let id: String

    /// Nil when the ID is not 32 lowercase hex characters, or the server is not an `https` URL
    /// with a host. `http` is read for `localhost` and `127.0.0.1`, for a relay run on this Mac.
    public init?(server: URL, id: String) {
        guard id.count == 32, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let scheme = components.scheme?.lowercased()
        let isLocal = scheme == "http" && ["localhost", "127.0.0.1"].contains(host)
        guard scheme == "https" || isLocal else { return nil }

        // A link or a published file can spell a server's address many ways. Two tenants are
        // the same only when their servers are, so the address is kept in one form.
        components.scheme = scheme
        components.host = host
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.query = nil
        components.fragment = nil
        guard let normalized = components.url else { return nil }
        self.server = normalized
        self.id = id
    }

    /// A tenant with a new random ID.
    public init?(server: URL) {
        self.init(server: server, id: (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined())
    }

    /// The link that invites someone to this tenant: `hermes://relay.join?server=…&tenant=…`.
    public var joinLink: URL {
        // Every reserved character is escaped, so a chat app that makes links of plain text
        // does not stop at the server's `://`.
        let server = server.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "hermes://relay.join?server=\(server)&tenant=\(id)")!
    }
}

/// A `hermes://relay.…` link: one step of setting up or joining a relay tenant.
///
/// The host has a dot, which a GitHub login cannot, so these never read as `hermes://owner/repo`.
public enum RelayLink: Sendable, Hashable {
    /// Where GitHub sends the browser after the owner creates the tenant's App.
    /// `code` is redeemed for the App's secrets.
    case setup(code: String, state: String)
    /// Where the relay sends the browser after a member signs in. `grant` is exchanged for
    /// the member's refresh token.
    case session(tenantID: String, grant: String, state: String)
    /// An invitation to a tenant, which the owner hands to the members.
    case join(RelayTenant)

    /// Reads a `hermes://relay.setup`, `relay.session` or `relay.join` link. Nil for anything
    /// else, and for one that lacks a value or names a tenant `RelayTenant` refuses.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "hermes", let host = url.host()?.lowercased() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        switch host {
        case "relay.setup":
            guard let code = value("code"), let state = value("state") else { return nil }
            self = .setup(code: code, state: state)
        case "relay.session":
            guard let tenant = value("tenant"), let grant = value("grant"), let state = value("state") else { return nil }
            self = .session(tenantID: tenant, grant: grant, state: state)
        case "relay.join":
            guard let server = value("server").flatMap(URL.init(string:)), let id = value("tenant"),
                  let tenant = RelayTenant(server: server, id: id) else { return nil }
            self = .join(tenant)
        default:
            return nil
        }
    }
}

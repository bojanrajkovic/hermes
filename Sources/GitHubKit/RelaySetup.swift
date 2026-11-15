import Foundation

/// The GitHub App a tenant's owner registers, described the way GitHub's manifest flow wants.
///
/// The account owns the App, so only its owners can read the App's deliveries or make it a
/// private key. The relay's operator can do neither.
public enum RelayAppManifest {
    /// GitHub's limit on an App's name.
    static let nameLimit = 34

    /// What the App may read. Each webhook event needs one of these.
    static let permissions = [
        "pull_requests": "read", "issues": "read", "checks": "read", "statuses": "read", "members": "read", "metadata": "read",
    ]

    /// The events the App sends the relay: what changes a pull request's row or pane, and
    /// what changes who can see a repository.
    static let events = [
        "pull_request", "pull_request_review", "pull_request_review_comment", "pull_request_review_thread",
        "issue_comment", "check_suite", "check_run", "status",
        "member", "membership", "organization", "team", "team_add", "repository",
    ]

    /// The App's name: `hermes-` and the account's login, cut to GitHub's limit. Names are
    /// unique across GitHub, and the owner can change this one on GitHub's page.
    static func name(for login: String) -> String {
        var name = String("hermes-\(login)".prefix(nameLimit))
        while name.hasSuffix("-") { name.removeLast() }
        return name
    }

    /// The manifest for a tenant's App, as JSON.
    public static func json(for tenant: RelayTenant, login: String) -> Data {
        let manifest: [String: Any] = [
            "name": name(for: login),
            "url": "https://github.com/bojanrajkovic/hermes",
            "hook_attributes": ["url": tenant.server.appending(path: "hook/\(tenant.id)").absoluteString, "active": true],
            "redirect_url": "hermes://relay.setup",
            "callback_urls": [tenant.server.appending(path: "t/\(tenant.id)/callback").absoluteString],
            "public": false,
            "default_permissions": permissions,
            "default_events": events,
        ]
        // The keys are plain strings and the values are JSON types, so this cannot throw.
        return try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// GitHub's page that registers an App from a manifest, for an organization or for the
    /// viewer's own account.
    public static func registrationURL(for account: Account, state: String) -> URL {
        var components = URLComponents(string: "https://github.com")!
        components.path = account.kind == .organization ? "/organizations/\(account.login)/settings/apps/new" : "/settings/apps/new"
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        return components.url!
    }

    /// Where an owner installs the App named `slug` on their account.
    public static func installURL(slug: String) -> URL {
        URL(string: "https://github.com/apps")!.appending(path: slug).appending(path: "installations/new")
    }

    /// A web page that posts the manifest to GitHub as soon as it opens. GitHub takes a
    /// manifest only as a form post from a browser.
    public static func page(manifest: Data, action: URL) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
            <!DOCTYPE html>
            <html lang="en">
            <meta charset="utf-8">
            <title>Hermes relay setup</title>
            <body onload="document.forms[0].submit()">
            <form method="post" action="\(escaped(action.absoluteString))">
            <input type="hidden" name="manifest" value="\(escaped(String(decoding: manifest, as: UTF8.self)))">
            <button>Continue to GitHub</button>
            </form>
            </body>
            </html>
            """
    }
}

/// The App GitHub made from a manifest. The private key GitHub sends with it is not read:
/// nothing in Hermes or the relay acts as the App.
public struct RelayAppCredentials: Sendable, Equatable, Decodable {
    public let id: Int
    /// The App's name in its URLs, such as `hermes-acme`.
    public let slug: String
    public let clientID: String
    public let clientSecret: String
    public let webhookSecret: String

    private enum CodingKeys: String, CodingKey {
        case id, slug
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case webhookSecret = "webhook_secret"
    }

    /// What registers the App's tenant with the relay.
    public func registration(invite: String) -> RelayRegistration {
        RelayRegistration(invite: invite, appID: id, clientID: clientID, clientSecret: clientSecret, webhookSecret: webhookSecret)
    }
}

extension RelayAPI {
    /// Whether a code whose redemption failed with `error` can be redeemed again. GitHub takes
    /// a code once, within an hour. A request that never reached GitHub, or that GitHub
    /// failed to serve, did not use the code. A refusal did, and so did an answer Hermes
    /// could not read, because GitHub had handed the App over by then.
    public static func canRedeemAgain(after error: any Error) -> Bool {
        switch error {
        case GitHubError.http(let status, _): !(400..<500).contains(status)
        case GitHubError.decoding: false
        default: true
        }
    }

    /// Redeems the code of a `hermes://relay.setup` link for the App's secrets. GitHub takes
    /// a code once, within an hour, and asks for no sign-in.
    public func redeemManifest(code: String) async throws -> RelayAppCredentials {
        var request = URLRequest(url: URL(string: "https://api.github.com/app-manifests")!.appending(path: code).appending(path: "conversions"))
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else { throw GitHubError.http(status: status, message: "GitHub did not accept the setup code.") }
        do {
            return try JSONDecoder().decode(RelayAppCredentials.self, from: data)
        } catch {
            throw GitHubError.decoding(description: String(describing: error))
        }
    }
}

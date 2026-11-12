import Foundation

/// Someone who acts on GitHub: a person, a bot, or an organization.
public struct User: Sendable, Hashable, Decodable {
    public let login: String
    public let avatarURL: URL
    /// True for GitHub Apps such as Renovate or Dependabot.
    public let isBot: Bool

    public init(login: String, avatarURL: URL, isBot: Bool) {
        self.login = login
        self.avatarURL = avatarURL
        self.isBot = isBot
    }

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login
        case avatarURL = "avatarUrl"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        login = try container.decode(String.self, forKey: .login)
        avatarURL = try container.decode(URL.self, forKey: .avatarURL)
        isBot = try container.decode(String.self, forKey: .typename) == "Bot"
    }
}

/// An owner of repositories: the viewer's personal account or an organization
/// the viewer belongs to.
public struct Account: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case personal
        case organization
    }

    public let kind: Kind
    public let login: String
    /// The display name. Nil when the account has not set one.
    public let name: String?
    public let avatarURL: URL

    public var id: String { login }

    public init(kind: Kind, login: String, name: String?, avatarURL: URL) {
        self.kind = kind
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// The signed-in user's profile and organizations.
public struct ViewerProfile: Sendable, Hashable {
    public let login: String
    public let name: String?
    public let avatarURL: URL
    public let bio: String?
    public let company: String?
    public let location: String?
    /// The public email address. Nil when the user shows none on their profile.
    public let email: String?
    public let profileURL: URL
    /// The organizations the viewer belongs to, in GitHub's order.
    public let organizations: [Account]

    /// The personal account first, then the organizations sorted by login.
    public var accounts: [Account] {
        let personal = Account(kind: .personal, login: login, name: name, avatarURL: avatarURL)
        return [personal] + organizations.sorted { $0.login.localizedStandardCompare($1.login) == .orderedAscending }
    }

    public init(
        login: String, name: String?, avatarURL: URL, bio: String?, company: String?, location: String?,
        email: String?, profileURL: URL, organizations: [Account]
    ) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.bio = bio
        self.company = company
        self.location = location
        self.email = email
        self.profileURL = profileURL
        self.organizations = organizations
    }
}

/// A repository's owner and name.
public struct RepositoryRef: Sendable, Hashable, CustomStringConvertible {
    public let owner: String
    public let name: String

    /// `owner/name`.
    public var description: String { "\(owner)/\(name)" }

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }
}

extension RepositoryRef: Decodable {
    private enum CodingKeys: String, CodingKey { case owner, name }
    private struct Owner: Decodable { let login: String }

    /// Decodes GraphQL's `{ name owner { login } }`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decode(Owner.self, forKey: .owner).login
        name = try container.decode(String.self, forKey: .name)
    }
}

/// A label on an issue or pull request.
public struct GitHubLabel: Sendable, Hashable, Decodable {
    public let name: String
    /// Six hex digits without a leading `#`.
    public let color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

/// A repository with its open issue count.
public struct Repository: Sendable, Hashable, Identifiable {
    public let ref: RepositoryRef
    public let url: URL
    public let isPrivate: Bool
    public let openIssueCount: Int

    public var id: RepositoryRef { ref }

    public init(ref: RepositoryRef, url: URL, isPrivate: Bool, openIssueCount: Int) {
        self.ref = ref
        self.url = url
        self.isPrivate = isPrivate
        self.openIssueCount = openIssueCount
    }
}

extension Repository: Decodable {
    private enum CodingKeys: String, CodingKey { case url, isPrivate, issues }
    private struct Count: Decodable { let totalCount: Int }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try RepositoryRef(from: decoder)
        url = try container.decode(URL.self, forKey: .url)
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
        openIssueCount = try container.decode(Count.self, forKey: .issues).totalCount
    }
}

/// The viewer's permission on a repository, from GitHub's `viewerPermission`.
public enum RepositoryPermission: String, Decodable, Sendable {
    case admin = "ADMIN", maintain = "MAINTAIN", write = "WRITE", triage = "TRIAGE", read = "READ"

    /// Write or better: the repositories Hermes loads in full.
    public var canPush: Bool {
        switch self {
        case .admin, .maintain, .write: true
        case .triage, .read: false
        }
    }
}

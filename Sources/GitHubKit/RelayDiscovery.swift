import Foundation

/// How an account tells its members where its relay tenant is, without a join link: a file
/// named `hermes-relay.json` in the account's `.github-private` repository. That is the
/// repository GitHub reads an organization's member-only files from, so people outside the
/// account can't read which tenant it uses. Hermes does not look in the public `.github`.
///
/// ```json
/// {"server": "https://relay.example.com", "tenant": "0a0a…"}
/// ```
///
/// The file holds no secret. Connecting to a tenant still takes a sign-in through its App.
public enum RelayDiscovery {
    public static let fileName = "hermes-relay.json"

    /// What publishing a tenant came to.
    public enum Publication: Sendable, Equatable {
        case published
        /// The account has no `.github-private` repository. Hermes does not create one.
        case noRepository
    }

    private struct File: Codable {
        let server: URL
        let tenant: String
    }

    /// The file's contents for a tenant.
    static func file(for tenant: RelayTenant) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // A URL and a string always encode.
        return try! encoder.encode(File(server: tenant.server, tenant: tenant.id)) + Data("\n".utf8)
    }

    /// The tenant a file names. Nil for a file that is not one, or names a tenant
    /// `RelayTenant` refuses: anyone who can write to the repository can write the file.
    static func tenant(in file: Data) -> RelayTenant? {
        guard let file = try? JSONDecoder().decode(File.self, from: file) else { return nil }
        return RelayTenant(server: file.server, id: file.tenant)
    }

    static func path(for account: String) -> String {
        "/repos/\(account)/.github-private/contents/\(fileName)"
    }
}

extension GitHubClient {
    /// The relay tenant an account publishes, or nil when it publishes none: it has no
    /// `.github-private` repository the viewer can read, or no file there.
    public func publishedRelay(of account: String) async throws -> RelayTenant? {
        do {
            return RelayDiscovery.tenant(in: try await get(RelayDiscovery.path(for: account), accept: "application/vnd.github.raw+json"))
        } catch GitHubError.http(status: 404, _) {
            return nil
        }
    }

    /// Commits a tenant's file to the default branch of the account's `.github-private` repository,
    /// in place of one that is there.
    ///
    /// - Throws: `GitHubError.http` with GitHub's reason when it refuses the commit, such as
    ///   a branch that takes changes only through pull requests.
    public func publishRelay(_ tenant: RelayTenant, for account: String) async throws -> RelayDiscovery.Publication {
        struct Existing: Decodable { let sha: String }
        struct Commit: Encodable {
            let message: String
            let content: String
            /// The file being replaced. GitHub refuses to overwrite a file without it.
            let sha: String?
        }

        do {
            _ = try await get("/repos/\(account)/.github-private")
        } catch GitHubError.http(status: 404, _) {
            return .noRepository
        }

        var existing: Existing?
        do {
            existing = try await get(RelayDiscovery.path(for: account), as: Existing.self)
        } catch GitHubError.http(status: 404, _) {}

        try await put(RelayDiscovery.path(for: account), body: Commit(
            message: "Publish the Hermes relay tenant",
            content: RelayDiscovery.file(for: tenant).base64EncodedString(), sha: existing?.sha
        ))
        return .published
    }
}

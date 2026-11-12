import Foundation

/// How a pull request's commits land on its base branch.
public enum MergeMethod: String, Sendable, Hashable, CaseIterable, Decodable {
    case merge = "MERGE"
    case squash = "SQUASH"
    case rebase = "REBASE"

    /// The name GitHub uses on its merge button.
    public var title: String {
        switch self {
        case .merge: "Create a Merge Commit"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase and Merge"
        }
    }
}

/// What GitHub says about merging a pull request right now.
public enum MergeStateStatus: String, Sendable, Hashable, Decodable {
    /// The head branch is behind the base and the repository requires it up to date.
    case behind = "BEHIND"
    /// A required review or check is missing.
    case blocked = "BLOCKED"
    case clean = "CLEAN"
    /// Merge conflicts.
    case dirty = "DIRTY"
    case draft = "DRAFT"
    /// Mergeable, with pre-receive hooks that still run.
    case hasHooks = "HAS_HOOKS"
    /// GitHub has not computed it yet.
    case unknown = "UNKNOWN"
    /// Mergeable, with a check that is not required failing or pending.
    case unstable = "UNSTABLE"
}

/// Whether the viewer can merge a pull request, and how.
public struct MergeReadiness: Sendable, Hashable {
    public let state: MergeStateStatus
    /// The methods the repository allows, in GitHub's order.
    public let allowedMethods: [MergeMethod]
    /// The method GitHub preselects for the viewer. One of `allowedMethods` when that is not empty.
    public let defaultMethod: MergeMethod
    /// Whether the viewer may push to the repository.
    public let viewerCanPush: Bool
    /// GitHub reports a draft as `clean`, so this is checked on its own.
    public let isDraft: Bool
    /// Whether the viewer may merge past unmet requirements, GitHub's
    /// `viewerCanMergeAsAdmin`: its "bypass rules" checkbox.
    public let viewerCanBypass: Bool

    public init(
        state: MergeStateStatus, allowedMethods: [MergeMethod], defaultMethod: MergeMethod, viewerCanPush: Bool,
        isDraft: Bool = false, viewerCanBypass: Bool = false
    ) {
        self.state = state
        self.isDraft = isDraft
        self.viewerCanBypass = viewerCanBypass
        self.allowedMethods = allowedMethods
        self.defaultMethod = defaultMethod
        self.viewerCanPush = viewerCanPush
    }

    /// Why the pull request cannot be merged now. `nil` when it can.
    public var blocker: String? {
        guard viewerCanPush else { return "You don't have permission to merge in this repository." }
        guard !allowedMethods.isEmpty else { return "This repository allows no merge method." }
        guard !isDraft else { return "The pull request is a draft." }
        switch state {
        case .clean, .hasHooks, .unstable: return nil
        case .behind: return "The branch is behind its base and must be updated first."
        case .blocked: return "A required review or check is missing."
        case .dirty: return "The branch has merge conflicts."
        case .draft: return "The pull request is a draft."
        case .unknown: return "GitHub is still working out whether this can merge."
        }
    }

    public var canMerge: Bool { blocker == nil }

    /// Whether the viewer can merge anyway, past a missing review or check or a
    /// branch behind its base. Never past conflicts, a draft, or missing permission:
    /// GitHub lets nobody bypass those.
    public var canBypass: Bool {
        guard viewerCanBypass, viewerCanPush, !allowedMethods.isEmpty, !isDraft else { return false }
        return state == .blocked || state == .behind
    }
}

private struct MergeReadinessData: Decodable, Sendable {
    struct Repository: Decodable, Sendable {
        struct PullRequest: Decodable, Sendable {
            let mergeStateStatus: MergeStateStatus
            let isDraft: Bool
            let viewerCanMergeAsAdmin: Bool
        }
        let mergeCommitAllowed: Bool
        let squashMergeAllowed: Bool
        let rebaseMergeAllowed: Bool
        let viewerDefaultMergeMethod: MergeMethod
        let viewerPermission: String?
        let pullRequest: PullRequest
    }
    let repository: Repository
}

private struct MergeResult: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        struct PullRequest: Decodable, Sendable { let merged: Bool }
        let pullRequest: PullRequest
    }
    let mergePullRequest: Payload
}

extension GitHubClient {
    /// Loads whether a pull request can be merged now and which methods its repository allows.
    public func mergeReadiness(repository: RepositoryRef, number: Int) async throws -> MergeReadiness {
        let query = """
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed viewerDefaultMergeMethod viewerPermission
                pullRequest(number: $number) { mergeStateStatus isDraft viewerCanMergeAsAdmin }
              }
            }
            """
        let data = try await graphQL(
            query,
            variables: ["owner": .string(repository.owner), "name": .string(repository.name), "number": .int(number)],
            as: MergeReadinessData.self
        ).repository
        let allowed = [
            data.mergeCommitAllowed ? MergeMethod.merge : nil,
            data.squashMergeAllowed ? .squash : nil,
            data.rebaseMergeAllowed ? .rebase : nil,
        ].compactMap { $0 }
        return MergeReadiness(
            state: data.pullRequest.mergeStateStatus,
            allowedMethods: allowed,
            defaultMethod: allowed.contains(data.viewerDefaultMergeMethod) ? data.viewerDefaultMergeMethod : allowed.first ?? .merge,
            viewerCanPush: ["ADMIN", "MAINTAIN", "WRITE"].contains(data.viewerPermission ?? ""),
            isDraft: data.pullRequest.isDraft,
            viewerCanBypass: data.pullRequest.viewerCanMergeAsAdmin
        )
    }

    /// Merges one pull request that is not part of a stack. When the viewer can
    /// bypass the repository's rules, GitHub merges past unmet requirements.
    ///
    /// - Parameters:
    ///   - pullRequestID: The GraphQL node ID.
    ///   - expectedHeadOID: The head commit the user looked at. GitHub refuses
    ///     the merge when the branch has moved on since.
    /// - Throws: `GitHubError.graphQL` with GitHub's reason when the merge is refused.
    public func mergePullRequest(pullRequestID: String, method: MergeMethod, expectedHeadOID: String) async throws {
        let query = """
            mutation($input: MergePullRequestInput!) { mergePullRequest(input: $input) { pullRequest { merged } } }
            """
        let input: [String: JSONValue] = [
            "pullRequestId": .string(pullRequestID),
            "mergeMethod": .string(method.rawValue),
            "expectedHeadOid": .string(expectedHeadOID),
        ]
        _ = try await graphQL(query, variables: ["input": .object(input)], as: MergeResult.self)
    }

    /// Merges a stack from its bottom up to and including one pull request,
    /// all or nothing, with the `gh stack` extension. GitHub refuses the
    /// ordinary merge call for a stacked pull request.
    ///
    /// - Throws: `GitHubError.ghNotInstalled` when `gh` is missing, or
    ///   `GitHubError.commandFailed` with what `gh stack merge` printed when it fails.
    public nonisolated func mergeStack(repository: RepositoryRef, upTo number: Int, method: MergeMethod) async throws {
        guard let gh = await GitHubAuth.locateGH() else { throw GitHubError.ghNotInstalled }
        let result = try await GitHubAuth.run(
            gh, ["stack", "merge", String(number), "--yes", "--merge-method", method.rawValue.lowercased()],
            // The extension reads the repository from its working directory unless this is set.
            environment: ["GH_REPO": repository.description],
            timeout: 180
        )
        guard result.status == 0 else {
            let output = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubError.commandFailed(message: output.isEmpty ? "gh stack merge failed." : output)
        }
    }
}

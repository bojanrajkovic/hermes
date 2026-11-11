import Foundation

/// A working directory attached to a checkout.
public struct Worktree: Hashable, Sendable {
    /// The worktree's root directory.
    public let directory: URL
    /// Full object ID of its `HEAD` commit.
    public let oid: String
    /// The checked-out branch's short name, or `nil` when `HEAD` is detached.
    public let branch: String?
    /// Whether this is the checkout's main working copy rather than a linked worktree.
    public let isMain: Bool
}

/// Which branch a new worktree checks out.
public enum WorktreeBranch: Hashable, Sendable {
    /// A branch that exists on the checkout's remote, such as a pull
    /// request's head branch. It is fetched first. A local branch of the same
    /// name is reused and fast-forwarded to the remote's tip, or left as it is
    /// when it has commits the remote lacks. Otherwise a branch is created
    /// that tracks `<remote>/<name>`.
    case existing(String)
    /// A new branch created from the tip of the remote's default branch.
    case new(String)

    /// The branch's short name.
    public var name: String {
        switch self {
        case let .existing(name), let .new(name): name
        }
    }
}

/// The user's local clone of a repository. Operations add and remove linked
/// worktrees and read branches. None of them changes the main working copy's
/// checked-out branch, index, or files.
public struct Checkout: Hashable, Sendable {
    /// `~/Library/Application Support/Hermes/worktrees`.
    public static var defaultWorktreesRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Hermes/worktrees", directoryHint: .isDirectory)
    }

    /// The repository on GitHub that this checkout's remote points at.
    public let repo: RepoID
    /// The main working copy's root directory.
    public let directory: URL
    /// Name of the git remote that points at `repo`. In a clone of a fork this
    /// is often `upstream` rather than `origin`.
    public let remote: String

    public init(repo: RepoID, directory: URL, remote: String = "origin") {
        self.repo = repo
        self.directory = directory
        self.remote = remote
    }

    /// Lists the checkout's worktrees, main working copy first. A bare
    /// repository entry is left out.
    public func worktrees() async throws -> [Worktree] {
        let output = try await Git.run(["worktree", "list", "--porcelain", "-z"], in: directory)
        return parseWorktrees(output.text)
    }

    /// Creates a linked worktree at `<root>/<owner>/<name>/<branch>`, with
    /// `/` in the branch name replaced by `-` so worktrees never nest.
    ///
    /// The fetch needs the network for `.existing`. For `.new` a failed fetch
    /// is ignored and the branch starts from the last known default branch.
    ///
    /// - Parameters:
    ///   - branch: The branch to check out in the new worktree.
    ///   - root: Directory that holds worktrees Hermes creates.
    /// - Returns: The new worktree.
    /// - Throws: `GitError.failed` if the branch is missing on the remote, is
    ///   already checked out in another worktree, or (for `.new`) already
    ///   exists; `GitError.noDefaultBranch` if `.new` has nothing to start from.
    public func addWorktree(branch: WorktreeBranch, root: URL = Checkout.defaultWorktreesRoot) async throws -> Worktree {
        let name = branch.name
        let target = root.appending(
            path: "\(repo.owner)/\(repo.name)/\(name.replacingOccurrences(of: "/", with: "-"))",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch branch {
        case .existing:
            try await fetchBranch(name)
            if try await Git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: directory) {
                try await Git.run(["worktree", "add", target.path, name], in: directory)
                // Fails, and is left alone, when the branch has commits the remote lacks.
                _ = try await Git.succeeds(["merge", "--ff-only", "--quiet", "\(remote)/\(name)"], in: target)
            } else {
                try await Git.run(["worktree", "add", "--track", "-b", name, target.path, "\(remote)/\(name)"], in: directory)
            }
        case .new:
            let start = try await Git.defaultBranch(in: directory, remote: remote)
            if start.ref.hasPrefix("\(remote)/") {
                try? await fetchBranch(start.name)
            }
            try await Git.run(["worktree", "add", "--no-track", "-b", name, target.path, start.ref], in: directory)
        }

        let head = try await WorkingTree(directory: target).head()
        return Worktree(directory: target, oid: head.oid, branch: head.branch, isMain: false)
    }

    /// Removes a linked worktree. Its branch is kept.
    ///
    /// - Parameters:
    ///   - worktree: The worktree's root directory.
    ///   - force: Remove it even with uncommitted or untracked files, which are lost.
    /// - Throws: `GitError.failed` if the worktree has uncommitted changes and
    ///   `force` is false, or if it is the main working copy.
    public func removeWorktree(at worktree: URL, force: Bool = false) async throws {
        try await Git.run(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path], in: directory)
    }

    /// Fetches a branch from the remote into `<remote>/<name>`, so that ref
    /// can be diffed against. Needs the network.
    ///
    /// - Parameter name: The branch's short name, such as a pull request's base branch.
    /// - Throws: `GitError.failed` if the branch is missing on the remote or the fetch fails.
    public func fetchBranch(_ name: String) async throws {
        try await fetch("+refs/heads/\(name):refs/remotes/\(remote)/\(name)")
    }

    private func fetch(_ refspec: String) async throws {
        try await Git.run(
            Git.authArguments(replacingHelpers: false) + ["fetch", "--quiet", "--no-tags", remote, refspec],
            in: directory
        )
    }
}

/// Parses `git worktree list --porcelain -z`: NUL-terminated `key value`
/// attributes, with an empty attribute between worktrees.
func parseWorktrees(_ output: String) -> [Worktree] {
    var worktrees: [Worktree] = []
    var isFirst = true
    for record in output.components(separatedBy: "\0\0") {
        var attributes: [String: String] = [:]
        for attribute in record.split(separator: "\0") {
            let pair = attribute.split(separator: " ", maxSplits: 1)
            guard let key = pair.first else { continue }
            attributes[String(key)] = pair.count > 1 ? String(pair[1]) : ""
        }
        guard let path = attributes["worktree"] else { continue }
        defer { isFirst = false }
        guard let oid = attributes["HEAD"], attributes["bare"] == nil else { continue }

        let branch = attributes["branch"].map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
        worktrees.append(Worktree(
            directory: URL(fileURLWithPath: path, isDirectory: true), oid: oid, branch: branch, isMain: isFirst
        ))
    }
    return worktrees
}

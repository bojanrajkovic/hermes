import Foundation

/// Bare clones of GitHub repositories, kept so the app can read files at a
/// pull request's head commit without a working copy.
///
/// Each repository lives at `<root>/<owner>/<name>.git`. Clones are shallow:
/// only the commits the app asks for are fetched. Calls for the same
/// repository run one at a time; calls for different repositories run
/// concurrently.
public actor RepoCache {
    /// `~/Library/Caches/Hermes/repos`.
    public static var defaultRoot: URL {
        URL.cachesDirectory.appending(path: "Hermes/repos", directoryHint: .isDirectory)
    }

    private let root: URL
    private let remoteURL: @Sendable (RepoID) -> String
    private var tails: [String: Task<Void, Never>] = [:]

    /// - Parameter root: Directory that holds the clones. Created on first use.
    public init(root: URL = RepoCache.defaultRoot) {
        self.init(root: root) { "https://github.com/\($0.owner)/\($0.name).git" }
    }

    /// Tests point the cache at local repositories instead of github.com.
    init(root: URL, remoteURL: @escaping @Sendable (RepoID) -> String) {
        self.root = root
        self.remoteURL = remoteURL
    }

    /// Makes a pull request's commit readable, cloning and fetching as needed.
    ///
    /// Fetches `pull/<number>/head` at depth 1. If the pull request has moved
    /// past `oid`, fetches `oid` itself. Does nothing over the network when
    /// the commit is already in the cache.
    ///
    /// - Parameters:
    ///   - repo: The repository the pull request targets.
    ///   - pullRequestNumber: The pull request's number.
    ///   - oid: Full object ID of the commit to read.
    /// - Returns: The commit as a `SourceTree`.
    /// - Throws: `GitError.commitUnavailable` if the remote does not serve
    ///   `oid`; `GitError.failed` for network and authentication failures.
    public func ensureCommit(repo: RepoID, pullRequestNumber: Int, oid: String) async throws -> CommitTree {
        let (directory, remote) = (directory(for: repo), remoteURL(repo))
        return try await serialized(repo) {
            try await Self.prepare(directory)
            let tree = CommitTree(gitDirectory: directory, oid: oid)
            if try await Self.hasCommit(oid, in: directory) { return tree }

            try await Self.fetch(["--depth=1", remote, Self.headRefspec(pullRequestNumber)], in: directory)
            if try await Self.hasCommit(oid, in: directory) { return tree }

            // The pull request moved on; ask for the commit by ID.
            _ = try? await Self.fetch(["--depth=1", remote, oid], in: directory)
            guard try await Self.hasCommit(oid, in: directory) else { throw GitError.commitUnavailable(oid: oid) }
            return tree
        }
    }

    /// Computes a pull request's diff locally, for when GitHub refuses to
    /// serve a large one. Equivalent to `git diff base...head`: the changes on
    /// the head since it diverged from the base branch.
    ///
    /// Fetches the base branch and the pull request head, deepening history
    /// until their merge base is found.
    ///
    /// - Parameters:
    ///   - repo: The repository the pull request targets.
    ///   - pullRequestNumber: The pull request's number.
    ///   - baseRef: Name of the base branch, such as `main`.
    ///   - headOid: Full object ID of the head commit to diff.
    /// - Returns: Unified diff text with renames detected.
    /// - Throws: `GitError.commitUnavailable` if `headOid` cannot be fetched;
    ///   `GitError.failed` if the branches share no history or git fails.
    public func diff(repo: RepoID, pullRequestNumber: Int, baseRef: String, headOid: String) async throws -> String {
        let (directory, remote) = (directory(for: repo), remoteURL(repo))
        return try await serialized(repo) {
            try await Self.prepare(directory)
            let base = "refs/hermes/base/\(baseRef)"
            let refspecs = [remote, "+refs/heads/\(baseRef):\(base)", Self.headRefspec(pullRequestNumber)]

            func mergeBaseKnown() async throws -> Bool {
                try await Git.succeeds(["merge-base", base, headOid], in: directory)
            }

            // shortcut: a merge base found in shallow history can differ from the
            // true one in criss-cross merges; fetch full history if that shows up.
            // A depth on a later fetch would cut history back to 50 commits and
            // drop a merge base that an earlier call deepened to. Without one,
            // git keeps the shallow boundary where it is.
            let depth = try await Git.succeeds(["show-ref", "--verify", "--quiet", base], in: directory) ? [] : ["--depth=50"]
            try await Self.fetch(depth + refspecs, in: directory)
            if try await !Self.hasCommit(headOid, in: directory) {
                _ = try? await Self.fetch(depth + [remote, headOid], in: directory)
                guard try await Self.hasCommit(headOid, in: directory) else {
                    throw GitError.commitUnavailable(oid: headOid)
                }
            }
            for step in [200, 1000, 5000] where try await !mergeBaseKnown() {
                try await Self.fetch(["--deepen=\(step)"] + refspecs, in: directory)
            }
            if try await !mergeBaseKnown(),
               try await Git.run(["rev-parse", "--is-shallow-repository"], in: directory).trimmed == "true" {
                try await Self.fetch(["--unshallow"] + refspecs, in: directory)
            }
            return try await Git.run(Git.diffArguments + ["\(base)...\(headOid)"], in: directory).text
        }
    }

    private func directory(for repo: RepoID) -> URL {
        root.appending(path: "\(repo.owner)/\(repo.name).git", directoryHint: .isDirectory)
    }

    /// Runs `body` after every earlier call for the same repository finishes,
    /// so two fetches never write the same clone at once.
    private func serialized<T: Sendable>(_ repo: RepoID, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tails[repo.key]
        let task = Task {
            await previous?.value
            return try await body()
        }
        tails[repo.key] = Task { _ = try? await task.value }
        // The work runs in its own task, so the caller's cancellation is passed on by hand.
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func headRefspec(_ number: Int) -> String {
        "+refs/pull/\(number)/head:refs/hermes/pull/\(number)"
    }

    /// Creates the bare repository if it does not exist. Nothing is downloaded
    /// here; fetches bring in only the commits that are asked for. Fetches name
    /// the URL, so the clone has no configured remote that could be missing.
    private static func prepare(_ directory: URL) async throws {
        guard !FileManager.default.fileExists(atPath: directory.appending(path: "HEAD").path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Git.run(["init", "--bare", "--quiet"], in: directory)
    }

    private static func hasCommit(_ oid: String, in directory: URL) async throws -> Bool {
        try await Git.succeeds(["cat-file", "-e", "\(oid)^{commit}"], in: directory)
    }

    private static func fetch(_ arguments: [String], in directory: URL) async throws {
        try await Git.run(
            Git.authArguments(replacingHelpers: true) + ["fetch", "--quiet", "--no-tags"] + arguments,
            in: directory
        )
    }
}

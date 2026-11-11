import Foundation

/// A working directory on disk: a checkout's main working copy or one of its
/// linked worktrees. Every operation only reads it.
public struct WorkingTree: SourceTree, Hashable {
    /// What `HEAD` points at.
    public struct Head: Hashable, Sendable {
        /// The checked-out branch's short name, or `nil` when `HEAD` is detached.
        public let branch: String?
        /// Full object ID of the `HEAD` commit.
        public let oid: String
    }

    /// The worktree's root directory.
    public let directory: URL

    /// - Parameter directory: The worktree's root, not a subdirectory of it.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Reads the current branch and commit.
    ///
    /// - Throws: `GitError.failed` if the directory is not a git worktree or has no commits.
    public func head() async throws -> Head {
        let oid = try await Git.run(["rev-parse", "HEAD"], in: directory).trimmed
        let branch = try await Git.run(["symbolic-ref", "--short", "-q", "HEAD"], in: directory, accepting: [0, 1])
        return Head(branch: branch.status == 0 ? branch.trimmed : nil, oid: oid)
    }

    /// The worktree's changes since it diverged from `baseRef`: commits on the
    /// branch plus staged, unstaged, and untracked files. Untracked files
    /// appear as added files; ignored files are left out.
    ///
    /// - Parameter baseRef: A ref or commit to compare with, such as `origin/main`.
    /// - Returns: Unified diff text with renames detected.
    /// - Throws: `GitError.failed` if `baseRef` does not exist or shares no history with `HEAD`.
    public func diff(against baseRef: String) async throws -> String {
        let mergeBase = try await Git.run(["merge-base", baseRef, "HEAD"], in: directory).trimmed

        // `git diff` skips untracked files. Marking them "intent to add" makes
        // it show them. That is done in a copy of the index, so the user's
        // staging area is not changed.
        let index = try await Git.run(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: directory).trimmed
        let scratch = FileManager.default.temporaryDirectory.appending(path: "hermes-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Read and write rather than copyItem: an APFS clone raises a file event
        // on the source, which the change watcher would report as an index change.
        try? Data(contentsOf: URL(fileURLWithPath: index)).write(to: scratch)
        let environment = ["GIT_INDEX_FILE": scratch.path]

        try await Git.run(["add", "--intent-to-add", "--", ":/"], in: directory, environment: environment)
        return try await Git.run(Git.diffArguments + [mergeBase], in: directory, environment: environment).text
    }

    public func readFile(_ path: String) async throws -> String {
        let root = directory.standardizedFileURL.path
        let file = directory.appending(path: path).standardizedFileURL
        guard file.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { throw GitError.pathOutsideTree(path) }
        return String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }

    public func listFiles() async throws -> [String] {
        try await Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: directory).nulSeparated
    }

    public func grep(word: String) async throws -> [GrepMatch] {
        guard !word.isEmpty else { return [] }
        let output = try await Git.run(grepArguments(word: word, extra: ["--untracked"]), in: directory, accepting: [0, 1])
        return parseGrep(output.text)
    }
}

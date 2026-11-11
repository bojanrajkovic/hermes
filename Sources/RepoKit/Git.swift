import Foundation

/// A GitHub repository, identified by owner and name.
public struct RepoID: Hashable, Sendable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Parses a github.com remote URL in any of the forms git accepts:
    /// `git@github.com:owner/name.git`, `ssh://git@github.com/owner/name`,
    /// and `https://github.com/owner/name.git`. The `.git` suffix and a
    /// trailing slash are optional. Returns `nil` for other hosts or shapes.
    public init?(remoteURL: String) {
        var rest = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
        } else if let colon = rest.firstIndex(of: ":") {
            // scp-like form: [user@]host:path
            rest.replaceSubrange(colon...colon, with: "/")
        } else {
            return nil
        }
        if let at = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }

        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        let host = parts[0].split(separator: ":")[0].lowercased()
        guard host == "github.com" || host == "ssh.github.com" else { return nil }
        let name = parts[2].hasSuffix(".git") ? String(parts[2].dropLast(4)) : String(parts[2])
        guard !name.isEmpty else { return nil }
        self.init(owner: String(parts[1]), name: name)
    }

    public var description: String { "\(owner)/\(name)" }

    /// GitHub treats owner and name case-insensitively, so lookups use this key.
    var key: String { description.lowercased() }
}

/// An error from running `git`.
public enum GitError: Error, Sendable, Equatable, LocalizedError {
    /// No `git` binary exists at /usr/bin, /opt/homebrew/bin, or /usr/local/bin.
    case gitNotFound
    /// `git` exited with a status the caller did not expect.
    case failed(arguments: [String], status: Int32, stderr: String)
    /// The commit is not on the remote, or is not reachable from the pull request.
    case commitUnavailable(oid: String)
    /// The checkout's remote has no `HEAD`, and there is no `main` or `master` to treat as the default branch.
    case noDefaultBranch
    /// The path points outside the tree it was read from.
    case pathOutsideTree(String)

    public var errorDescription: String? {
        switch self {
        case .gitNotFound:
            "git is not installed."
        case let .failed(arguments, status, stderr):
            "git \(arguments.first ?? "") failed (exit \(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .commitUnavailable(oid):
            "Commit \(oid) could not be fetched."
        case .noDefaultBranch:
            "The checkout has no default branch."
        case let .pathOutsideTree(path):
            "\(path) is outside the tree."
        }
    }
}

/// Runs `git` as a child process. A GUI app starts with a minimal PATH, so the
/// binaries are found by absolute path.
enum Git {
    struct Output: Sendable {
        let stdout: Data
        let stderr: String
        let status: Int32

        var text: String { String(decoding: stdout, as: UTF8.self) }
        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        /// NUL-separated fields, as printed by `-z` flags.
        var nulSeparated: [String] { text.split(separator: "\0").map(String.init) }
    }

    private static let searchDirectories = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    static let gitURL: URL? = firstExecutable("git", in: searchDirectories)

    /// `gh` is often installed by a version manager, so the user's PATH and the
    /// mise shim directory are searched after the standard locations.
    static let ghURL: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return firstExecutable("gh", in: searchDirectories + ["\(home)/.local/bin", "\(home)/.local/share/mise/shims"] + path)
    }()

    private static func firstExecutable(_ name: String, in directories: [String]) -> URL? {
        directories.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Arguments that let git authenticate to github.com over HTTPS with the
    /// token `gh` holds. Empty when `gh` is not installed, which still works
    /// for public repositories.
    ///
    /// - Parameter replacingHelpers: Drop the helpers from the user's git
    ///   config first, so the macOS keychain helper cannot prompt or supply a
    ///   stale password.
    static func authArguments(replacingHelpers: Bool) -> [String] {
        guard let gh = ghURL else { return [] }
        let quoted = "'" + gh.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return (replacingHelpers ? ["-c", "credential.helper="] : [])
            + ["-c", "credential.https://github.com.helper=!\(quoted) auth git-credential"]
    }

    private static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        for inherited in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] { env[inherited] = nil }
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Read commands must not rewrite the index: the change watcher would
        // see the write and trigger another read.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["PATH"] = ([env["PATH"]].compactMap { $0 } + searchDirectories + ["/bin"]).joined(separator: ":")
        return env
    }()

    /// Runs `git` and returns its output.
    ///
    /// - Parameters:
    ///   - arguments: Arguments after `git`.
    ///   - directory: Working directory, or `nil` for the current one.
    ///   - environment: Variables added to the inherited environment.
    ///   - accepting: Exit statuses that are not errors. Commands like
    ///     `git grep` use status 1 for "nothing found".
    /// - Throws: `GitError.gitNotFound`, or `GitError.failed` for any other exit status.
    @discardableResult
    static func run(
        _ arguments: [String],
        in directory: URL?,
        environment extra: [String: String] = [:],
        accepting: Set<Int32> = [0]
    ) async throws -> Output {
        guard let git = gitURL else { throw GitError.gitNotFound }
        // onCancel below cannot stop a process that has not launched yet.
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = git
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = directory
        process.environment = environment.merging(extra) { _, new in new }
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let child = process
        let output: Output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do { try child.run() } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    // Both pipes are drained at once, or a full stderr pipe would block git.
                    nonisolated(unsafe) var errorData = Data()
                    let group = DispatchGroup()
                    DispatchQueue.global().async(group: group) {
                        errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    }
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    child.waitUntilExit()
                    continuation.resume(returning: Output(
                        stdout: data,
                        stderr: String(decoding: errorData, as: UTF8.self),
                        status: child.terminationStatus
                    ))
                }
            }
        } onCancel: {
            // terminate() raises if the process has not launched yet.
            if child.isRunning { child.terminate() }
        }

        try Task.checkCancellation()
        guard accepting.contains(output.status) else {
            throw GitError.failed(arguments: arguments, status: output.status, stderr: output.stderr)
        }
        return output
    }

    /// `git diff` with rename detection, in the one format DiffKit parses.
    /// The flags undo user configuration that changes the output:
    /// `diff.noprefix`, `diff.mnemonicPrefix`, `diff.external`, `color.ui=always`,
    /// textconv filters, and `diff.submodule`.
    static let diffArguments = [
        "diff", "-M", "--no-color", "--no-ext-diff", "--no-textconv",
        "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short",
    ]

    /// Whether `git` exits 0 for these arguments. Used for existence checks.
    static func succeeds(_ arguments: [String], in directory: URL) async throws -> Bool {
        try await run(arguments, in: directory, accepting: [0, 1, 128]).status == 0
    }

    /// The checkout's default branch: its short name, and the ref to read it
    /// from. `<remote>/<name>` is preferred because the local branch may be stale.
    static func defaultBranch(in directory: URL, remote: String) async throws -> (name: String, ref: String) {
        let remoteHead = try await run(
            ["symbolic-ref", "--short", "-q", "refs/remotes/\(remote)/HEAD"], in: directory, accepting: [0, 1, 128]
        )
        if remoteHead.status == 0, remoteHead.trimmed.hasPrefix("\(remote)/") {
            return (String(remoteHead.trimmed.dropFirst(remote.count + 1)), remoteHead.trimmed)
        }
        for name in ["main", "master"] {
            for ref in ["\(remote)/\(name)", name] where try await succeeds(["rev-parse", "--verify", "-q", "\(ref)^{commit}"], in: directory) {
                return (name, ref)
            }
        }
        throw GitError.noDefaultBranch
    }
}

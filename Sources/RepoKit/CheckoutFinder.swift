import Foundation

/// Finds the user's existing clone of a repository by looking at the git
/// remotes of directories under the search roots.
///
/// A root is scanned two levels deep, so both `~/Projects/<repo>` and
/// `~/Projects/<group>/<repo>` are found. Linked worktrees are not candidates;
/// only directories that hold a `.git` directory are. The scan runs once and
/// its result is kept until `rescan()`.
public actor CheckoutFinder {
    /// `~/Projects`.
    public static var defaultRoots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projects", directoryHint: .isDirectory)]
    }

    private let roots: [URL]
    private var scan: Task<[String: Checkout], Never>?

    /// - Parameter roots: Directories to search. Missing ones are skipped.
    public init(roots: [URL] = CheckoutFinder.defaultRoots) {
        self.roots = roots
    }

    /// Returns the checkout that has a remote pointing at `repo` on
    /// github.com, or `nil` if there is none. When several match, the one with
    /// the shortest path wins, then the alphabetically first. The result's
    /// `remote` names the matching remote, which is not always `origin`.
    public func checkout(for repo: RepoID) async -> Checkout? {
        if scan == nil {
            let roots = roots
            scan = Task { await Self.scan(roots) }
        }
        return await scan?.value[repo.key]
    }

    /// Forgets the cached scan, so the next lookup reads the disk again.
    public func rescan() {
        scan = nil
    }

    private static func scan(_ roots: [URL]) async -> [String: Checkout] {
        let candidates = roots.flatMap(repositories(under:)).sorted {
            ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path)
        }
        var found: [String: Checkout] = [:]
        for directory in candidates {
            // `git remote -v` prints URLs after `url.<base>.insteadOf` rewrites.
            let remotes = try? await Git.run(["remote", "-v"], in: directory)
            for (name, repo) in parseRemotes(remotes?.text ?? "") where found[repo.key] == nil {
                found[repo.key] = Checkout(repo: repo, directory: directory, remote: name)
            }
        }
        return found
    }

    /// Directories one or two levels below `root` that contain a `.git` directory.
    private static func repositories(under root: URL) -> [URL] {
        func isRepository(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.appending(path: ".git").path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        func subdirectories(_ url: URL) -> [URL] {
            let children = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
            return (children ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return subdirectories(root).flatMap { child in
            isRepository(child) ? [child] : subdirectories(child).filter(isRepository)
        }
    }
}

/// Parses `git remote -v` (`<name> TAB <url> (fetch)` lines) into the remotes
/// whose fetch URL is a github.com repository.
func parseRemotes(_ output: String) -> [(name: String, repo: RepoID)] {
    output.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: "\t", maxSplits: 1)
        guard fields.count == 2, fields[1].hasSuffix(" (fetch)"),
              let repo = RepoID(remoteURL: String(fields[1].dropLast(" (fetch)".count))) else { return nil }
        return (String(fields[0]), repo)
    }
}

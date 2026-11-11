import CryptoKit
import DiffKit
import Foundation
import GitHubKit
import RepoKit

extension DiffSource {
    /// Identifies what is shown, ignoring fields that change as a pull request
    /// is refreshed (title, update time, head commit). The screen keeps its
    /// state for as long as this stays the same.
    var key: String {
        switch self {
        case .pullRequest(let pullRequest): "pr:\(pullRequest.repository)#\(pullRequest.number)"
        case .workingTree(let directory, let baseRef): "tree:\(directory.path):\(baseRef)"
        case .localBranch(let checkout, let branch): "branch:\(checkout.directory.path):\(branch.parent)...\(branch.name)"
        }
    }
}

/// Fetches diffs and file text for a ``DiffSource``. Nothing here touches the main actor.
enum DiffLoader {
    struct Fetched: Sendable {
        let text: String
        /// The pull request's head commit that `text` belongs to. `nil` for local sources.
        let head: String?
        /// When GitHub last recorded activity on the pull request, read before the diff. `nil` for local sources.
        var updatedAt: Date?
    }

    /// Loads the source's unified diff text.
    ///
    /// A pull request's diff comes from GitHub. When GitHub refuses a large
    /// diff, it is computed in the repository cache instead.
    static func fetch(_ source: DiffSource, client: GitHubClient, repoCache: RepoCache) async throws -> Fetched {
        switch source {
        case .pullRequest(let pullRequest):
            let repository = pullRequest.repository
            let revision = try await client.pullRequestRevision(repository: repository, number: pullRequest.number)
            let head = revision.headOID
            do {
                let text = try await client.pullRequestDiff(repository: repository, number: pullRequest.number)
                return Fetched(text: text, head: head, updatedAt: revision.updatedAt)
            } catch GitHubError.diffTooLarge {
                let text = try await repoCache.diff(
                    repo: RepoID(owner: repository.owner, name: repository.name), pullRequestNumber: pullRequest.number,
                    baseRef: pullRequest.baseRefName, headOid: head
                )
                return Fetched(text: text, head: head, updatedAt: revision.updatedAt)
            }
        case .workingTree(let directory, let baseRef):
            return Fetched(text: try await WorkingTree(directory: directory).diff(against: baseRef), head: nil)
        case .localBranch(let checkout, let branch):
            return Fetched(text: try await checkout.diff(of: branch), head: nil)
        }
    }

    /// The files at the diff's new side, for context expansion.
    ///
    /// A pull request's head commit is fetched into the repository cache,
    /// which can take a while. A local branch is readable only while one of
    /// the checkout's worktrees has it checked out.
    static func tree(for source: DiffSource, head: String?, repoCache: RepoCache) async throws -> (any SourceTree)? {
        switch source {
        case .pullRequest(let pullRequest):
            guard let head else { return nil }
            let repo = RepoID(owner: pullRequest.repository.owner, name: pullRequest.repository.name)
            return try await repoCache.ensureCommit(repo: repo, pullRequestNumber: pullRequest.number, oid: head)
        case .workingTree(let directory, _):
            return WorkingTree(directory: directory)
        case .localBranch(let checkout, let branch):
            let worktree = try await checkout.worktrees().first { $0.branch == branch.name }
            return worktree.map { WorkingTree(directory: $0.directory) }
        }
    }

    /// The unchanged lines a file's diff leaves out, or `nil` when the file cannot be read.
    static func hiddenRegions(of file: FileDiff, in tree: any SourceTree) async -> [HiddenRegion]? {
        guard let path = file.newPath, let text = try? await tree.readFile(path) else { return nil }
        return file.hiddenRegions(newText: text)
    }

    /// Where GitHub shows a file of a pull request's diff.
    static func gitHubURL(pullRequest: URL, path: String) -> URL? {
        let anchor = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "\(pullRequest.absoluteString)/files#diff-\(anchor)")
    }

    /// A sentence for the error state.
    static func message(for error: any Error) -> String {
        switch error {
        case GitHubError.ghNotInstalled:
            "The GitHub command line tool (gh) is not installed."
        case GitHubError.ghNotLoggedIn:
            "Not signed in to GitHub. Run “gh auth login” in a terminal."
        case GitHubError.rateLimited(let resetAt):
            "GitHub's rate limit is used up until \(resetAt.formatted(date: .omitted, time: .shortened))."
        case GitHubError.http(let status, let message):
            message.isEmpty ? "GitHub answered with status \(status)." : message
        case GitHubError.graphQL(let errors):
            errors.first?.message ?? "GitHub could not answer the request."
        default:
            error.localizedDescription
        }
    }
}

/// Runs `work` for every element with at most `limit` running at once, and
/// hands each result to `receive` as it finishes.
@MainActor
func forEachConcurrently<Element: Sendable, Result: Sendable>(
    _ elements: [Element], limit: Int,
    work: @escaping @Sendable (Element) async -> Result, receive: (Element, Result) -> Void
) async {
    await withTaskGroup(of: (Element, Result).self) { group in
        var rest = elements.makeIterator()
        func addNext() {
            guard let element = rest.next() else { return }
            group.addTask { (element, await work(element)) }
        }
        for _ in 0..<limit { addNext() }
        for await (element, result) in group {
            guard !Task.isCancelled else { continue }
            receive(element, result)
            addNext()
        }
    }
}

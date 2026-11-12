import Foundation
import RepoKit

/// Where a local session will run. Planning only reads; `Workspace.create`
/// makes the worktree.
struct WorkspacePlan: Hashable, Sendable {
    let checkout: Checkout
    let branch: String
    /// The worktree's directory.
    let directory: URL
    /// Whether a worktree for `branch` is already there and will be reused.
    let exists: Bool
}

enum WorkspaceError: LocalizedError, Equatable {
    case noCheckout(RepoID)
    case branchInMainWorkingCopy(branch: String, directory: URL)
    case branchNotOnRemote(branch: String, remote: String)
    case toolNotFound(String)
    case cloneFailed(String)

    var errorDescription: String? {
        switch self {
        case let .noCheckout(repo):
            "No local checkout of \(repo) was found."
        case let .branchInMainWorkingCopy(branch, directory):
            "The branch “\(branch)” is checked out in your working copy at \(directory.abbreviatedPath). "
                + "Hermes doesn't change that copy. Switch it to another branch and try again."
        case let .branchNotOnRemote(branch, remote):
            "The branch “\(branch)” isn't on the remote “\(remote)”. "
                + "A pull request from a fork can't run in a local session."
        case let .toolNotFound(tool):
            "“\(tool)” wasn't found on your PATH."
        case let .cloneFailed(message):
            "Cloning failed: \(message)"
        }
    }
}

/// Decides which worktree a local session uses: the existing worktree of the
/// origin's branch, or a new one under `root`.
///
/// - Parameter existing: The worktree that has the origin's branch checked out, if any.
/// - Throws: `WorkspaceError.branchInMainWorkingCopy` if the branch is checked
///   out in the checkout's main working copy, which a session must not use.
func planWorkspace(
    origin: SessionOrigin,
    checkout: Checkout,
    existing: (directory: URL, isMain: Bool)?,
    root: URL = Checkout.defaultWorktreesRoot
) throws -> WorkspacePlan {
    let branch = origin.branchName
    if let existing {
        guard !existing.isMain else {
            throw WorkspaceError.branchInMainWorkingCopy(branch: branch, directory: existing.directory)
        }
        return WorkspacePlan(checkout: checkout, branch: branch, directory: existing.directory, exists: true)
    }
    return WorkspacePlan(checkout: checkout, branch: branch, directory: Workspace.worktreeDirectory(repo: checkout.repo, branch: branch, root: root), exists: false)
}

/// Turns a failed `git worktree add` or fetch into an error the launch sheet can show.
func worktreeError(_ error: any Error, branch: String, remote: String) -> any Error {
    guard case let GitError.failed(_, _, stderr) = error else { return error }
    if stderr.contains("couldn't find remote ref") || stderr.contains("invalid reference") {
        return WorkspaceError.branchNotOnRemote(branch: branch, remote: remote)
    }
    return error
}

enum Workspace {
    /// `~/Library/Application Support/Hermes/checkouts`, where Hermes clones
    /// repositories the user has no checkout of.
    static var checkoutsRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Hermes/checkouts", directoryHint: .isDirectory)
    }

    static func cloneDestination(for repo: RepoID) -> URL {
        checkoutsRoot.appending(path: "\(repo.owner)/\(repo.name)", directoryHint: .isDirectory)
    }

    /// The directory `Checkout.addWorktree` creates for `branch`.
    static func worktreeDirectory(repo: RepoID, branch: String, root: URL = Checkout.defaultWorktreesRoot) -> URL {
        root.appending(path: "\(repo.owner)/\(repo.name)/\(branch.replacingOccurrences(of: "/", with: "-"))", directoryHint: .isDirectory)
    }

    /// Clones `repo` into `cloneDestination(for:)` with `gh`, or with `git`
    /// over HTTPS when `gh` is not installed.
    static func clone(_ repo: RepoID) async throws -> Checkout {
        let destination = cloneDestination(for: repo)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let output: Shell.Output
        let environment = ["GIT_TERMINAL_PROMPT": "0", "PATH": await Shell.path.value]
        if let gh = await Shell.find("gh") {
            output = try await Shell.run(gh, ["repo", "clone", repo.description, destination.path], environment: environment)
        } else if let git = await Shell.find("git") {
            output = try await Shell.run(git, ["clone", "https://github.com/\(repo).git", destination.path], environment: environment)
        } else {
            throw WorkspaceError.toolNotFound("git")
        }

        guard output.status == 0 else {
            throw WorkspaceError.cloneFailed(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Checkout(repo: repo, directory: destination)
    }

    /// Makes the plan's worktree if it does not exist yet.
    ///
    /// - Returns: The ref the session's local diff is compared with.
    static func create(_ plan: WorkspacePlan, origin: SessionOrigin) async throws -> String {
        let checkout = plan.checkout
        switch origin {
        case let .pullRequest(_, _, _, _, baseRefName, _):
            if !plan.exists {
                do {
                    _ = try await checkout.addWorktree(branch: .existing(plan.branch))
                } catch {
                    throw worktreeError(error, branch: plan.branch, remote: checkout.remote)
                }
            }
            // The local diff compares with the base branch as it is on the remote now.
            try await checkout.fetchBranch(baseRefName)
            return "\(checkout.remote)/\(baseRefName)"

        case .issue:
            if !plan.exists {
                do {
                    _ = try await checkout.addWorktree(branch: .new(plan.branch))
                } catch let GitError.failed(_, _, stderr) where stderr.contains("already exists") {
                    // The branch is left over from an earlier session whose worktree was removed.
                    try await git(["worktree", "add", plan.directory.path, plan.branch], in: checkout.directory)
                }
            }
            let head = try? await git(["symbolic-ref", "--short", "-q", "refs/remotes/\(checkout.remote)/HEAD"], in: checkout.directory)
            return head ?? "\(checkout.remote)/main"
        }
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) async throws -> String {
        guard let git = await Shell.find("git") else { throw WorkspaceError.toolNotFound("git") }
        let output = try await Shell.run(git, arguments, in: directory)
        guard output.status == 0 else {
            throw GitError.failed(arguments: arguments, status: output.status, stderr: output.stderr)
        }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension URL {
    /// The path with the home directory written as `~`.
    public var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

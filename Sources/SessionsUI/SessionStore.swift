import Foundation
import GitHubKit
import Observation
import RepoKit

/// What happens to a session's worktree when the session is closed.
public enum WorktreeDisposition: Hashable, Sendable {
    case keep
    /// Remove it unless it has uncommitted or untracked files.
    case remove
    /// Remove it and lose any uncommitted or untracked files.
    case removeDiscardingChanges
}

public enum SessionCloseError: LocalizedError {
    /// The worktree has uncommitted or untracked files, so it was not removed.
    case uncommittedChanges

    public var errorDescription: String? {
        "The worktree has uncommitted changes."
    }
}

/// The sessions started in this run of the app. Sessions end when the app quits.
@Observable
@MainActor
public final class SessionStore {
    public private(set) var sessions: [ClaudeSession] = []
    public let settings: SessionSettings

    @ObservationIgnored private var finder: (roots: [URL], finder: CheckoutFinder)?

    public init(settings: SessionSettings = .shared) {
        self.settings = settings
    }

    public func sessions(for origin: SessionOrigin) -> [ClaudeSession] {
        sessions.filter { $0.origin == origin }
    }

    /// The session working on `branch` of `repository`. A pull request whose
    /// head branch is `branch` is the one that session opened or continues.
    public func session(onBranch branch: String, in repository: RepositoryRef) -> ClaudeSession? {
        sessions.first { $0.branch == branch && $0.origin.repository == repository }
    }

    /// Starts a session for `origin`.
    ///
    /// A local session runs in a git worktree of the user's checkout: the
    /// existing worktree of the origin's branch, or a new one. The checkout's
    /// main working copy is never changed. A cloud session creates nothing on disk.
    ///
    /// - Parameters:
    ///   - name: The session's display name. Defaults to `origin.defaultSessionName`.
    ///   - prompt: The first message to Claude. Defaults to `origin.defaultPrompt`.
    /// - Throws: An error whose `localizedDescription` can be shown as it is:
    ///   no checkout, `claude` or `git` missing, or a worktree that cannot be created.
    @discardableResult
    public func launch(
        _ origin: SessionOrigin,
        environment: SessionEnvironment,
        permissionMode: PermissionMode = .default,
        name: String? = nil,
        prompt: String? = nil,
        inClaudeApp: Bool = false
    ) async throws -> ClaudeSession {
        let claude = await Shell.find("claude")
        if !inClaudeApp, claude == nil { throw WorkspaceError.toolNotFound("claude") }

        var configuration = LaunchConfiguration(
            environment: environment, permissionMode: permissionMode,
            name: name ?? origin.defaultSessionName, prompt: prompt ?? origin.defaultPrompt, directory: nil
        )
        var plan: WorkspacePlan?
        var baseRef: String?
        switch environment {
        case .local:
            let workspace = try await self.plan(for: origin)
            baseRef = try await Workspace.create(workspace, origin: origin)
            configuration.directory = workspace.directory
            plan = workspace
        case .cloud:
            configuration.directory = await cloudDirectory(for: origin)
        }
        // The launch sheet cancels the task when it closes. The worktree stays.
        try Task.checkCancellation()

        var branch = plan?.branch
        if branch == nil, case let .pullRequest(_, _, _, headRefName, _, _) = origin { branch = headRefName }

        // In the Claude app, the session's own terminal only opens the link and says so. The
        // session entry stays, so the worktree's diff and the link to its pull request still work.
        let command: String
        let script: String
        if inClaudeApp {
            guard let url = configuration.claudeAppURL else { throw WorkspaceError.noCheckout(origin.repoID) }
            command = "open \(shellQuoted(url.absoluteString))"
            script = """
                #!/bin/sh
                /usr/bin/\(command)
                printf 'Opened in the Claude app.\\nPick the environment there. This pane keeps the diff of the worktree.\\n'
                # The terminal reports a command that ends within a quarter of a second as a failed launch.
                sleep 1

                """
        } else {
            command = configuration.commandLine()
            script = """
                #!/bin/sh
                export PATH=\(shellQuoted(await Shell.path.value))
                \(configuration.commandLine(executable: claude?.path ?? "claude"))

                """
        }

        let session = try ClaudeSession(
            origin: origin,
            title: configuration.name,
            environment: environment,
            workingDirectory: plan?.directory,
            branch: branch,
            baseRef: baseRef,
            commandLine: command,
            script: script,
            processDirectory: configuration.directory,
            checkout: plan?.checkout
        )
        session.store = self
        sessions.append(session)
        return session
    }

    /// Whether closing `session` may offer to remove its worktree: Hermes
    /// created it, and no other session runs in it.
    public func canRemoveWorktree(of session: ClaudeSession) -> Bool {
        guard let directory = session.workingDirectory, session.checkout != nil else { return false }
        return directory.path.hasPrefix(Checkout.defaultWorktreesRoot.path)
            && !sessions.contains { $0 !== session && $0.workingDirectory == directory }
    }

    /// Ends the session's process and forgets the session.
    ///
    /// - Parameter worktree: `.remove` deletes the worktree only when it is
    ///   clean. The branch is kept either way.
    /// - Throws: `SessionCloseError.uncommittedChanges` if `.remove` found
    ///   uncommitted work. The process has ended, the worktree is untouched,
    ///   and the session stays in `sessions` so the caller can ask the user
    ///   and call again with `.keep` or `.removeDiscardingChanges`. Any other
    ///   removal failure also leaves the session listed, exited.
    public func close(_ session: ClaudeSession, worktree: WorktreeDisposition = .keep) async throws {
        session.terminate()

        if worktree != .keep, canRemoveWorktree(of: session), let checkout = session.checkout, let directory = session.workingDirectory {
            do {
                try await checkout.removeWorktree(at: directory, force: worktree == .removeDiscardingChanges)
            } catch let GitError.failed(_, _, stderr) where worktree == .remove && stderr.contains("--force") {
                throw SessionCloseError.uncommittedChanges
            }
        }

        // Only now: a session that stays listed after a failed removal can still restart.
        session.deleteScript()
        sessions.removeAll { $0 === session }
    }

    // MARK: Workspace

    /// The user's checkout of the origin's repository, from the search roots
    /// in settings or from Hermes's own clones.
    func checkout(for origin: SessionOrigin) async -> Checkout? {
        await checkout(for: origin.repoID)
    }

    /// The user's checkout of a repository, from the search roots in settings or from Hermes's own clones.
    public func checkout(for repository: RepoID) async -> Checkout? {
        let roots = settings.searchRoots + [Workspace.checkoutsRoot]
        if finder?.roots != roots { finder = (roots, CheckoutFinder(roots: roots)) }
        guard let finder = finder?.finder else { return nil }

        if let checkout = await finder.checkout(for: repository) { return checkout }
        // The scan is cached, and the user may have cloned since.
        await finder.rescan()
        return await finder.checkout(for: repository)
    }

    /// Where a local session for `origin` would run. Reads only.
    func plan(for origin: SessionOrigin) async throws -> WorkspacePlan {
        guard let checkout = await checkout(for: origin) else { throw WorkspaceError.noCheckout(origin.repoID) }
        let existing = try await checkout.worktrees().first { $0.branch == origin.branchName }
        return try planWorkspace(origin: origin, checkout: checkout, existing: existing.map { ($0.directory, $0.isMain) })
    }

    func clone(for origin: SessionOrigin) async throws {
        _ = try await Workspace.clone(origin.repoID)
        await finder?.finder.rescan()
    }

    /// The directory a cloud session's command runs in: the checkout, so
    /// `claude` can tell which repository the session is for.
    func cloudDirectory(for origin: SessionOrigin) async -> URL? {
        await checkout(for: origin)?.directory
    }
}

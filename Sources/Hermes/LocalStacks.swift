import Foundation
import GitHubKit
import RepoKit
import SessionsUI

/// A local branch of a repository, for the branch screen.
struct LocalBranchKey: Hashable, Sendable {
    let repository: RepositoryRef
    let branch: String
}

/// The local stacks of each repository the user has a checkout of. Read from
/// git only, and shared by every window.
@Observable
@MainActor
final class LocalStacks {
    /// A repository's checkout and its stacks.
    struct Entry: Equatable {
        let checkout: Checkout
        let stacks: [LocalStack]
    }

    private let sessions: SessionStore
    /// Nil inside means the repository has no checkout. A missing key means not looked up yet.
    private(set) var entries: [RepositoryRef: Entry?] = [:]

    init(sessions: SessionStore) {
        self.sessions = sessions
    }

    func entry(_ repository: RepositoryRef) -> Entry? {
        entries[repository] ?? nil
    }

    func isLoaded(_ repository: RepositoryRef) -> Bool {
        entries[repository] != nil
    }

    /// Reads a repository's stacks again. Cheap: git only. Keeps the old entry when git fails.
    func load(_ repository: RepositoryRef) async {
        guard let checkout = await sessions.checkout(for: RepoID(owner: repository.owner, name: repository.name)) else {
            entries[repository] = .some(nil)
            return
        }
        guard let stacks = try? await checkout.stacks() else { return }
        let entry = Entry(checkout: checkout, stacks: stacks.filter { !$0.branches.isEmpty })
        if entries[repository] != .some(entry) { entries[repository] = entry }
    }
}

extension [LocalStack] {
    /// The branches built on `branch`, directly or through other branches, in stack order.
    func branches(above branch: String) -> [LocalStack.Branch] {
        flatMap { stack in
            var chain: Set = [branch]
            return stack.branches.filter { candidate in
                guard chain.contains(candidate.parent) else { return false }
                chain.insert(candidate.name)
                return true
            }
        }
    }

    /// The stack a branch is part of.
    func stack(containing branch: String) -> LocalStack? {
        first { $0.branches.contains { $0.name == branch } }
    }
}

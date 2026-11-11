import Foundation

/// A chain of local branches that build on each other, as used for stacked
/// pull requests.
public struct LocalStack: Hashable, Sendable {
    /// One branch in a stack.
    public struct Branch: Hashable, Sendable {
        /// The branch's short name.
        public let name: String
        /// The branch this one builds on: the trunk, or a branch earlier in the stack.
        public let parent: String
    }

    /// The branch the stack targets, such as `main`.
    public let trunk: String
    /// The stack's branches, each after its parent. A stack read from
    /// `gh stack` is a single chain from bottom to top. An inferred stack can
    /// fork when two branches build on the same parent.
    public let branches: [Branch]
}

extension Checkout {
    /// The checkout's stacks of local branches.
    ///
    /// When the `gh stack` extension tracks stacks in this checkout, those are
    /// returned as recorded. Otherwise stacks are inferred from history: a
    /// branch's parent is the nearest other branch whose tip is one of its
    /// ancestors, and branches with no commits beyond the default branch are
    /// left out. Inference returns a branch on its own as a one-branch stack.
    /// "Default branch" means both the local one and the remote's, so a stale
    /// local `main` does not make every newer branch look stacked on it.
    ///
    /// - Throws: `GitError.noDefaultBranch` when inferring and the checkout
    ///   has no default branch; `GitError.failed` if git fails.
    public func stacks() async throws -> [LocalStack] {
        if let recorded = try await recordedStacks(), !recorded.isEmpty { return recorded }

        let trunk = try await Git.defaultBranch(in: directory, remote: remote)
        let localTrunk = "refs/heads/\(trunk.name)"
        let hasLocalTrunk = try await Git.succeeds(["show-ref", "--verify", "--quiet", localTrunk], in: directory)
        let tips = try await Git.run(["for-each-ref", "--format=%(objectname) %(refname:short)", "refs/heads"], in: directory)
        let commits = try await Git.run(
            ["rev-list", "--parents", "--branches", "--not", trunk.ref] + (hasLocalTrunk ? [localTrunk] : []), in: directory
        )
        return inferStacks(trunk: trunk.name, branchTips: tips.text, commitParents: commits.text)
    }

    /// One branch's own changes: `git diff parent...branch`, which leaves out
    /// commits the parent gained after the branch was cut.
    ///
    /// When the parent is the default branch, the remote's copy is used if
    /// there is one. The local default branch may be stale or missing, and a
    /// stale one would add other people's commits to the diff.
    ///
    /// - Returns: Unified diff text with renames detected.
    /// - Throws: `GitError.failed` if either branch is missing.
    public func diff(of branch: LocalStack.Branch) async throws -> String {
        let trunk = try? await Git.defaultBranch(in: directory, remote: remote)
        let parent = if let trunk, trunk.name == branch.parent { trunk.ref } else { branch.parent }
        return try await Git.run(Git.diffArguments + ["\(parent)...refs/heads/\(branch.name)"], in: directory).text
    }

    /// Reads the stacks the `gh stack` extension stores in `<git dir>/gh-stack`.
    /// The file holds every stack; `gh stack view --json` prints only the
    /// current branch's stack and asks GitHub for pull request state.
    ///
    /// - Returns: `nil` when the file is missing or has an unknown schema version.
    private func recordedStacks() async throws -> [LocalStack]? {
        let gitDirectory = try await Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory).trimmed
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: gitDirectory).appending(path: "gh-stack")) else { return nil }
        return parseGHStackFile(data)
    }
}

/// Parses the `gh stack` extension's state file (schema version 1).
func parseGHStackFile(_ data: Data) -> [LocalStack]? {
    struct File: Decodable {
        struct Stack: Decodable {
            struct Ref: Decodable { let branch: String }
            let trunk: Ref
            let branches: [Ref]
        }
        let schemaVersion: Int
        let stacks: [Stack]
    }
    guard let file = try? JSONDecoder().decode(File.self, from: data), file.schemaVersion == 1 else { return nil }
    return file.stacks.map { stack in
        let names = stack.branches.map(\.branch)
        return LocalStack(
            trunk: stack.trunk.branch,
            branches: zip(names, [stack.trunk.branch] + names).map { LocalStack.Branch(name: $0, parent: $1) }
        )
    }
}

/// Groups branches into stacks from commit ancestry.
///
/// - Parameters:
///   - trunk: The default branch's name.
///   - branchTips: `<oid> <branch>` lines for every local branch.
///   - commitParents: `git rev-list --parents` lines (`<oid> <parent>...`) for
///     the commits on local branches that are not on the trunk.
func inferStacks(trunk: String, branchTips: String, commitParents: String) -> [LocalStack] {
    var parents: [Substring: [Substring]] = [:]
    for line in commitParents.split(separator: "\n") {
        let oids = line.split(separator: " ")
        parents[oids[0]] = Array(oids.dropFirst())
    }

    // Branches ahead of the trunk, by tip. Branches sharing a tip are siblings.
    var branchesAt: [Substring: [String]] = [:]
    for line in branchTips.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 1)
        guard fields.count == 2, parents[fields[0]] != nil else { continue }
        branchesAt[fields[0], default: []].append(String(fields[1]))
    }

    // Walk back from each tip, breadth first, to the nearest commit that is another branch's tip.
    var children: [String: [String]] = [:]
    for (tip, names) in branchesAt {
        var queue = parents[tip] ?? []
        var seen = Set(queue)
        var parent = trunk
        while !queue.isEmpty {
            let oid = queue.removeFirst()
            if let below = branchesAt[oid]?.min() {
                parent = below
                break
            }
            for next in parents[oid] ?? [] where seen.insert(next).inserted { queue.append(next) }
        }
        children[parent, default: []].append(contentsOf: names)
    }

    func descendants(of parent: String) -> [LocalStack.Branch] {
        (children[parent] ?? []).sorted().flatMap { [LocalStack.Branch(name: $0, parent: parent)] + descendants(of: $0) }
    }
    return (children[trunk] ?? []).sorted().map { root in
        LocalStack(trunk: trunk, branches: [LocalStack.Branch(name: root, parent: trunk)] + descendants(of: root))
    }
}

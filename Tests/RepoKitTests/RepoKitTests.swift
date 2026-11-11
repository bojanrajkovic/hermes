import Foundation
import Testing
@testable import RepoKit

// MARK: - Helpers

/// A scratch directory removed when the test ends.
final class Scratch: Sendable {
    let url: URL

    init() throws {
        let created = FileManager.default.temporaryDirectory.appending(path: "RepoKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // FSEvents and git report resolved paths (/private/var, not /var).
        url = URL(fileURLWithPath: WatchLayout(worktree: created).worktree, isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func callAsFunction(_ path: String) -> URL { url.appending(path: path) }
}

@discardableResult
func git(_ arguments: String..., in directory: URL) async throws -> String {
    try await Git.run(
        ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments,
        in: directory
    ).trimmed
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// Creates a repository on `main` with one commit containing `files`.
func makeRepo(at directory: URL, files: [String: String] = ["README.md": "hello\n"]) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try await git("init", "--quiet", "-b", "main", in: directory)
    for (path, text) in files { try write(text, to: directory.appending(path: path)) }
    try await git("add", "-A", in: directory)
    try await git("commit", "--quiet", "-m", "initial", in: directory)
}

/// Adds a commit that creates or replaces one file.
func commit(_ path: String, _ text: String, in directory: URL) async throws {
    try write(text, to: directory.appending(path: path))
    try await git("add", "-A", in: directory)
    try await git("commit", "--quiet", "-m", "change \(path)", in: directory)
}

/// Whether `stream` emits within `seconds`.
func emits(_ stream: AsyncStream<Void>, within seconds: Double) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

// MARK: - Remote URLs

@Test(arguments: [
    "git@github.com:bojanrajkovic/airway.git",
    "git@github.com:bojanrajkovic/airway",
    "ssh://git@github.com/bojanrajkovic/airway.git",
    "ssh://git@ssh.github.com:443/bojanrajkovic/airway.git",
    "https://github.com/bojanrajkovic/airway.git",
    "https://github.com/bojanrajkovic/airway/",
    "https://user@GitHub.com/bojanrajkovic/airway",
])
func parsesGitHubRemoteURLs(url: String) {
    #expect(RepoID(remoteURL: url) == RepoID(owner: "bojanrajkovic", name: "airway"))
}

@Test(arguments: [
    "https://gitlab.com/owner/name.git",
    "git@example.com:owner/name.git",
    "https://github.com/owner",
    "https://github.com/owner/name/extra",
    "/local/path/owner/name",
    "",
])
func rejectsOtherRemoteURLs(url: String) {
    #expect(RepoID(remoteURL: url) == nil)
}

// MARK: - Working tree

@Test func workingTreeDiffIncludesCommittedStagedUnstagedAndUntracked() async throws {
    let scratch = try Scratch()
    let repo = scratch("repo")
    try await makeRepo(at: repo, files: ["a.txt": "one\n", "b.txt": "one\n", "c.txt": "one\n", ".gitignore": "ignored/\n"])
    try await git("checkout", "--quiet", "-b", "feature", in: repo)
    try await commit("a.txt", "committed\n", in: repo)
    try write("staged\n", to: repo.appending(path: "b.txt"))
    try await git("add", "b.txt", in: repo)
    try write("unstaged\n", to: repo.appending(path: "c.txt"))
    try write("brand new\n", to: repo.appending(path: "new/untracked.txt"))
    try write("secret\n", to: repo.appending(path: "ignored/file.txt"))
    let statusBefore = try await git("status", "--porcelain", in: repo)

    let tree = WorkingTree(directory: repo)
    let diff = try await tree.diff(against: "main")

    #expect(diff.contains("+committed"))
    #expect(diff.contains("+staged"))
    #expect(diff.contains("+unstaged"))
    #expect(diff.contains("diff --git a/new/untracked.txt b/new/untracked.txt\nnew file mode 100644"))
    #expect(diff.contains("+brand new"))
    #expect(!diff.contains("secret"))
    // The untracked file is still untracked: the user's index was not changed.
    #expect(try await git("status", "--porcelain", in: repo) == statusBefore)
    #expect(statusBefore.contains("?? new/"))

    #expect(try await tree.head() == WorkingTree.Head(branch: "feature", oid: try await git("rev-parse", "HEAD", in: repo)))
    try await git("checkout", "--quiet", "--detach", in: repo)
    #expect(try await tree.head().branch == nil)
}

@Test func workingTreeDiffOnlyCoversChangesSinceTheMergeBase() async throws {
    let scratch = try Scratch()
    let repo = scratch("repo")
    try await makeRepo(at: repo)
    try await git("checkout", "--quiet", "-b", "feature", in: repo)
    try await commit("feature.txt", "mine\n", in: repo)
    try await git("checkout", "--quiet", "main", in: repo)
    try await commit("main.txt", "theirs\n", in: repo)
    try await git("checkout", "--quiet", "feature", in: repo)

    let diff = try await WorkingTree(directory: repo).diff(against: "main")
    #expect(diff.contains("feature.txt"))
    #expect(!diff.contains("main.txt"))
}

// MARK: - Source trees

let grepFixture = [
    "src/render.swift": "func render() {}\nlet rendering = 1\n  render()\n",
    "docs/notes.md": "call render to draw\n",
    "node_modules/pkg/index.js": "function render() {}\n",
    "web/node_modules/pkg/index.js": "function render() {}\n",
    "vendor/lib.go": "func render() {}\n",
]

@Test func grepFindsWholeWordsInACommitAndAWorkingDirectory() async throws {
    let scratch = try Scratch()
    let repo = scratch("repo")
    try await makeRepo(at: repo, files: grepFixture)
    try Data([0x00, 0x01] + Array("render".utf8)).write(to: repo.appending(path: "binary.dat"))
    try await git("add", "-A", in: repo)
    try await git("commit", "--quiet", "-m", "binary", in: repo)

    let expected = [
        GrepMatch(path: "docs/notes.md", line: 1, text: "call render to draw"),
        GrepMatch(path: "src/render.swift", line: 1, text: "func render() {}"),
        GrepMatch(path: "src/render.swift", line: 3, text: "  render()"),
    ]
    let commitTree = CommitTree(gitDirectory: repo.appending(path: ".git"), oid: try await git("rev-parse", "HEAD", in: repo))
    #expect(try await commitTree.grep(word: "render") == expected)
    #expect(try await commitTree.grep(word: "nowhere").isEmpty)

    // The working directory also sees files that are not committed.
    try write("render\n", to: repo.appending(path: "src/untracked.swift"))
    let working = WorkingTree(directory: repo)
    #expect(try await working.grep(word: "render") == expected + [GrepMatch(path: "src/untracked.swift", line: 1, text: "render")])
}

@Test func grepCapsMatchesAndLineLength() {
    let record = "f.txt\u{0}1\u{0}" + String(repeating: "x", count: 1000) + "\n"
    let matches = parseGrep(String(repeating: record, count: SourceTreeLimits.matches + 10))
    #expect(matches.count == SourceTreeLimits.matches)
    #expect(matches[0].text.count == SourceTreeLimits.lineLength)
}

@Test func sourceTreesReadAndListFiles() async throws {
    let scratch = try Scratch()
    let repo = scratch("repo")
    try await makeRepo(at: repo, files: ["a.txt": "committed\n", "dir/b.txt": "b\n"])
    let commitTree = CommitTree(gitDirectory: repo.appending(path: ".git"), oid: try await git("rev-parse", "HEAD", in: repo))
    try write("edited\n", to: repo.appending(path: "a.txt"))
    try write("new\n", to: repo.appending(path: "c.txt"))
    let working = WorkingTree(directory: repo)

    #expect(try await commitTree.readFile("a.txt") == "committed\n")
    #expect(try await commitTree.listFiles() == ["a.txt", "dir/b.txt"])
    await #expect(throws: GitError.self) { try await commitTree.readFile("missing.txt") }

    #expect(try await working.readFile("a.txt") == "edited\n")
    #expect(try await working.listFiles().sorted() == ["a.txt", "c.txt", "dir/b.txt"])
    await #expect(throws: GitError.pathOutsideTree("../outside.txt")) { try await working.readFile("../outside.txt") }
}

// MARK: - Checkout lookup

@Test func findsCheckoutsOneAndTwoLevelsDeepByRemote() async throws {
    let scratch = try Scratch()
    try await makeRepo(at: scratch("projects/airway"))
    try await git("remote", "add", "origin", "git@github.com:bojanrajkovic/airway.git", in: scratch("projects/airway"))
    try await makeRepo(at: scratch("projects/work/hermes"))
    try await git("remote", "add", "upstream", "https://github.com/BojanRajkovic/Hermes", in: scratch("projects/work/hermes"))
    try await makeRepo(at: scratch("projects/a/b/too-deep"))
    try await git("remote", "add", "origin", "https://github.com/o/too-deep.git", in: scratch("projects/a/b/too-deep"))

    let finder = CheckoutFinder(roots: [scratch("projects"), scratch("missing")])
    #expect(await finder.checkout(for: RepoID(owner: "bojanrajkovic", name: "airway"))?.directory.path == scratch("projects/airway").path)
    #expect(await finder.checkout(for: RepoID(owner: "bojanrajkovic", name: "hermes"))?.directory.path == scratch("projects/work/hermes").path)
    // The checkout records which remote matched, and URL rewrites are applied.
    #expect(await finder.checkout(for: RepoID(owner: "bojanrajkovic", name: "hermes"))?.remote == "upstream")
    try await git("config", "url.git@github.com:.insteadOf", "gh:", in: scratch("projects/airway"))
    try await git("remote", "add", "fork", "gh:someone/airway", in: scratch("projects/airway"))
    await finder.rescan()
    #expect(await finder.checkout(for: RepoID(owner: "someone", name: "airway"))?.remote == "fork")
    #expect(await finder.checkout(for: RepoID(owner: "o", name: "too-deep")) == nil)

    // The scan is cached until rescan().
    try await makeRepo(at: scratch("projects/late"))
    try await git("remote", "add", "origin", "https://github.com/o/late.git", in: scratch("projects/late"))
    let late = RepoID(owner: "o", name: "late")
    #expect(await finder.checkout(for: late) == nil)
    await finder.rescan()
    #expect(await finder.checkout(for: late) != nil)
}

// MARK: - Worktrees

@Test func addsListsAndRemovesWorktrees() async throws {
    let scratch = try Scratch()
    // "origin" has main and a pull request branch the local clone has never fetched.
    let origin = scratch("origin")
    try await makeRepo(at: origin)
    let main = scratch("checkout")
    try await git("clone", "--quiet", origin.path, main.path, in: scratch.url)
    try await git("checkout", "--quiet", "-b", "feature/pr", in: origin)
    try await commit("pr.txt", "pr\n", in: origin)
    let prHead = try await git("rev-parse", "HEAD", in: origin)
    try await git("checkout", "--quiet", "main", in: origin)
    try await commit("later.txt", "later\n", in: origin)
    let originMain = try await git("rev-parse", "HEAD", in: origin)

    try write("uncommitted\n", to: main.appending(path: "wip.txt"))
    let checkout = Checkout(repo: RepoID(owner: "o", name: "n"), directory: main)
    let root = scratch("worktrees")

    let existing = try await checkout.addWorktree(branch: .existing("feature/pr"), root: root)
    #expect(existing.directory.path == root.appending(path: "o/n/feature-pr").path)
    #expect(existing.branch == "feature/pr")
    #expect(existing.oid == prHead)
    #expect(try await git("rev-parse", "--abbrev-ref", "feature/pr@{upstream}", in: main) == "origin/feature/pr")

    // A new branch starts from origin's current default branch, not the stale local one.
    let new = try await checkout.addWorktree(branch: .new("topic"), root: root)
    #expect(new.branch == "topic")
    #expect(new.oid == originMain)

    let listed = try await checkout.worktrees()
    #expect(listed.map(\.branch) == ["main", "feature/pr", "topic"])
    #expect(listed.map(\.isMain) == [true, false, false])
    #expect(listed[1].directory.path == existing.directory.path)
    #expect(listed[1].oid == prHead)

    // A dirty worktree is only removed when forced.
    try write("dirty\n", to: new.directory.appending(path: "dirty.txt"))
    await #expect(throws: GitError.self) { try await checkout.removeWorktree(at: new.directory) }
    try await checkout.removeWorktree(at: new.directory, force: true)
    try await checkout.removeWorktree(at: existing.directory)
    #expect(try await checkout.worktrees().map(\.branch) == ["main"])
    #expect(!FileManager.default.fileExists(atPath: existing.directory.path))

    // The main working copy kept its branch and its uncommitted file.
    #expect(try await WorkingTree(directory: main).head().branch == "main")
    #expect(try await git("status", "--porcelain", in: main) == "?? wip.txt")
    await #expect(throws: GitError.self) { try await checkout.removeWorktree(at: main, force: true) }
}

@Test func worktreeOnALeftoverBranchStartsAtTheRemoteTip() async throws {
    let scratch = try Scratch()
    let origin = scratch("origin")
    try await makeRepo(at: origin)
    try await git("checkout", "--quiet", "-b", "pr", in: origin)
    try await commit("pr.txt", "one\n", in: origin)
    let main = scratch("checkout")
    try await git("clone", "--quiet", "--branch", "main", origin.path, main.path, in: scratch.url)
    let checkout = Checkout(repo: RepoID(owner: "o", name: "n"), directory: main)
    let root = scratch("worktrees")

    // Removing a worktree keeps its branch; the pull request then gets a new commit.
    let first = try await checkout.addWorktree(branch: .existing("pr"), root: root)
    try await checkout.removeWorktree(at: first.directory)
    try await commit("pr.txt", "two\n", in: origin)
    let pushed = try await git("rev-parse", "HEAD", in: origin)

    let second = try await checkout.addWorktree(branch: .existing("pr"), root: root)
    #expect(second.oid == pushed)
    #expect(try String(contentsOf: second.directory.appending(path: "pr.txt"), encoding: .utf8) == "two\n")

    // A branch with its own commits is not moved.
    try await commit("local.txt", "local\n", in: second.directory)
    let local = try await git("rev-parse", "HEAD", in: second.directory)
    try await checkout.removeWorktree(at: second.directory)
    try await commit("pr.txt", "three\n", in: origin)
    #expect(try await checkout.addWorktree(branch: .existing("pr"), root: root).oid == local)
}

@Test func parsesDetachedAndBareWorktrees() {
    let output = [
        "worktree /repo.git\0bare\0",
        "worktree /wt/one\0HEAD abc\0branch refs/heads/feat/x\0",
        "worktree /wt/two with space\0HEAD def\0detached\0locked reason\0",
    ].joined(separator: "\0")
    let worktrees = parseWorktrees(output)
    #expect(worktrees.map(\.directory.path) == ["/wt/one", "/wt/two with space"])
    #expect(worktrees.map(\.branch) == ["feat/x", nil])
    #expect(worktrees.map(\.isMain) == [false, false])
}

// MARK: - Stacks

@Test func infersStacksFromBranchAncestry() async throws {
    let scratch = try Scratch()
    let repo = scratch("repo")
    try await makeRepo(at: repo)
    // main ── api ── ui ── polish
    //    │      └── docs
    //    └── solo            merged: no commits beyond main
    try await git("checkout", "--quiet", "-b", "api", in: repo)
    try await commit("api.txt", "api\n", in: repo)
    try await commit("api2.txt", "api2\n", in: repo)
    try await git("checkout", "--quiet", "-b", "ui", in: repo)
    try await commit("ui.txt", "ui\n", in: repo)
    try await git("checkout", "--quiet", "-b", "polish", in: repo)
    try await commit("polish.txt", "polish\n", in: repo)
    try await git("checkout", "--quiet", "-b", "docs", "api", in: repo)
    try await commit("docs.txt", "docs\n", in: repo)
    try await git("checkout", "--quiet", "-b", "solo", "main", in: repo)
    try await commit("solo.txt", "solo\n", in: repo)
    try await git("branch", "merged", "main", in: repo)

    let checkout = Checkout(repo: RepoID(owner: "o", name: "n"), directory: repo)
    let stacks = try await checkout.stacks()
    #expect(stacks == [
        LocalStack(trunk: "main", branches: [
            .init(name: "api", parent: "main"),
            .init(name: "docs", parent: "api"),
            .init(name: "ui", parent: "api"),
            .init(name: "polish", parent: "ui"),
        ]),
        LocalStack(trunk: "main", branches: [.init(name: "solo", parent: "main")]),
    ])

    // A branch's diff holds only its own commits, even after its parent moves on.
    try await git("checkout", "--quiet", "api", in: repo)
    try await commit("api3.txt", "api3\n", in: repo)
    let diff = try await checkout.diff(of: .init(name: "ui", parent: "api"))
    #expect(diff.contains("ui.txt"))
    #expect(!diff.contains("api"))
}

@Test func prefersStacksRecordedByGHStack() async throws {
    let scratch = try Scratch()
    let repo = scratch("repo")
    try await makeRepo(at: repo)
    try await git("checkout", "--quiet", "-b", "unrelated", in: repo)
    try await commit("x.txt", "x\n", in: repo)
    // The shape `gh stack init f1 f2` writes.
    try write("""
    {"schemaVersion": 1, "repository": "", "stacks": [{
      "trunk": {"branch": "develop", "head": "06090e1"},
      "branches": [{"branch": "f1", "base": "06090e1"}, {"branch": "f2", "base": "dd71a84"}]
    }]}
    """, to: repo.appending(path: ".git/gh-stack"))

    let stacks = try await Checkout(repo: RepoID(owner: "o", name: "n"), directory: repo).stacks()
    #expect(stacks == [LocalStack(trunk: "develop", branches: [
        .init(name: "f1", parent: "develop"),
        .init(name: "f2", parent: "f1"),
    ])])
    #expect(parseGHStackFile(Data(#"{"schemaVersion": 2, "stacks": []}"#.utf8)) == nil)
}

// MARK: - Change watching

@Test func watchLayoutFiltersGitInternalsAndBuildDirectories() async throws {
    let scratch = try Scratch()
    let main = scratch("main")
    try await makeRepo(at: main)
    let linked = scratch("linked")
    try await git("worktree", "add", "--quiet", "-b", "wt", linked.path, in: main)

    let layout = WatchLayout(worktree: linked)
    let gitDirectory = main.path + "/.git/worktrees/linked"
    #expect(layout.gitDirectory == gitDirectory)
    #expect(layout.commonDirectory == main.path + "/.git")
    #expect(layout.roots == [linked.path, gitDirectory, main.path + "/.git"])

    #expect(layout.isRelevant(linked.path + "/src/a.swift"))
    #expect(layout.isRelevant(gitDirectory + "/HEAD"))
    #expect(layout.isRelevant(gitDirectory + "/index"))
    #expect(layout.isRelevant(main.path + "/.git/refs/heads/wt"))
    #expect(layout.isRelevant(main.path + "/.git/packed-refs"))
    #expect(!layout.isRelevant(gitDirectory + "/index.lock"))
    #expect(!layout.isRelevant(gitDirectory + "/logs/HEAD"))
    #expect(!layout.isRelevant(main.path + "/.git/objects/ab/cdef"))
    // The main working copy's own HEAD and index are not this worktree's.
    #expect(!layout.isRelevant(main.path + "/.git/HEAD"))
    #expect(!layout.isRelevant(main.path + "/.git/index"))
    for directory in [".build", "node_modules", "target", "dist"] {
        #expect(!layout.isRelevant(linked.path + "/pkg/\(directory)/out.o"))
    }

    let mainLayout = WatchLayout(worktree: main)
    #expect(mainLayout.roots == [main.path])
    #expect(mainLayout.isRelevant(main.path + "/.git/HEAD"))
    #expect(!mainLayout.isRelevant(main.path + "/.git/objects/ab/cdef"))
}

@Test func watcherFiresOnFileChangesAndCommitsButNotBuildOutput() async throws {
    let scratch = try Scratch()
    let main = scratch("main")
    try await makeRepo(at: main, files: ["a.txt": "one\n", "staged.txt": "one\n"])
    let linked = scratch("linked")
    try await git("worktree", "add", "--quiet", "-b", "wt", linked.path, in: main)
    try write("staged\n", to: linked.appending(path: "staged.txt"))
    try await git("add", "-A", in: linked)
    try FileManager.default.createDirectory(at: linked.appending(path: "node_modules"), withIntermediateDirectories: true)
    let tree = WorkingTree(directory: linked)

    // Each case gets a fresh stream; FSEvents needs a moment before it reports.
    func fires(within seconds: Double, after change: @Sendable @escaping () async throws -> Void) async throws -> Bool {
        try await Task.sleep(for: .seconds(1))  // let events from the previous case drain
        let stream = tree.changes()
        async let fired = emits(stream, within: seconds)
        try await Task.sleep(for: .milliseconds(500))
        try await change()
        return await fired
    }

    #expect(try await fires(within: 10) { try write("two\n", to: linked.appending(path: "a.txt")) })
    #expect(try await !fires(within: 2) { try write("x\n", to: linked.appending(path: "node_modules/x.js")) })
    // Committing staged content touches no file in the worktree, only HEAD, the index, and the ref.
    #expect(try await fires(within: 10) { try await git("commit", "--quiet", "-m", "staged", in: linked) })
    // Reading the diff must not look like a change, or a reload would trigger itself.
    #expect(try await !fires(within: 2) { _ = try await tree.diff(against: "main") })
}

@Test func watcherFiresWhileWritesContinue() async throws {
    let scratch = try Scratch()
    let repo = scratch("repo")
    try await makeRepo(at: repo)

    let stream = WorkingTree(directory: repo).changes()
    async let fired = emits(stream, within: 3)
    try await Task.sleep(for: .milliseconds(500))
    // Writes arrive faster than the 300 ms delay, for longer than the wait above.
    let writer = Task {
        for index in 0..<50 {
            try write("\(index)\n", to: repo.appending(path: "log.txt"))
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    #expect(await fired)
    writer.cancel()
}

// MARK: - Repo cache

/// A local "GitHub": a repository with `main` and a pull request ref whose
/// head renamed a file.
func makeOrigin(at origin: URL) async throws -> (first: String, head: String) {
    try await makeRepo(at: origin, files: ["old.txt": String(repeating: "same line\n", count: 20), "keep.txt": "keep\n"])
    try await git("config", "uploadpack.allowAnySHA1InWant", "true", in: origin)
    try await git("checkout", "--quiet", "-b", "pr", in: origin)
    try await commit("first.txt", "first\n", in: origin)
    let first = try await git("rev-parse", "HEAD", in: origin)
    try await git("mv", "old.txt", "renamed.txt", in: origin)
    try await git("commit", "--quiet", "-m", "rename", in: origin)
    let head = try await git("rev-parse", "HEAD", in: origin)
    try await git("update-ref", "refs/pull/7/head", head, in: origin)
    try await git("checkout", "--quiet", "main", in: origin)
    try await git("branch", "-D", "--quiet", "pr", in: origin)
    try await commit("main-only.txt", "main\n", in: origin)
    return (first, head)
}

@Test func cacheFetchesPullRequestCommitsWithoutRacing() async throws {
    let scratch = try Scratch()
    let commits = try await makeOrigin(at: scratch("origin"))
    let origin = "file://" + scratch("origin").path
    let cache = RepoCache(root: scratch("cache")) { _ in origin }
    let repo = RepoID(owner: "o", name: "n")

    // Concurrent first calls share one clone.
    let trees = try await withThrowingTaskGroup(of: CommitTree.self) { group in
        for _ in 0..<6 {
            group.addTask { try await cache.ensureCommit(repo: repo, pullRequestNumber: 7, oid: commits.head) }
        }
        return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(Set(trees).count == 1)
    let tree = try #require(trees.first)
    #expect(tree.gitDirectory.path == scratch("cache/o/n.git").path)
    #expect(try await tree.listFiles() == ["first.txt", "keep.txt", "renamed.txt"])
    #expect(try await tree.readFile("keep.txt") == "keep\n")
    #expect(try await tree.grep(word: "same").count == 20)
    // Only the head commit was downloaded.
    #expect(try await git("rev-list", "--count", commits.head, in: tree.gitDirectory) == "1")

    // An older commit of the pull request is fetched by ID.
    let older = try await cache.ensureCommit(repo: repo, pullRequestNumber: 7, oid: commits.first)
    #expect(try await older.listFiles() == ["first.txt", "keep.txt", "old.txt"])

    await #expect(throws: GitError.commitUnavailable(oid: String(repeating: "0", count: 39) + "1")) {
        try await cache.ensureCommit(repo: repo, pullRequestNumber: 7, oid: String(repeating: "0", count: 39) + "1")
    }
}

@Test func cacheDiffsAPullRequestAgainstItsBaseWithRenames() async throws {
    let scratch = try Scratch()
    let commits = try await makeOrigin(at: scratch("origin"))
    let origin = "file://" + scratch("origin").path
    let cache = RepoCache(root: scratch("cache")) { _ in origin }

    let diff = try await cache.diff(repo: RepoID(owner: "o", name: "n"), pullRequestNumber: 7, baseRef: "main", headOid: commits.head)
    #expect(diff.contains("rename from old.txt\nrename to renamed.txt"))
    #expect(diff.contains("first.txt"))
    // Three-dot diff: commits only on the base branch are not shown as removals.
    #expect(!diff.contains("main-only.txt"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HERMES_LIVE"] == "1"))
func liveCacheFetchesAPullRequestFromGitHub() async throws {
    let scratch = try Scratch()
    let repo = RepoID(owner: "bojanrajkovic", name: "airway")
    // The head moves while the pull request is open, so read it instead of hard-coding it.
    let head = try await git("ls-remote", "https://github.com/bojanrajkovic/airway.git", "refs/pull/94/head", in: scratch.url)
    let oid = String(try #require(head.split(separator: "\t").first))
    let cache = RepoCache(root: scratch("cache"))

    let tree = try await cache.ensureCommit(repo: repo, pullRequestNumber: 94, oid: oid)
    #expect(try await !tree.listFiles().isEmpty)
    let diff = try await cache.diff(repo: repo, pullRequestNumber: 94, baseRef: "main", headOid: oid)
    #expect(diff.hasPrefix("diff --git "))
}

// MARK: - Hardening

@Test func readsOutputLargerThanAPipeBuffer() async throws {
    let scratch = try Scratch()
    let repo = scratch("repo")
    let big = String(repeating: "0123456789abcdef\n", count: 200_000)  // 3.4 MB
    try await makeRepo(at: repo, files: ["big.txt": big])
    let tree = CommitTree(gitDirectory: repo.appending(path: ".git"), oid: try await git("rev-parse", "HEAD", in: repo))
    #expect(try await tree.readFile("big.txt") == big)
    // A directory is not a file.
    await #expect(throws: GitError.self) { try await tree.readFile(".") }
}

@Test func diffAndGrepOutputIgnoresUserConfiguration() async throws {
    let scratch = try Scratch()
    let repo = scratch("repo")
    try await makeRepo(at: repo, files: ["a.txt": "needle\n"])
    for setting in ["diff.mnemonicPrefix", "diff.noprefix", "grep.column"] {
        try await git("config", setting, "true", in: repo)
    }
    try await git("config", "color.ui", "always", in: repo)
    try await git("config", "diff.external", "false", in: repo)
    try await git("checkout", "--quiet", "-b", "feature", in: repo)
    try await commit("a.txt", "needle changed\n", in: repo)

    let header = "diff --git a/a.txt b/a.txt\n"
    let checkout = Checkout(repo: RepoID(owner: "o", name: "n"), directory: repo)
    #expect(try await checkout.diff(of: .init(name: "feature", parent: "main")).hasPrefix(header))
    let working = WorkingTree(directory: repo)
    #expect(try await working.diff(against: "main").hasPrefix(header))
    #expect(try await working.grep(word: "needle") == [GrepMatch(path: "a.txt", line: 1, text: "needle changed")])
    #expect(try await working.grep(word: "").isEmpty)
}

@Test func stacksAndWorktreesUseTheMatchingRemoteWhenLocalMainIsStaleOrMissing() async throws {
    let scratch = try Scratch()
    let upstream = scratch("upstream")
    try await makeRepo(at: upstream)
    let main = scratch("checkout")
    try await git("clone", "--quiet", "--origin", "upstream", upstream.path, main.path, in: scratch.url)
    // Upstream moves on; the branch is cut from the new upstream/main while local main stays behind.
    try await commit("theirs.txt", "theirs\n", in: upstream)
    try await git("fetch", "--quiet", "upstream", in: main)
    try await git("checkout", "--quiet", "-b", "feature", "upstream/main", in: main)
    try await commit("mine.txt", "mine\n", in: main)

    let checkout = Checkout(repo: RepoID(owner: "o", name: "n"), directory: main, remote: "upstream")
    let expected = [LocalStack(trunk: "main", branches: [.init(name: "feature", parent: "main")])]
    #expect(try await checkout.stacks() == expected)
    let diff = try await checkout.diff(of: expected[0].branches[0])
    #expect(diff.contains("mine.txt"))
    #expect(!diff.contains("theirs.txt"))

    // With no local main at all, the stack and its diff still resolve.
    try await git("branch", "-D", "--quiet", "main", in: main)
    #expect(try await checkout.stacks() == expected)
    #expect(try await checkout.diff(of: expected[0].branches[0]) == diff)

    // Worktrees fetch from that remote too.
    try await git("checkout", "--quiet", "-b", "pr", in: upstream)
    try await commit("pr.txt", "pr\n", in: upstream)
    let added = try await checkout.addWorktree(branch: .existing("pr"), root: scratch("worktrees"))
    #expect(added.oid == (try await git("rev-parse", "pr", in: upstream)))
    #expect(try await git("rev-parse", "--abbrev-ref", "pr@{upstream}", in: main) == "upstream/pr")
}

@Test func cacheDiffDeepensUntilTheMergeBaseIsFound() async throws {
    let scratch = try Scratch()
    let commits = try await makeOrigin(at: scratch("origin"))
    // Push the merge base more than the first fetch's 50 commits below main's tip.
    for index in 0..<60 {
        try await git("commit", "--quiet", "--allow-empty", "-m", "filler \(index)", in: scratch("origin"))
    }
    let origin = "file://" + scratch("origin").path
    let cache = RepoCache(root: scratch("cache")) { _ in origin }

    let diff = try await cache.diff(repo: RepoID(owner: "o", name: "n"), pullRequestNumber: 7, baseRef: "main", headOid: commits.head)
    #expect(diff.contains("rename from old.txt\nrename to renamed.txt"))
    #expect(!diff.contains("main-only.txt"))

    // A later call keeps the deepened history. This one stops right after its
    // first fetch, because the commit does not exist.
    let repo = RepoID(owner: "o", name: "n")
    let missing = String(repeating: "0", count: 39) + "1"
    await #expect(throws: GitError.commitUnavailable(oid: missing)) {
        try await cache.diff(repo: repo, pullRequestNumber: 7, baseRef: "main", headOid: missing)
    }
    #expect(try await Git.succeeds(["merge-base", "refs/hermes/base/main", commits.head], in: scratch("cache/o/n.git")))
}

@Test func gitDoesNotStartInACancelledTask() async throws {
    let scratch = try Scratch()
    let target = scratch("never-created")
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await Git.run(["init", "--quiet", target.path], in: scratch.url)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

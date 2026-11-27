import DiffKit
import Foundation
import GitHubKit
import RepoKit
import Testing
@testable import DiffUI

/// Submits a real review. Not part of the normal test run, and only ever
/// against the scratch repository:
///
///     DIFFUI_SUBMIT=2 swift test --filter DiffUITests.LiveReviewTests
@MainActor
@Suite(.enabled(if: ["DIFFUI_SUBMIT", "DIFFUI_WATCH", "DIFFUI_VIEWED"].contains { ProcessInfo.processInfo.environment[$0] != nil }))
struct LiveReviewTests {
    private static let playground = RepositoryRef(owner: "bojanrajkovic", name: "hermes-playground")

    /// Watches a pull request (`DIFFUI_WATCH=<number>`) for a minute and reports when its threads change.
    /// Comment on the pull request while it runs. The test itself only reads.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIFFUI_WATCH"] != nil))
    func threadsReloadWhenSomeoneComments() async throws {
        let number = try #require(ProcessInfo.processInfo.environment["DIFFUI_WATCH"].flatMap(Int.init))
        let client = GitHubClient()
        let pullRequest = try #require(try await client.pullRequests(ids: client.pullRequestIDs(matching: PullRequestSearch.open(owner: Self.playground.owner)))
            .first { $0.repository == Self.playground && $0.number == number })
        let root = FileManager.default.temporaryDirectory.appending(path: "hermes-live-\(UUID().uuidString)")
        let model = DiffModel(source: .pullRequest(pullRequest), client: client, repoCache: RepoCache(), draftsRoot: root)
        let runner = Task { await model.run() }
        defer { runner.cancel() }
        var seen = -1
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(500))
            let count = model.review?.threads.reduce(0) { $0 + $1.comments.count } ?? 0
            if count != seen {
                seen = count
                print("WATCH comments=\(count) at \(Date.now.formatted(date: .omitted, time: .standard))")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIFFUI_SUBMIT"] != nil))
    func oneSubmissionCarriesEveryKindOfComment() async throws {
        let number = try #require(ProcessInfo.processInfo.environment["DIFFUI_SUBMIT"].flatMap(Int.init))
        let client = GitHubClient()
        let pullRequests = try await client.pullRequests(ids: client.pullRequestIDs(matching: PullRequestSearch.open(owner: Self.playground.owner)))
        let pullRequest = try #require(pullRequests.first { $0.repository == Self.playground && $0.number == number })
        let root = FileManager.default.temporaryDirectory.appending(path: "hermes-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = DiffModel(source: .pullRequest(pullRequest), client: client, repoCache: RepoCache(), draftsRoot: root)
        await model.reload()
        let review = try #require(model.review)
        let before = review.threads
        let existing = try #require(before.first { !$0.isOutdated })

        func add(_ file: FileModel, _ first: DiffLine, _ last: DiffLine, _ body: String) {
            review.startComment(file: file.id, from: first, to: last)
            review.composer?.text = body
            review.addComposerToReview()
        }
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        let lines = model.files.flatMap { file in file.diff.hunks.flatMap(\.lines).map { (file, $0) } }
        let addition = try #require(lines.first { $0.1.kind == .addition })
        let deletion = try #require(lines.first { $0.1.kind == .deletion })
        let (rangeFile, hunk) = try #require(
            model.files.lazy.flatMap { file in file.diff.hunks.map { (file, $0) } }.first { $0.1.lines.count { $0.kind == .addition } >= 3 }
        )
        let additions = hunk.lines.filter { $0.kind == .addition }
        add(addition.0, addition.1, addition.1, "Hermes test \(stamp): single line on the right.")
        add(deletion.0, deletion.1, deletion.1, "Hermes test \(stamp): a removed line, on the left.")
        add(rangeFile, additions[0], additions[2], "Hermes test \(stamp): three lines.")
        review.open(.reply(threadID: existing.id))
        review.composer?.text = "Hermes test \(stamp): a reply."
        review.addComposerToReview()
        review.summary = "Hermes test \(stamp): one review with four comments."

        await review.flush()
        #expect(PendingReview.load(from: PendingReview.url(root: root, repository: Self.playground, number: number)).comments.count == 4)
        #expect(review.layout.submittable.count == 4)

        #expect(await review.submit(.comment))
        #expect(review.submission == .idle)
        #expect(review.pending.comments.isEmpty)
        #expect(review.threads.count == before.count + 3)
        #expect(review.threads.first { $0.id == existing.id }?.comments.count == existing.comments.count + 1)
        await review.flush()
        print("SUBMIT stamp=\(stamp) threads=\(review.threads.count)")
    }

    /// Marks files viewed both ways on a pull request (`DIFFUI_VIEWED=<number>`, at least two files),
    /// then unmarks them.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIFFUI_VIEWED"] != nil))
    func viewedMarksSyncWithGitHub() async throws {
        let number = try #require(ProcessInfo.processInfo.environment["DIFFUI_VIEWED"].flatMap(Int.init))
        let client = GitHubClient()
        let pullRequest = try #require(try await client.pullRequests(ids: client.pullRequestIDs(matching: PullRequestSearch.open(owner: Self.playground.owner)))
            .first { $0.repository == Self.playground && $0.number == number })
        let root = FileManager.default.temporaryDirectory.appending(path: "hermes-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func gitHubViewed() async throws -> Set<String> {
            try await client.pullRequestRevision(repository: Self.playground, number: number).viewedPaths
        }
        let model = DiffModel(source: .pullRequest(pullRequest), client: client, repoCache: RepoCache(), draftsRoot: root)
        let runner = Task { await model.run() }
        defer { runner.cancel() }
        while model.phase != .loaded { try await Task.sleep(for: .milliseconds(200)) }
        let (first, second) = (model.files[0], model.files[1])
        // Unmarks both files whatever happens, so the next run starts clean.
        func cleanUp() async {
            for path in [first.diff.path, second.diff.path] {
                try? await client.setFileViewed(pullRequestID: pullRequest.id, path: path, viewed: false)
            }
        }
        do {
            try await checkViewedSync(model, client, pullRequest, first, second, gitHubViewed)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    private func checkViewedSync(
        _ model: DiffModel, _ client: GitHubClient, _ pullRequest: PullRequest, _ first: FileModel, _ second: FileModel,
        _ gitHubViewed: () async throws -> Set<String>
    ) async throws {
        // Hermes to GitHub.
        model.setViewed(true, for: first)
        try await Task.sleep(for: .seconds(2))
        #expect(try await gitHubViewed().contains(first.diff.path))

        // GitHub to Hermes, within one poll.
        try await client.setFileViewed(pullRequestID: pullRequest.id, path: second.diff.path, viewed: true)
        try await Task.sleep(for: .seconds(12))
        #expect(second.isViewed)
        #expect(first.isViewed)

        model.setViewed(false, for: first)
        try await client.setFileViewed(pullRequestID: pullRequest.id, path: second.diff.path, viewed: false)
        try await Task.sleep(for: .seconds(12))
        #expect(!first.isViewed && !second.isViewed)
        #expect(try await gitHubViewed().isEmpty)
    }
}

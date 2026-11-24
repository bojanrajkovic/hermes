import Foundation
import GitHubKit
import os

/// The store's GitHub tables as a JSON file in Caches, so the lists show at launch before the
/// first refresh answers.
///
/// It is a cache, not a second home: the store reads it once at launch, and every fetch after
/// that overwrites what it restored. It keeps the pull request lists and the records they name,
/// and repositories. Issue lists are left out: every refresh reloads each one the store holds,
/// so carrying them across launches would make that set, and its cost, grow without end.
public struct StoreSnapshot: Codable, Sendable {
    /// The signed-in user who saved it. Nil when nobody had signed in.
    var viewer: String?
    var pullRequests: [ItemKey: PullRequest]
    var repositories: [RepositoryRef: Stamped<Repository>]
    var accounts: [String: AccountLists]
    var details: [ItemKey: PullRequestDetail]
    var readiness: [ItemKey: MergeReadiness]
    var revisions: [ItemKey: Stamped<PullRequestRevision>]
    var checks: [CommitKey: CommitChecks]

    /// Where the app keeps its snapshot. macOS may empty Caches, which costs one slow launch.
    public static let url = URL.cachesDirectory.appending(path: "Hermes/store.json")

    /// How long ago an account's lists may have loaded for a restore to keep them. GitHub's
    /// search returns at most 1,000 results, so the first refresh after a longer gap could miss
    /// pull requests that closed, and they would stay listed.
    static let maxAge: TimeInterval = 24 * 60 * 60

    private static let log = Logger(subsystem: "com.coderinserepeat.hermes", category: "store")

    /// Writes the snapshot atomically, so a reader never sees half a file. Safe off the main actor.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Reads the snapshot at `url`. One this build can't decode, such as one an older build
    /// wrote, is deleted.
    ///
    /// - Returns: Nil when there is none or it was deleted.
    static func read(from url: URL) -> StoreSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(StoreSnapshot.self, from: data)
        } catch {
            log.error("snapshot unreadable: \(error, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}

extension GitHubStore {
    /// The tables as they are now, cut down to what the account lists name: their pull requests,
    /// with each one's detail, readiness, revision, and head commit's checks, and repositories.
    /// A pull request opened only by link loads again when a screen shows it.
    public func snapshot() -> StoreSnapshot {
        let listed = Set(accounts.values.flatMap(\.openPullRequests))
        let heads = Set(listed.compactMap { pullRequests[$0] }.map { CommitKey(repository: $0.repository, oid: $0.headOID) })
        return StoreSnapshot(
            // A quit before sign-in finishes keeps the restored snapshot's owner.
            viewer: viewer ?? restoredViewer,
            pullRequests: pullRequests.filter { listed.contains($0.key) },
            repositories: repositories,
            accounts: accounts,
            details: details.filter { listed.contains($0.key) },
            readiness: readiness.filter { listed.contains($0.key) },
            revisions: revisions.filter { listed.contains($0.key) },
            checks: checks.filter { heads.contains($0.key) && $0.value.isLoaded }
        )
    }

    /// Fills the tables from the snapshot at `url`, for launch. Call it before the first refresh.
    public func restore(from url: URL, now: Date = .now) {
        if let snapshot = StoreSnapshot.read(from: url) { restore(snapshot, now: now) }
    }

    /// Fills the tables from `snapshot`. An account whose lists last loaded more than `maxAge`
    /// before `now` is left out, along with the pull requests only it lists, and loads from scratch.
    ///
    /// A restored value never beats a fetched one. A record already in the store came from a
    /// fetch, so it stays. Every later fetch writes over a restored record: plain tables take
    /// any write, and `Stamped` values keep the start time of the fetch that produced them,
    /// which is before any fetch this launch makes. The load bookkeeping (`detailLoadedFor`,
    /// `readinessInputs`, `checksShownAt`) starts empty, so a screen's first poll loads its
    /// detail, readiness, and checks. The write counters and
    /// `AppliedPayloads` start empty too, so a restored value can't make a load drop its answer.
    func restore(_ snapshot: StoreSnapshot, now: Date) {
        let recent = snapshot.accounts.filter { _, lists in
            lists.pullRequestsLoadedAt.map { now.timeIntervalSince($0) <= StoreSnapshot.maxAge } ?? false
        }
        let listed = Set(recent.values.flatMap(\.openPullRequests))
        func keepLive<Value>(_ live: Value, _: Value) -> Value { live }
        restoredViewer = snapshot.viewer
        accounts.merge(recent, uniquingKeysWith: keepLive)
        pullRequests.merge(snapshot.pullRequests.filter { listed.contains($0.key) }, uniquingKeysWith: keepLive)
        repositories.merge(snapshot.repositories, uniquingKeysWith: keepLive)
        details.merge(snapshot.details.filter { listed.contains($0.key) }, uniquingKeysWith: keepLive)
        readiness.merge(snapshot.readiness.filter { listed.contains($0.key) }, uniquingKeysWith: keepLive)
        revisions.merge(snapshot.revisions.filter { listed.contains($0.key) }, uniquingKeysWith: keepLive)
        checks.merge(snapshot.checks, uniquingKeysWith: keepLive)
    }

    /// Records who signed in. When the restored snapshot was another user's, its records go,
    /// so that user's private pull requests don't show. Every table loads again from GitHub.
    public func signedIn(as login: String) {
        viewer = login
        defer { restoredViewer = nil }
        guard let restoredViewer, restoredViewer != login else { return }
        pullRequests = [:]
        repositories = [:]
        accounts = [:]
        details = [:]
        readiness = [:]
        revisions = [:]
        checks = [:]
    }
}

import Foundation
import GitHubKit

/// What a pull request's merge readiness depends on: a push, a review, or a finished check changes it.
struct ReadinessInput: Hashable {
    let head: String
    let updatedAt: Date
    let checks: ChecksRollup?

    init(_ pullRequest: PullRequest) {
        head = pullRequest.headOID
        updatedAt = pullRequest.updatedAt
        checks = pullRequest.checkState
    }
}

/// One file of one pull request, for ordering its viewed marks.
struct ViewedFile: Hashable {
    let key: ItemKey
    let path: String
}

extension GitHubStore {
    // MARK: Polling

    /// Keeps an open pull request's screens current: its head commit and viewed files, its
    /// record, its conversation and review threads, and whether it can merge.
    func pollPullRequest(_ key: ItemKey) async {
        let started = Date.now
        if let revision = try? await client.pullRequestRevision(repository: key.repository, number: key.number) {
            take(revision, for: key, startedAt: started)
            if let record = pullRequests[key], record.headOID != revision.headOID || record.updatedAt != revision.updatedAt {
                await refetch(key)
            }
        }

        // Whether it can merge loads beside the detail, which can take seconds on a large pull request.
        async let readiness: Void = loadReadinessIfStale(key)

        // The conversation and the threads change with GitHub's update time, which a push, a
        // comment, or a review moves.
        let updatedAt = revisions[key]?.value.updatedAt ?? pullRequests[key]?.updatedAt
        if details[key] == nil || detailLoadedFor[key] != updatedAt {
            if await loadDetail(key) { detailLoadedFor[key] = updatedAt }
        }
        await readiness
    }

    private func loadReadinessIfStale(_ key: ItemKey) async {
        if let record = pullRequests[key], record.state == .open, readinessInputs[key] != ReadinessInput(record) {
            await loadReadiness(key)
        }
    }

    // MARK: Revision and viewed files

    /// Takes a revision read by a fetch that started at `startedAt`. A fetch that started
    /// before the last viewed mark doesn't know about it, so its answer is dropped. Marks
    /// still on their way to GitHub are laid over the revision, since GitHub may answer
    /// without them until their mutation finishes.
    public func take(_ revision: PullRequestRevision, for key: ItemKey, startedAt: Date) {
        var revision = revision
        for (file, viewed) in viewedInFlight where file.key == key {
            if viewed { revision.viewedPaths.insert(file.path) } else { revision.viewedPaths.remove(file.path) }
        }
        if revisions[key]?.write(revision, startedAt: startedAt) == nil {
            revisions[key] = Stamped(revision, fetchedAt: startedAt)
        }
    }

    /// The paths the viewer marked viewed on GitHub. Nil until a revision loads.
    public func viewedPaths(of key: ItemKey) -> Set<String>? {
        revisions[key]?.value.viewedPaths
    }

    /// Marks a file viewed or unviewed on GitHub. The mark shows at once, and a revision
    /// fetch that started before it can't undo it. Marks for one path go out in order.
    ///
    /// - Throws: What GitHub answered. The mark is then taken back, unless a later mark for
    ///   the same path replaced it.
    public func setViewed(_ viewed: Bool, path: String, of pullRequest: PullRequest) async throws {
        let key = pullRequest.key
        let file = ViewedFile(key: key, path: path)
        viewedInFlight[file] = viewed
        markViewed(viewed, path: path, of: key)
        viewedSends[file, default: 0] += 1
        let send = viewedSends[file] ?? 0
        let previous = viewedTasks[file]
        let task = Task { [client] in
            await previous?.value
            try await client.setFileViewed(pullRequestID: pullRequest.id, path: path, viewed: viewed)
        }
        viewedTasks[file] = Task { _ = try? await task.value }
        do {
            try await task.value
            if viewedSends[file] == send { viewedInFlight[file] = nil }
        } catch {
            guard viewedSends[file] == send else { throw error }
            viewedInFlight[file] = nil
            markViewed(!viewed, path: path, of: key)
            throw error
        }
    }

    private func markViewed(_ viewed: Bool, path: String, of key: ItemKey) {
        guard var revision = revisions[key]?.value else { return }
        if viewed { revision.viewedPaths.insert(path) } else { revision.viewedPaths.remove(path) }
        take(revision, for: key, startedAt: .now)
    }

    // MARK: Conversation and threads

    /// Loads the pull request's description, conversation, reviews, commits, and review threads.
    ///
    /// A change applied while GitHub answers is newer than the answer, so the load runs once
    /// more. A load that a later one overtakes drops its answer.
    ///
    /// - Returns: Whether the detail was loaded.
    @discardableResult
    public func loadDetail(_ key: ItemKey) async -> Bool {
        detailLoads[key, default: 0] += 1
        let load = detailLoads[key] ?? 0
        do {
            var before: Int
            var detail: PullRequestDetail
            repeat {
                before = detailWrites[key, default: 0]
                detail = try await client.pullRequestDetail(repository: key.repository, number: key.number)
                guard load == detailLoads[key] else { return false }
            } while detailWrites[key, default: 0] != before
            details[key] = detail
            detailErrors[key] = nil
            return true
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            return false
        } catch {
            detailErrors[key] = describe(error)
            return false
        }
    }

    /// Applies what a webhook says changed to the description, conversation, and reviews.
    ///
    /// - Returns: False when nothing is loaded yet or the change can't be applied, so the
    ///   detail has to load instead.
    public func applyToDetail(_ change: WebhookChange, for key: ItemKey) -> Bool {
        guard let changed = details[key]?.applying(change) else { return false }
        details[key] = changed
        detailWrites[key, default: 0] += 1
        return true
    }

    /// Applies what a webhook says changed to the review threads.
    ///
    /// - Returns: False when nothing is loaded yet or the change can't be applied, so the
    ///   threads have to load instead.
    public func applyToThreads(_ change: WebhookChange, for key: ItemKey) -> Bool {
        guard var detail = details[key], let threads = ReviewThread.applying(change, to: detail.reviewThreads) else { return false }
        detail.reviewThreads = threads
        details[key] = detail
        detailWrites[key, default: 0] += 1
        return true
    }

    // MARK: Merging

    /// Loads whether the pull request can merge, and how.
    /// A failed load leaves the inputs unrecorded, so the next poll tries again.
    public func loadReadiness(_ key: ItemKey) async {
        let input = pullRequests[key].map(ReadinessInput.init)
        guard let loaded = try? await client.mergeReadiness(repository: key.repository, number: key.number) else { return }
        readiness[key] = loaded
        if let input { readinessInputs[key] = input }
    }
}

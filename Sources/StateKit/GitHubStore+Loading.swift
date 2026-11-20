import Foundation
import GitHubKit

extension GitHubStore {
    /// Brings an account's lists up to date. Rows keep their identity, so selection and scroll position stay.
    ///
    /// The first load fetches the pull requests that involve the viewer, shows
    /// them, then fetches the rest of the account. Later refreshes fetch only the
    /// pull requests updated since the last one, so a large organization costs a
    /// few requests per refresh instead of hundreds.
    ///
    /// - Parameter everything: Also reload the repositories, which otherwise
    ///   reload once they are 10 minutes old. For ⌘R.
    public func refresh(_ login: String, everything: Bool = false) async {
        guard !login.isEmpty, !lists(of: login).isRefreshing else { return }
        accounts[login, default: AccountLists()].isRefreshing = true
        defer { accounts[login]?.isRefreshing = false }

        let started = Date.now
        accounts[login]?.lastAttempt = started
        let appliedBefore = applied
        let lists = lists(of: login)
        // Tried, not loaded: a failed load waits as long as a good one, so it does not retry every refresh.
        let reposAreStale = lists.repositoriesTriedAt.map { started.timeIntervalSince($0) > 600 } ?? true
        let loadsRepositories = everything || reposAreStale
        if loadsRepositories { accounts[login]?.repositoriesTriedAt = started }
        async let loadedRepositories = loadsRepositories ? client.repositories(owner: login) : nil
        do {
            if let since = lists.pullRequestsLoadedAt {
                try await loadChanges(of: login, since: since)
            } else {
                try await loadEverything(of: login)
            }
            accounts[login]?.pullRequestsLoadedAt = started
            if let loaded = try await loadedRepositories {
                for repository in loaded { store(repository, startedAt: started) }
                accounts[login]?.repositories = loaded.map(\.ref)
            }
            // Teams change as rarely as repositories do. A failed load keeps the last answer.
            if loadsRepositories, let teams = try? await client.viewerTeams() { accounts[login]?.signals.teams = teams }
            accounts[login]?.listError = nil
            accounts[login]?.lastRefresh = .now
        } catch {
            accounts[login]?.listError = describe(error)
        }
        // A row that took a payload while the lists loaded may now show their older answer, so it loads once more.
        for key in applied.rows(since: appliedBefore) { await refetch(key) }

        await withTaskGroup(of: Void.self) { group in
            for repository in issueLists.keys where repository.owner == login {
                group.addTask { await self.reloadIssues(of: repository) }
            }
        }
    }

    /// Reloads when the lists are older than a few seconds, for app activation.
    public func refreshIfStale(_ login: String) async {
        if let lastRefresh = lists(of: login).lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 10 { return }
        await refresh(login)
    }

    /// The viewer's pull requests first, so their lists show while the rest of the account loads.
    /// The rest is only what is in repositories the viewer can push to. A load that fails part
    /// way keeps what it fetched, and the next refresh fetches only what is still missing.
    private func loadEverything(of login: String) async throws {
        let found = try await client.pullRequestHits(
            matchingEach: [PullRequestSearch.involvingViewer(owner: login)[0]] + signalSearches(login)
        )
        try await loadMissing(Array(Set(found[0].map(\.id)).union(noteSignals(found.dropFirst(), of: login))), of: login)
        accounts[login]?.hasLoaded = true

        let rest = try await client.pullRequestHits(matching: PullRequestSearch.open(owner: login)).filter(\.canPush)
        try await loadMissing(rest.map(\.id), of: login)
    }

    /// Loads the pull requests not held yet, 50 at a time, adding each batch as it arrives.
    private func loadMissing(_ ids: [String], of login: String) async throws {
        let held = Set(openPullRequests(of: login).map(\.id))
        let missing = ids.filter { !held.contains($0) }
        for start in stride(from: 0, to: missing.count, by: 50) {
            let batch = try await client.pullRequests(ids: Array(missing[start..<min(start + 50, missing.count)]))
            setOpenPullRequests(PullRequestChanges.apply(to: openPullRequests(of: login), changed: batch, closed: []), of: login)
        }
    }

    /// The pull requests updated since the last refresh, and the current review requests.
    // shortcut: a repository archived since the first load keeps its pull requests until relaunch; reload everything if that matters.
    private func loadChanges(of login: String, since: Date) async throws {
        let found = try await client.pullRequestHits(matchingEach: [
            PullRequestSearch.updated(owner: login, since: since, open: true),
            PullRequestSearch.updated(owner: login, since: since, open: false),
        ] + signalSearches(login))
        let (openHits, closedIDs, signaledIDs) = (found[0], found[1].map(\.id), noteSignals(found.dropFirst(2), of: login))

        // A read-only repository's pull request loads only when the viewer already holds it or has a part in it.
        // A review request or a mention does not update the pull request, so one not held yet loads here.
        let open = openPullRequests(of: login)
        let held = Set(open.map(\.id))
        let openIDs = openHits.filter { $0.canPush || held.contains($0.id) || signaledIDs.contains($0.id) }.map(\.id)
        // A check that finishes or runs again does not update its pull request, so any whose checks have not passed load again.
        let unsettled = open.filter { $0.checkState != nil && $0.checkState != .passed }.map(\.id)
        let watched = watched(login)
        let watchedIDs = PullRequestChanges.watched(watched, among: open)
        async let fetched: Void = refetchOpenedByNumber(watched, of: login)
        let changed = try await client.pullRequests(
            ids: Array(Set(openIDs + unsettled + watchedIDs).union(signaledIDs.subtracting(held))), perRequest: 25
        )
        await fetched

        // A pull request loaded by ID says itself when it has closed, before the search does.
        let reloaded = PullRequestChanges.apply(
            to: openPullRequests(of: login), changed: changed.filter { $0.state == .open },
            closed: Set(closedIDs).union(changed.filter { $0.state != .open }.map(\.id))
        )
        let closed = changed.filter { $0.state != .open }
        for pullRequest in closed { pullRequests[pullRequest.key] = pullRequest }
        // One that left without a closed copy here loads whether it was merged or closed.
        let staying = Set(reloaded.map(\.key)).union(closed.map(\.key))
        for leaving in lists(of: login).openPullRequests where !staying.contains(leaving) {
            Task { await refetch(leaving) }
        }
        setOpenPullRequests(reloaded, of: login)
    }

    /// Writes the records of an account's open list and its order.
    private func setOpenPullRequests(_ list: [PullRequest], of login: String) {
        for pullRequest in list { pullRequests[pullRequest.key] = pullRequest }
        accounts[login]?.openPullRequests = list.map(\.key)
    }

    /// Loads again the watched pull requests that are open but not in the open list: ones opened by number.
    private func refetchOpenedByNumber(_ watched: [ItemKey], of login: String) async {
        let listed = Set(lists(of: login).openPullRequests)
        for key in watched where !listed.contains(key) && pullRequests[key]?.state == .open { await refetch(key) }
    }

    /// Searches for the viewer's review requests, reviews, and mentions, in that order. The pull
    /// request itself says who it asks and what the viewer reviewed, so these only find the
    /// ones not held yet, in any repository.
    private func signalSearches(_ login: String) -> [String] {
        [
            PullRequestSearch.reviewRequested(owner: login), PullRequestSearch.reviewedByViewer(owner: login),
            PullRequestSearch.mentioningViewer(owner: login),
        ]
    }

    /// Keeps the mentions from the results of `signalSearches`, and returns every pull request they name.
    private func noteSignals(_ found: ArraySlice<[PullRequestHit]>, of login: String) -> Set<String> {
        accounts[login]?.signals.mentions = Set(found.last?.map(\.id) ?? [])
        return Set(found.joined().map(\.id))
    }
}

import Foundation
import GitHubKit

extension GitHubStore {
    /// Loads the next page of a repository's issues. Does nothing while a page
    /// is loading or when every issue is loaded.
    public func loadMoreIssues(of repository: RepositoryRef) async {
        var list = issueList(of: repository)
        guard !list.isLoading, list.hasNextPage else { return }
        list.isLoading = true
        list.error = nil
        issueLists[repository] = list

        let started = Date.now
        do {
            let page = try await client.issues(repository: repository, pageSize: Self.issuePageSize, after: list.endCursor)
            guard var current = issueLists[repository] else { return }
            store(page, of: repository, startedAt: started)
            let known = Set(current.keys)
            current.keys += page.items.map { ItemKey(repository: repository, number: $0.number) }.filter { !known.contains($0) }
            current.endCursor = page.endCursor ?? current.endCursor
            current.hasNextPage = page.hasNextPage
            current.isLoading = false
            issueLists[repository] = current
        } catch {
            issueLists[repository]?.isLoading = false
            issueLists[repository]?.error = describe(error)
        }
    }

    /// Loads again as many issues as are loaded now, in pages of up to 100.
    public func reloadIssues(of repository: RepositoryRef) async {
        guard let existing = issueLists[repository], !existing.isLoading, !existing.keys.isEmpty else { return }
        let started = Date.now
        var reloaded = IssueList()
        var pages: [IssuePage] = []
        do {
            repeat {
                let page = try await client.issues(
                    repository: repository, pageSize: min(100, max(Self.issuePageSize, existing.keys.count - reloaded.keys.count)),
                    after: reloaded.endCursor
                )
                pages.append(page)
                reloaded.keys += page.items.map { ItemKey(repository: repository, number: $0.number) }
                reloaded.endCursor = page.endCursor
                reloaded.hasNextPage = page.hasNextPage
            } while reloaded.hasNextPage && reloaded.keys.count < existing.keys.count
        } catch {
            return
        }
        // Skip the result when more pages were loaded meanwhile.
        guard let current = issueLists[repository], !current.isLoading, current.keys.count == existing.keys.count else { return }
        for page in pages { store(page, of: repository, startedAt: started) }
        // An issue that left the loaded part of the list keeps its record. It loads whether it closed.
        let staying = Set(reloaded.keys)
        for leaving in existing.keys where !staying.contains(leaving) { Task { await refetch(leaving) } }
        issueLists[repository] = reloaded
    }

    /// Writes an issue page's issues and its repository, which carries the open issue count.
    ///
    /// Records are keyed by the repository that was asked for, which the list uses too. GitHub
    /// answers for a renamed repository under its new name, and that record isn't the one the
    /// sidebar reads, so it is left alone.
    private func store(_ page: IssuePage, of repository: RepositoryRef, startedAt: Date) {
        for issue in page.items { issues[ItemKey(repository: repository, number: issue.number)] = issue }
        if page.repository.ref == repository { store(page.repository, startedAt: startedAt) }
    }
}

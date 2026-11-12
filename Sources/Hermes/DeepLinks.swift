import Foundation
import GitHubKit

extension WindowModel {
    /// Shows what a `hermes://` link names. When the link's owner is one of
    /// the viewer's accounts, that account is selected first.
    func open(_ link: DeepLink) async {
        guard case .ready(let viewer) = startup else {
            pendingLink = link
            return
        }
        let repository = link.repository
        if let owner = viewer.accounts.first(where: { $0.login.caseInsensitiveCompare(repository.owner) == .orderedSame }) {
            select(owner)
        }

        switch link {
        case .repository:
            reveal(repository, list: .pullRequests)
        case .issue(_, let number, let comment):
            commentToShow = comment
            await open(ItemKey(repository: repository, number: number))
        case .pullRequest(_, let number, let target):
            await openPullRequest(ItemKey(repository: repository, number: number), target: target)
        case .stack(_, let number):
            do {
                guard let bottom = try await client.stackPullRequests(repository: repository, number: number).first else {
                    resolveError = "Stack \(number) in \(repository) has no pull requests."
                    return
                }
                await openPullRequest(ItemKey(repository: repository, number: bottom), target: nil)
            } catch {
                resolveError = "Could not open stack \(number) in \(repository): \(describe(error))"
            }
        }
    }

    private func openPullRequest(_ key: ItemKey, target: DeepLink.PullRequestTarget?) async {
        switch target {
        case .comment(let id):
            commentToShow = id
            await open(key)
            pullRequestTab = .conversation
        case .reviewComment, .file:
            diffTarget = target
            await open(key)
            pullRequestTab = .files
        case .files:
            await open(key)
            pullRequestTab = .files
        case nil:
            await open(key)
        }
    }
}

extension DeepLink {
    /// What the link names, such as `octo/app#12` or `octo/app stack 97`.
    var title: String {
        switch self {
        case .repository(let repository): "\(repository)"
        case .issue(let repository, let number, _), .pullRequest(let repository, let number, _): "\(repository)#\(number)"
        case .stack(let repository, let number): "\(repository) stack \(number)"
        }
    }

    /// The link's path after `hermes://`, without what it points at inside the page.
    var path: String {
        switch self {
        case .repository(let repository): "\(repository)"
        case .issue(let repository, let number, _): "\(repository)/issues/\(number)"
        case .pullRequest(let repository, let number, _): "\(repository)/pull/\(number)"
        case .stack(let repository, let number): "\(repository)/stack/\(number)"
        }
    }

    /// The repository the link is in.
    var repository: RepositoryRef {
        switch self {
        case .repository(let repository), .issue(let repository, _, _), .pullRequest(let repository, _, _),
             .stack(let repository, _):
            repository
        }
    }
}

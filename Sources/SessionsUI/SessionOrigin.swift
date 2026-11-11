import Foundation
import GitHubKit
import RepoKit

/// What a Claude Code session was started from.
public enum SessionOrigin: Hashable, Sendable {
    case pullRequest(repository: RepositoryRef, number: Int, title: String, headRefName: String, baseRefName: String, url: URL)
    case issue(repository: RepositoryRef, number: Int, title: String, url: URL)

    public var repository: RepositoryRef {
        switch self {
        case let .pullRequest(repository, _, _, _, _, _), let .issue(repository, _, _, _): repository
        }
    }

    public var number: Int {
        switch self {
        case let .pullRequest(_, number, _, _, _, _), let .issue(_, number, _, _): number
        }
    }

    public var title: String {
        switch self {
        case let .pullRequest(_, _, title, _, _, _), let .issue(_, _, title, _): title
        }
    }

    public var url: URL {
        switch self {
        case let .pullRequest(_, _, _, _, _, url), let .issue(_, _, _, url): url
        }
    }

    /// `name#number`, such as `airway#94`.
    public var reference: String { "\(repository.name)#\(number)" }

    /// The branch a local session works on: the pull request's head branch,
    /// or a new `issue-<number>-<slug>` branch for an issue.
    public var branchName: String {
        switch self {
        case let .pullRequest(_, _, _, headRefName, _, _): headRefName
        case let .issue(_, number, title, _): issueBranchName(number: number, title: title)
        }
    }

    /// The prompt the launch sheet starts with.
    public var defaultPrompt: String {
        switch self {
        case let .pullRequest(_, _, _, headRefName, _, url):
            """
            Review the pull request at \(url.absoluteString) and continue the work on it. \
            Address open review comments and failing checks, and push your commits to its branch `\(headRefName)`.
            """
        case let .issue(_, number, _, url):
            """
            Implement the issue at \(url.absoluteString). \
            When the work is done, push the branch and open a pull request whose body says "Fixes #\(number)".
            """
        }
    }

    /// The session name the launch sheet starts with.
    public var defaultSessionName: String {
        let name = "\(reference) \(title)"
        return name.count > 60 ? String(name.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : name
    }

    var repoID: RepoID { RepoID(owner: repository.owner, name: repository.name) }

    var symbolName: String {
        switch self {
        case .pullRequest: "arrow.triangle.pull"
        case .issue: "smallcircle.filled.circle"
        }
    }

    var kindLabel: String {
        switch self {
        case .pullRequest: "Pull request"
        case .issue: "Issue"
        }
    }
}

/// `issue-<number>-<slug>`, where the slug is the first few words of the
/// title in lowercase ASCII joined by `-`. A title with no usable words
/// gives `issue-<number>`.
func issueBranchName(number: Int, title: String) -> String {
    let words = title.lowercased()
        .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        .prefix(5)
    var slug = words.joined(separator: "-")
    if slug.count > 40 {
        slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    return slug.isEmpty ? "issue-\(number)" : "issue-\(number)-\(slug)"
}

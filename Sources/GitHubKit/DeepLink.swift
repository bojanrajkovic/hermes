import CryptoKit
import Foundation

/// A place in Hermes named by a link. The links are GitHub's own:
/// `hermes://owner/repo/pull/12` is `https://github.com/owner/repo/pull/12`
/// with the scheme and host swapped, and the github.com form is read too.
public enum DeepLink: Sendable, Hashable {
    case repository(RepositoryRef)
    /// An issue, and a comment on it from an `#issuecomment-<id>` fragment.
    case issue(RepositoryRef, number: Int, comment: Int?)
    case pullRequest(RepositoryRef, number: Int, target: PullRequestTarget?)
    /// A stack of pull requests, by its number in the repository.
    case stack(RepositoryRef, number: Int)

    /// Where in a pull request a link points.
    public enum PullRequestTarget: Sendable, Hashable {
        /// A comment on the conversation: `#issuecomment-<id>`.
        case comment(Int)
        /// A review comment in a thread on the diff: `#discussion_r<id>`, or `/files#r<id>`.
        case reviewComment(Int)
        /// The changed files: `/files` or `/changes`.
        case files
        /// A file, and maybe lines of it: `/files#diff-<hash>R45`.
        case file(pathHash: String, lines: Lines?)
    }

    /// Lines of one side of a file's diff, 1-based and inclusive.
    public struct Lines: Sendable, Hashable {
        public let side: DiffSide
        public let start: Int
        public let end: Int

        public init(side: DiffSide, start: Int, end: Int) {
            self.side = side
            self.start = start
            self.end = end
        }
    }

    /// Reads a `hermes://` or `https://github.com` link. `nil` for anything else.
    public init?(url: URL) {
        let parts: [String]
        switch url.scheme?.lowercased() {
        case "hermes":
            // In `hermes://owner/repo`, the owner is the URL's host.
            guard let host = url.host() else { return nil }
            parts = [host] + url.pathComponents.filter { $0 != "/" }
        case "https" where url.host()?.lowercased() == "github.com", "http" where url.host()?.lowercased() == "github.com":
            parts = url.pathComponents.filter { $0 != "/" }
        default:
            return nil
        }
        guard parts.count >= 2 else { return nil }
        let repository = RepositoryRef(owner: parts[0], name: parts[1])
        let fragment = url.fragment() ?? ""
        guard parts.count >= 4 else {
            guard parts.count == 2 else { return nil }
            self = .repository(repository)
            return
        }
        guard let number = Int(parts[3]), number > 0 else { return nil }
        switch parts[2] {
        case "issues":
            self = .issue(repository, number: number, comment: Self.number(in: fragment, after: "issuecomment-"))
        case "pull":
            let isFiles = parts.count >= 5 && ["files", "changes"].contains(parts[4])
            self = .pullRequest(repository, number: number, target: Self.target(fragment: fragment, isFiles: isFiles))
        case "stack":
            self = .stack(repository, number: number)
        default:
            return nil
        }
    }

    private static func target(fragment: String, isFiles: Bool) -> PullRequestTarget? {
        if let id = number(in: fragment, after: "issuecomment-") { return .comment(id) }
        if let id = number(in: fragment, after: "discussion_r") ?? number(in: fragment, after: "r") { return .reviewComment(id) }
        if fragment.hasPrefix("diff-") {
            let rest = fragment.dropFirst("diff-".count)
            let hash = String(rest.prefix { $0.isHexDigit }).lowercased()
            guard hash.count == 64 else { return isFiles ? .files : nil }
            return .file(pathHash: hash, lines: lines(String(rest.dropFirst(64))))
        }
        return isFiles ? .files : nil
    }

    /// `R45`, `L3`, or `R45-R50`.
    private static func lines(_ text: String) -> Lines? {
        let ends = text.split(separator: "-").map { part -> (DiffSide, Int)? in
            guard let first = part.first, let line = Int(part.dropFirst()), line > 0 else { return nil }
            switch first {
            case "R": return (.right, line)
            case "L": return (.left, line)
            default: return nil
            }
        }
        guard let start = ends.first ?? nil else { return nil }
        let end = ends.count > 1 ? ends[1] : start
        return Lines(side: start.0, start: start.1, end: max(end?.1 ?? start.1, start.1))
    }

    private static func number(in fragment: String, after prefix: String) -> Int? {
        guard fragment.hasPrefix(prefix) else { return nil }
        return Int(fragment.dropFirst(prefix.count))
    }

    /// The hash GitHub names a file by in a `#diff-<hash>` anchor: the SHA-256 of its path, in hex.
    public static func pathHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

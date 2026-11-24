import Foundation
import GitHubKit

/// Where Hermes keeps text the user typed and hasn't sent: one folder per repository under
/// `<root>/drafts/<owner>/<repo>/`, with a file per pull request or issue for each kind of draft.
/// A pending review is `<number>.json`; a conversation comment is `<number>.comment.md`.
/// Each file has one writer, so two screens never overwrite each other's text.
public enum Drafts {
    /// `~/Library/Application Support/Hermes`.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Hermes")
    }

    /// The file for one kind of draft of a pull request or issue: `<root>/drafts/<owner>/<repo>/<number>.<ext>`.
    public static func url(root: URL, repository: RepositoryRef, number: Int, extension ext: String) -> URL {
        root.appending(path: "drafts/\(repository.owner)/\(repository.name)/\(number).\(ext)")
    }

    private static func commentURL(root: URL, key: ItemKey) -> URL {
        url(root: root, repository: key.repository, number: key.number, extension: "comment.md")
    }

    /// The unsent conversation comment of a pull request or issue, as Markdown.
    /// Empty when there is none or the file can't be read.
    public static func comment(root: URL = defaultRoot, key: ItemKey) -> String {
        (try? String(contentsOf: commentURL(root: root, key: key), encoding: .utf8)) ?? ""
    }

    /// Saves the unsent conversation comment, or removes its file when `text` is empty.
    public static func saveComment(_ text: String, root: URL = defaultRoot, key: ItemKey) throws {
        let url = commentURL(root: root, key: key)
        guard !text.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

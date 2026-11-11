import Foundation

/// One line that contains a searched word.
public struct GrepMatch: Hashable, Sendable {
    /// File path relative to the tree's root.
    public let path: String
    /// 1-based line number.
    public let line: Int
    /// The line's text, cut to `SourceTreeLimits.lineLength` characters.
    public let text: String

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

/// Limits on `SourceTree.grep(word:)`, so a common word in a large repository
/// cannot return megabytes of matches.
public enum SourceTreeLimits {
    /// The most matches one `grep(word:)` call returns.
    public static let matches = 500
    /// The most characters kept from a matching line. Minified files have very long lines.
    public static let lineLength = 400
}

/// A readable snapshot of a repository's files: either a commit or a working
/// directory. Go-to-definition searches it with `grep(word:)` and then reads
/// the candidate files.
public protocol SourceTree: Sendable {
    /// Reads a file as UTF-8 text. Invalid bytes become U+FFFD.
    ///
    /// - Parameter path: Path relative to the tree's root.
    /// - Throws: An error if the file does not exist in the tree.
    func readFile(_ path: String) async throws -> String

    /// Lists every file in the tree, as paths relative to its root. A working
    /// directory includes untracked files that are not ignored.
    func listFiles() async throws -> [String]

    /// Finds lines containing `word` as a whole word, case-sensitively.
    /// Binary files and vendored or build directories (`node_modules`,
    /// `vendor`, `Pods`, `.build`, `dist`, `target`) are skipped.
    ///
    /// - Returns: At most `SourceTreeLimits.matches` matches, in path order.
    ///   Empty when `word` is empty.
    func grep(word: String) async throws -> [GrepMatch]
}

/// A commit in a bare clone held by `RepoCache`.
public struct CommitTree: SourceTree, Hashable {
    /// The bare repository that holds the commit.
    public let gitDirectory: URL
    /// The commit's full object ID.
    public let oid: String

    public func readFile(_ path: String) async throws -> String {
        // `cat-file blob` fails on a directory; `git show` would print its listing.
        try await Git.run(["cat-file", "blob", "\(oid):\(path)"], in: gitDirectory).text
    }

    public func listFiles() async throws -> [String] {
        try await Git.run(["ls-tree", "-r", "--name-only", "-z", oid], in: gitDirectory).nulSeparated
    }

    public func grep(word: String) async throws -> [GrepMatch] {
        guard !word.isEmpty else { return [] }
        let output = try await Git.run(grepArguments(word: word, extra: [oid]), in: gitDirectory, accepting: [0, 1])
        return parseGrep(output.text, prefix: "\(oid):")
    }
}

/// Arguments for a whole-word, fixed-string `git grep` with `-z` output.
/// `--no-column` undoes `grep.column`, which would add a field to each record.
func grepArguments(word: String, extra: [String]) -> [String] {
    let skipped = ["node_modules", "vendor", "Pods", ".build", "dist", "target"]
    return ["grep", "-n", "--no-column", "-w", "-I", "-F", "-z", "--no-color", "-e", word] + extra + ["--", "."]
        + skipped.map { ":(exclude,glob)**/\($0)/**" }
}

/// Parses `git grep -n -z` output: one `path NUL line NUL text` record per line.
///
/// - Parameter prefix: Text git puts before each path (`<oid>:` when grepping a commit).
func parseGrep(_ output: String, prefix: String = "") -> [GrepMatch] {
    output.split(separator: "\n").prefix(SourceTreeLimits.matches).compactMap { record in
        let fields = record.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let line = Int(fields[1]), fields[0].hasPrefix(prefix) else { return nil }
        return GrepMatch(
            path: String(fields[0].dropFirst(prefix.count)),
            line: line,
            text: String(fields[2].prefix(SourceTreeLimits.lineLength))
        )
    }
}

/// A parsed git unified diff: one entry per changed file, in the order the diff lists them.
public struct Diff: Sendable, Hashable {
    /// The changed files, in diff order.
    public let files: [FileDiff]

    /// Parses the output of `git diff` or GitHub's `application/vnd.github.diff`.
    ///
    /// Parsing never fails. Text before the first `diff --git` line is ignored,
    /// and a hunk that ends early keeps the lines it has. Combined merge diffs
    /// (`diff --cc`) are skipped.
    ///
    /// - Parameter text: The diff text. Paths must use git's default `a/` and
    ///   `b/` prefixes.
    public init(parsing text: String) {
        files = DiffParser.parse(text)
    }
}

/// What happened to a file, with the paths that apply to that kind of change.
public enum FileChange: Sendable, Hashable {
    case added(path: String)
    case deleted(path: String)
    /// Content or mode changed in place.
    case modified(path: String)
    case renamed(from: String, to: String)
    case copied(from: String, to: String)
}

extension FileChange {
    /// The new path, or the old path of a deleted file.
    var path: String {
        switch self {
        case .added(let path), .deleted(let path), .modified(let path): path
        case .renamed(_, let to), .copied(_, let to): to
        }
    }
}

/// The body of a file's diff.
public enum FileContent: Sendable, Hashable {
    /// Text hunks. Empty for a pure rename, a pure mode change, and an empty file.
    case text([Hunk])
    /// Git reported the file as binary, so there are no lines.
    case binary
}

/// One file's entry in a diff.
public struct FileDiff: Sendable, Hashable, Identifiable {
    /// Unique within a diff, and the same when the diff is parsed again.
    ///
    /// Equal to `path`, except for the second entry of a type change: git
    /// writes a file that became a symlink (or the reverse) as a deleted entry
    /// and an added entry with the same path, and the added entry's `id` gets
    /// a suffix.
    public let id: String
    public let change: FileChange
    public let content: FileContent
    /// The file mode before the change, such as `100644`. `nil` for an added
    /// file, or when the diff does not state a mode.
    public let oldMode: String?
    /// The file mode after the change. `nil` for a deleted file, or when the
    /// diff does not state a mode.
    public let newMode: String?
    /// The number of added lines across all hunks.
    public let additions: Int
    /// The number of deleted lines across all hunks.
    public let deletions: Int

    /// The path before the change. `nil` for an added file.
    public var oldPath: String? {
        switch change {
        case .added: nil
        case .deleted(let path), .modified(let path): path
        case .renamed(let from, _), .copied(let from, _): from
        }
    }

    /// The path after the change. `nil` for a deleted file.
    public var newPath: String? {
        switch change {
        case .deleted: nil
        case .added(let path), .modified(let path): path
        case .renamed(_, let to), .copied(_, let to): to
        }
    }

    /// The path GitHub uses for the file: the new path, or the old path of a
    /// deleted file. Review comments on either side use this path.
    public var path: String { change.path }

    /// The text hunks, or an empty array for a binary file.
    public var hunks: [Hunk] {
        if case .text(let hunks) = content { hunks } else { [] }
    }

    /// Whether the mode changed on a file that existed before and after.
    public var isModeChange: Bool {
        if let oldMode, let newMode { oldMode != newMode } else { false }
    }
}

/// A contiguous block of a file's diff, introduced by an `@@ -a,b +c,d @@` line.
public struct Hunk: Sendable, Hashable {
    /// The first old line the hunk covers. When `oldCount` is 0, the line
    /// before the insertion point (0 at the top of the file).
    public let oldStart: Int
    /// The number of old lines the hunk covers (context plus deletions).
    public let oldCount: Int
    /// The first new line the hunk covers. When `newCount` is 0, the line
    /// before the deletion point.
    public let newStart: Int
    /// The number of new lines the hunk covers (context plus additions).
    public let newCount: Int
    /// The text git prints after the closing `@@`, usually the enclosing
    /// function. Empty when there is none.
    public let sectionHeading: String
    public let lines: [DiffLine]
}

/// How a line ends in the file.
public enum LineEnding: Sendable, Hashable {
    case lf
    case crlf
    /// The last line of a file with no trailing newline
    /// (`\ No newline at end of file`).
    case none
}

/// One line of a diff.
public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case context, addition, deletion
    }

    /// The line's kind together with the line numbers that kind has.
    public enum Numbers: Sendable, Hashable {
        case context(old: Int, new: Int)
        case addition(new: Int)
        case deletion(old: Int)
    }

    public let numbers: Numbers
    /// The line's content without the leading `+`, `-`, or space and without
    /// its line ending.
    public let text: String
    public let ending: LineEnding

    public var kind: Kind {
        switch numbers {
        case .context: .context
        case .addition: .addition
        case .deletion: .deletion
        }
    }

    /// The 1-based line number in the old file. `nil` for an addition.
    public var oldNumber: Int? {
        switch numbers {
        case .context(let old, _), .deletion(let old): old
        case .addition: nil
        }
    }

    /// The 1-based line number in the new file. `nil` for a deletion.
    public var newNumber: Int? {
        switch numbers {
        case .context(_, let new), .addition(let new): new
        case .deletion: nil
        }
    }

    /// `numbers`. It is unique within a file, including lines revealed by
    /// context expansion.
    public var id: Numbers { numbers }
}

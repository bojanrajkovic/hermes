/// The side of a diff a review comment sits on, with GitHub's API spelling as the raw value.
public enum DiffSide: String, Sendable, Hashable {
    /// The old file. Line numbers are old line numbers.
    case left = "LEFT"
    /// The new file. Line numbers are new line numbers.
    case right = "RIGHT"
}

/// A line on one side of a file's diff.
public struct DiffPosition: Sendable, Hashable {
    public let side: DiffSide
    /// The 1-based line number in the old file (`left`) or new file (`right`).
    public let line: Int

    public init(side: DiffSide, line: Int) {
        self.side = side
        self.line = line
    }
}

/// Where a review comment attaches, in GitHub's model.
///
/// `end` maps to the API's `line` and `side`. `start` maps to `start_line` and
/// `start_side`, and is `nil` for a single-line comment.
public struct CommentAnchor: Sendable, Hashable {
    /// The file's path in the diff: `FileDiff.path`.
    public let path: String
    /// The first line of a multi-line comment.
    public let start: DiffPosition?
    /// The comment's line, or the last line of a multi-line comment.
    public let end: DiffPosition

    public init(path: String, start: DiffPosition? = nil, end: DiffPosition) {
        self.path = path
        self.start = start
        self.end = end
    }
}

/// The index of a line within a file's diff.
public struct LineLocation: Sendable, Hashable, Comparable {
    /// An index into `FileDiff.hunks`.
    public let hunkIndex: Int
    /// An index into that hunk's `lines`.
    public let lineIndex: Int

    public static func < (lhs: LineLocation, rhs: LineLocation) -> Bool {
        (lhs.hunkIndex, lhs.lineIndex) < (rhs.hunkIndex, rhs.lineIndex)
    }
}

/// Why two positions cannot form a multi-line comment.
public enum RangeSelectionError: Error, Sendable, Hashable {
    /// The position is not a line of any hunk. GitHub only accepts comments on
    /// lines the diff shows, so lines revealed by context expansion do not count.
    case notInDiff(DiffPosition)
    /// The positions are in different hunks. GitHub rejects such a range with
    /// "start_line must be part of the same hunk as the line".
    case differentHunks
}

extension DiffLine {
    /// The position a comment on this line gets by default: a deletion is on
    /// the left with its old number, an addition or context line is on the
    /// right with its new number.
    public var commentPosition: DiffPosition {
        switch numbers {
        case .deletion(let old): DiffPosition(side: .left, line: old)
        case .addition(let new), .context(_, let new): DiffPosition(side: .right, line: new)
        }
    }
}

extension FileDiff {
    /// The anchor for a single-line comment on `line`.
    public func anchor(for line: DiffLine) -> CommentAnchor {
        CommentAnchor(path: path, end: line.commentPosition)
    }

    /// The anchor for a comment on the lines from `first` to `second`.
    ///
    /// GitHub accepts a range when both ends are lines of the same hunk and
    /// the start comes before the end in the diff. The ends may be on
    /// different sides. This function takes the ends in either order, so a
    /// selection dragged upward works. Two positions on the same line give a
    /// single-line anchor.
    ///
    /// - Throws: `RangeSelectionError` when an end is not in the diff or the
    ///   ends are in different hunks.
    public func rangeAnchor(from first: DiffPosition, to second: DiffPosition) throws(RangeSelectionError) -> CommentAnchor {
        guard let a = location(of: first) else { throw .notInDiff(first) }
        guard let b = location(of: second) else { throw .notInDiff(second) }
        guard a.hunkIndex == b.hunkIndex else { throw .differentHunks }
        if a == b { return CommentAnchor(path: path, end: second) }
        return a < b
            ? CommentAnchor(path: path, start: first, end: second)
            : CommentAnchor(path: path, start: second, end: first)
    }

    /// Finds the diff line at `position`.
    ///
    /// A context line is found from either side: by its old number on the left
    /// and its new number on the right.
    ///
    /// - Returns: `nil` when no hunk contains the line.
    public func location(of position: DiffPosition) -> LineLocation? {
        for (hunkIndex, hunk) in hunks.enumerated() {
            let covered = switch position.side {
            case .left: hunk.oldStart..<(hunk.oldStart + hunk.oldCount)
            case .right: hunk.newStart..<(hunk.newStart + hunk.newCount)
            }
            guard covered.contains(position.line) else { continue }
            let lineIndex = hunk.lines.firstIndex {
                (position.side == .left ? $0.oldNumber : $0.newNumber) == position.line
            }
            return lineIndex.map { LineLocation(hunkIndex: hunkIndex, lineIndex: $0) }
        }
        return nil
    }
}

/// A review thread and the diff line it sits on.
public struct PlacedThread<Thread> {
    public let thread: Thread
    /// The `id` of the file the thread is in.
    public let fileID: FileDiff.ID
    /// The first line of a multi-line thread. `nil` for a single-line thread,
    /// and when the start line is not in the diff.
    public let start: LineLocation?
    /// The line the thread is shown under.
    public let end: LineLocation
}

/// The result of matching review threads against a diff.
public struct ThreadPlacement<Thread> {
    /// Threads whose line is in the diff, in input order.
    public let placed: [PlacedThread<Thread>]
    /// Threads with no anchor, or whose file or line is not in the diff. These
    /// are outdated threads, and threads on lines outside every hunk.
    public let unplaced: [Thread]
}

extension PlacedThread: Sendable where Thread: Sendable {}
extension ThreadPlacement: Sendable where Thread: Sendable {}
extension PlacedThread: Equatable where Thread: Equatable {}
extension ThreadPlacement: Equatable where Thread: Equatable {}

extension Diff {
    /// Matches review threads to diff lines.
    ///
    /// - Parameters:
    ///   - threads: The threads to place.
    ///   - anchor: Returns a thread's current anchor, or `nil` for a thread
    ///     GitHub reports as outdated (its `line` is null).
    /// - Returns: The placed threads with their locations, and the rest as unplaced.
    public func place<Thread>(_ threads: [Thread], anchor: (Thread) -> CommentAnchor?) -> ThreadPlacement<Thread> {
        // A type change gives two entries with one path, so try each.
        let filesByPath = Dictionary(grouping: files, by: \.path)
        var placed: [PlacedThread<Thread>] = []
        var unplaced: [Thread] = []
        for thread in threads {
            guard let anchor = anchor(thread),
                  let (file, end) = filesByPath[anchor.path]?.lazy
                      .compactMap({ file in file.location(of: anchor.end).map { (file, $0) } }).first
            else {
                unplaced.append(thread)
                continue
            }
            let start = anchor.start.flatMap(file.location(of:))
            placed.append(PlacedThread(thread: thread, fileID: file.id, start: start, end: end))
        }
        return ThreadPlacement(placed: placed, unplaced: unplaced)
    }
}

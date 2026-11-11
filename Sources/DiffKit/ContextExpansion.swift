/// How much of a hidden region to reveal.
public enum Expansion: Sendable, Hashable {
    /// Reveal up to this many lines from the top of the region, extending the hunk above it.
    case down(Int)
    /// Reveal up to this many lines from the bottom of the region, extending the hunk below it.
    case up(Int)
    case all
}

/// Unchanged lines the diff leaves out: before the first hunk, between two
/// hunks, or after the last hunk.
public struct HiddenRegion: Sendable, Hashable {
    /// The region sits directly before `hunks[hunkIndex]`. A value equal to
    /// `hunks.count` means it follows the last hunk.
    public let hunkIndex: Int
    /// The lines still hidden, as context lines in file order.
    public private(set) var lines: [DiffLine]

    init(hunkIndex: Int, lines: [DiffLine]) {
        self.hunkIndex = hunkIndex
        self.lines = lines
    }

    /// Removes lines from the region and returns them for display.
    ///
    /// - Returns: The revealed lines in file order. Fewer than asked for when
    ///   the region is smaller, and empty once nothing is hidden.
    public mutating func expand(_ expansion: Expansion) -> [DiffLine] {
        let revealed: [DiffLine]
        switch expansion {
        case .down(let count):
            revealed = Array(lines.prefix(max(count, 0)))
            lines.removeFirst(revealed.count)
        case .up(let count):
            revealed = Array(lines.suffix(max(count, 0)))
            lines.removeLast(revealed.count)
        case .all:
            revealed = lines
            lines = []
        }
        return revealed
    }
}

extension FileDiff {
    /// The unchanged lines the diff does not show, taken from the file's full new text.
    ///
    /// Each line is a context line with its old and new numbers. A file with
    /// no hunks (a pure rename or mode change) gives one region holding the
    /// whole file.
    ///
    /// - Parameter newText: The file's full content at the diff's new side.
    /// - Returns: The non-empty regions in file order. Empty for deleted and
    ///   binary files, and when the hunks already cover the file.
    public func hiddenRegions(newText: String) -> [HiddenRegion] {
        guard case .text(let hunks) = content, newPath != nil else { return [] }
        let fileLines = lines(of: newText)
        var regions: [HiddenRegion] = []
        var nextNew = 1
        // Old number minus new number for unchanged lines at this point in the file.
        var offset = 0

        func addRegion(before hunkIndex: Int, upTo endNew: Int) {
            let range = nextNew..<max(nextNew, min(endNew, fileLines.count + 1))
            guard !range.isEmpty else { return }
            let lines = range.map { new in
                DiffLine(numbers: .context(old: new + offset, new: new), text: fileLines[new - 1].text, ending: fileLines[new - 1].ending)
            }
            regions.append(HiddenRegion(hunkIndex: hunkIndex, lines: lines))
        }

        for (index, hunk) in hunks.enumerated() {
            // With a count of 0, the start is the line before the change, not the first line of it.
            addRegion(before: index, upTo: hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart)
            nextNew = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart + hunk.newCount
            let nextOld = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart + hunk.oldCount
            offset = nextOld - nextNew
        }
        addRegion(before: hunks.count, upTo: .max)
        return regions
    }
}

/// Splits file text into lines the way git does: a trailing newline ends the
/// last line and does not start an empty one.
private func lines(of text: String) -> [(text: String, ending: LineEnding)] {
    var result: [(String, LineEnding)] = []
    var rest = text.utf8[...]
    while !rest.isEmpty {
        var line = rest
        var ending = LineEnding.none
        if let newline = rest.firstIndex(of: 0x0A) {
            line = rest[..<newline]
            rest = rest[rest.index(after: newline)...]
            ending = .lf
            if line.last == 0x0D {
                line = line.dropLast()
                ending = .crlf
            }
        } else {
            rest = rest[rest.endIndex...]
        }
        result.append((String(Substring(line)), ending))
    }
    return result
}

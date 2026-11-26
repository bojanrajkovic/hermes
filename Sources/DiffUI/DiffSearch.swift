import DiffKit
import Foundation
import Observation

/// The find bar's query, its matches, and the match on screen.
@Observable @MainActor
final class DiffFind {
    var isShown = false
    var query = ""
    private(set) var matches: [DiffMatch] = []
    /// The index of the match on screen.
    private(set) var current: Int?
    /// The matches on each line, for the cells to draw.
    private(set) var ranges: [FileDiff.ID: [DiffLine.Numbers: [Range<Int>]]] = [:]
    /// The query `matches` were found for.
    @ObservationIgnored private(set) var searchedQuery = ""

    var currentMatch: DiffMatch? { current.map { matches[$0] } }

    /// Stores the matches for `query`. A new query moves to its first match. The same query, searched
    /// again after the rows changed, keeps the match on screen when it still exists.
    /// - Returns: The match to scroll to, if it changed.
    func show(_ found: [DiffMatch], for query: String) -> DiffMatch? {
        let previous = currentMatch
        let isNewQuery = query != searchedQuery
        searchedQuery = query
        matches = found
        ranges = found.reduce(into: [:]) { $0[$1.row.file, default: [:]][$1.line, default: []].append($1.range) }
        // Match on file, line, and range instead of row ID. A split row's ID names its new side, so a
        // removed line's row ID changes with the layout.
        current = isNewQuery ? nil : previous.flatMap { previous in
            found.firstIndex { $0.row.file == previous.row.file && $0.line == previous.line && $0.range == previous.range }
        }
        return isNewQuery ? step(by: 1) : nil
    }

    /// Moves to the next (`1`) or previous (`-1`) match, wrapping around.
    /// - Returns: The match to scroll to.
    func step(by offset: Int) -> DiffMatch? {
        guard !matches.isEmpty else { return nil }
        current = ((current ?? (offset > 0 ? -1 : 0)) + offset + matches.count) % matches.count
        return currentMatch
    }

    /// Clears the query and its matches, and hides the bar.
    func close() {
        isShown = false
        query = ""
        _ = show([], for: "")
    }
}

/// The find ranges to draw on one side of a code line.
struct FoundRanges: Equatable {
    /// UTF-16 ranges in the line's text.
    var all: [Range<Int>] = []
    /// The match on screen, when it is on this line.
    var current: Range<Int>?
}

/// One occurrence of the find query in a code line of the diff.
struct DiffMatch: Hashable, Sendable {
    /// The row that shows the line. In a split row, the row's ID can name the other side's line.
    let row: RowID
    let line: DiffLine.Numbers
    /// UTF-16 offsets in the line's text.
    let range: Range<Int>
}

enum DiffSearch {
    /// Returns every occurrence of `query` in the code lines of `files`, ignoring case and
    /// diacritics, in the order the list shows them. Each element of `files` is one file's rows. A context line
    /// that a split row shows on both sides counts once.
    static func matches(of query: String, in files: [[DiffRow]]) -> [DiffMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [DiffMatch] = []
        for row in files.joined() {
            for cell in row.cells {
                let text = cell.line.text as NSString
                var searchRange = NSRange(location: 0, length: text.length)
                while searchRange.length > 0 {
                    let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                    guard found.location != NSNotFound else { break }
                    matches.append(DiffMatch(row: row.id, line: cell.line.numbers, range: found.location..<found.upperBound))
                    searchRange = NSRange(location: found.upperBound, length: text.length - found.upperBound)
                }
            }
        }
        return matches
    }
}

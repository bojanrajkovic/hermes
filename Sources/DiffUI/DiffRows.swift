import DiffKit
import Foundation

/// How changed lines are arranged.
public enum DiffLayout: String, Sendable, Hashable, CaseIterable {
    /// One column: deletions above the additions that replace them.
    case unified
    /// Two columns: the old file on the left, the new file on the right.
    case split
}

/// Identifies a row in the diff list. Stable across reloads, so the table keeps
/// rows, their measured heights, and the scroll position when the diff changes around them.
struct RowID: Hashable, Sendable {
    enum Item: Hashable, Sendable {
        /// The file's sticky header.
        case header
        /// A code line. A split row uses its new-side line, or the old-side
        /// line when it has no new side, so most IDs are the same in both layouts.
        case line(DiffLine.Numbers)
        /// The header above the hunk that starts at these lines.
        case hunk(oldStart: Int, newStart: Int)
        /// The expander after the last hunk.
        case end
        case notice(Int)
        /// The file's rendered Markdown, shown in place of its lines.
        case rendered
        /// The gap after the file.
        case spacer
    }

    let file: FileDiff.ID
    let item: Item
}

/// One code line with its styled text.
struct LineCell: Hashable, Sendable {
    let line: DiffLine
    let text: AttributedString
}

/// The row above a hunk (or after the last one). It shows the `@@` range and
/// the controls that reveal the unchanged lines hidden at that point.
struct HunkHeader: Hashable, Sendable {
    /// Index of the hidden region: the hunk the row sits above, or
    /// `hunks.count` for the row after the last hunk.
    let region: Int
    /// `@@ -1,5 +1,7 @@`, or empty for the row after the last hunk.
    let range: String
    /// The enclosing function git printed after the range. May be empty.
    let heading: String
    /// Unchanged lines still hidden here. 0 until the file's text is loaded.
    let hidden: Int
    /// Whether lines can be revealed toward the hunk above (false at the top of the file).
    let canExpandDown: Bool
    /// Whether lines can be revealed toward the hunk below (false after the last hunk).
    let canExpandUp: Bool
}

/// What a file shows in place of, or above, its lines.
enum FileNotice: Hashable, Sendable {
    case binary
    case renamed(from: String, to: String)
    case copied(from: String, to: String)
    case modeChanged(old: String, new: String)
    case empty
    /// The diff is long, so it is not rendered until the user asks.
    case large(lines: Int)
}

struct DiffRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case hunk(HunkHeader)
        case unified(LineCell)
        case split(old: LineCell?, new: LineCell?)
        case notice(FileNotice)
    }

    let id: RowID
    let kind: Kind

    /// The row's code lines: one, the two sides of a split row, or none. A context line of a split row counts once.
    var cells: [LineCell] {
        switch kind {
        case .unified(let cell): [cell]
        case .split(let old, let new): old == new ? [old].compactMap { $0 } : [old, new].compactMap { $0 }
        case .hunk, .notice: []
        }
    }
}

/// The unchanged lines of one file that the user has revealed, and those still hidden.
struct FileExpansion: Hashable, Sendable {
    /// Hidden lines by region index. Empty until the file's text is loaded.
    private(set) var regions: [Int: HiddenRegion] = [:]
    /// Lines revealed from the top of a region. They follow the hunk above it.
    private(set) var top: [Int: [DiffLine]] = [:]
    /// Lines revealed from the bottom of a region. They lead into the hunk below it.
    private(set) var bottom: [Int: [DiffLine]] = [:]

    init() {}

    init(regions: [HiddenRegion]) {
        self.regions = Dictionary(regions.map { ($0.hunkIndex, $0) }) { first, _ in first }
    }

    func hidden(in region: Int) -> Int { regions[region]?.lines.count ?? 0 }

    /// Reveals lines of a region.
    ///
    /// - Returns: The lines that became visible, for styling.
    @discardableResult
    mutating func expand(region: Int, _ expansion: Expansion) -> [DiffLine] {
        guard let revealed = regions[region]?.expand(expansion), !revealed.isEmpty else { return [] }
        if case .up = expansion {
            bottom[region] = revealed + (bottom[region] ?? [])
        } else {
            top[region, default: []] += revealed
        }
        return revealed
    }

    /// Whether any line of the region has been revealed.
    func isOpened(_ region: Int) -> Bool { top[region] != nil || bottom[region] != nil }
}

/// A file with more diff lines than this is collapsed behind a "Load diff" button.
let largeFileLineLimit = 2_000

/// Builds the rows of one file.
///
/// Per region `r` and the hunk below it, the order is: lines revealed from
/// the region's top, the hunk header, lines revealed from the region's
/// bottom, then the hunk's own lines.
///
/// - Parameters:
///   - showsLargeDiff: Whether the user asked to see a diff over ``largeFileLineLimit``.
///   - text: The styled text of a line.
func diffRows(
    file: FileDiff, expansion: FileExpansion, layout: DiffLayout, showsLargeDiff: Bool = false,
    text: (DiffLine) -> AttributedString
) -> [DiffRow] {
    func row(_ item: RowID.Item, _ kind: DiffRow.Kind) -> DiffRow {
        DiffRow(id: RowID(file: file.id, item: item), kind: kind)
    }
    func cell(_ line: DiffLine) -> LineCell { LineCell(line: line, text: text(line)) }
    func context(_ lines: [DiffLine]) -> [DiffRow] {
        lines.map { line in
            row(.line(line.numbers), layout == .unified ? .unified(cell(line)) : .split(old: cell(line), new: cell(line)))
        }
    }

    var rows: [DiffRow] = []
    var notices: [FileNotice] = []
    switch file.change {
    case .renamed(let from, let to) where file.hunks.isEmpty: notices.append(.renamed(from: from, to: to))
    case .copied(let from, let to) where file.hunks.isEmpty: notices.append(.copied(from: from, to: to))
    default: break
    }
    if file.isModeChange, let old = file.oldMode, let new = file.newMode {
        notices.append(.modeChanged(old: old, new: new))
    }
    if file.content == .binary {
        notices.append(.binary)
    } else if file.hunks.isEmpty, notices.isEmpty {
        notices.append(.empty)
    }
    let lineCount = file.hunks.reduce(0) { $0 + $1.lines.count }
    let isHeldBack = lineCount > largeFileLineLimit && !showsLargeDiff
    if isHeldBack { notices.append(.large(lines: lineCount)) }
    rows += notices.enumerated().map { row(.notice($0.offset), .notice($0.element)) }
    guard !isHeldBack else { return rows }

    let hunks = file.hunks
    for region in 0...hunks.count {
        rows += context(expansion.top[region] ?? [])

        let hidden = expansion.hidden(in: region)
        if region < hunks.count {
            let hunk = hunks[region]
            // Once a region is fully revealed, its hunks read as one block.
            if hidden > 0 || !expansion.isOpened(region) {
                // Revealed lines make the hunk start earlier than its range says, so the range goes.
                let isOpened = expansion.isOpened(region)
                let header = HunkHeader(
                    region: region,
                    range: isOpened ? "" : "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@",
                    heading: isOpened ? "" : hunk.sectionHeading, hidden: hidden,
                    canExpandDown: region > 0, canExpandUp: true
                )
                rows.append(row(.hunk(oldStart: hunk.oldStart, newStart: hunk.newStart), .hunk(header)))
            }
            rows += context(expansion.bottom[region] ?? [])
            switch layout {
            case .unified:
                rows += hunk.lines.map { row(.line($0.numbers), .unified(cell($0))) }
            case .split:
                rows += hunk.splitRows.compactMap { pair in
                    guard let anchor = pair.new ?? pair.old else { return nil }
                    return row(.line(anchor.numbers), .split(old: pair.old.map(cell), new: pair.new.map(cell)))
                }
            }
        } else if hidden > 0 {
            let header = HunkHeader(
                region: region, range: "", heading: "", hidden: hidden,
                canExpandDown: !hunks.isEmpty, canExpandUp: false
            )
            rows.append(row(.end, .hunk(header)))
        }
    }
    return rows
}

import AppKit
import DiffKit
import SwiftUI

/// One row of the diff table: a file's header, one of its diff rows, its rendered Markdown, or the gap after it.
struct DiffTableRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case header
        /// A diff row and the digits its gutter fits.
        case line(DiffRow, digits: Int)
        case rendered
        case spacer
    }

    let id: RowID
    let kind: Kind
    let file: FileModel

    /// The diff row and its gutter digits when this is a code line, which the table draws itself.
    var codeLine: (row: DiffRow, digits: Int)? {
        guard case .line(let row, let digits) = kind else { return nil }
        switch row.kind {
        case .unified, .split: return (row, digits)
        case .hunk, .notice: return nil
        }
    }

    nonisolated static func == (lhs: DiffTableRow, rhs: DiffTableRow) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.file === rhs.file
    }
}

/// The rows of the diff table, top to bottom: per file its header, then its
/// lines or its rendered Markdown unless the file is collapsed, then a spacer.
@MainActor
func tableRows(files: [FileModel]) -> [DiffTableRow] {
    var rows: [DiffTableRow] = []
    rows.reserveCapacity(files.reduce(0) { $0 + $1.rows.count + 2 })
    for file in files {
        func row(_ item: RowID.Item, _ kind: DiffTableRow.Kind) -> DiffTableRow {
            DiffTableRow(id: RowID(file: file.id, item: item), kind: kind, file: file)
        }
        rows.append(row(.header, .header))
        if !file.isCollapsed, file.showsRendered {
            rows.append(row(.rendered, .rendered))
        } else if !file.isCollapsed {
            let digits = file.gutterDigits
            for line in file.rows {
                rows.append(DiffTableRow(id: line.id, kind: .line(line, digits: digits), file: file))
            }
        }
        rows.append(row(.spacer, .spacer))
    }
    return rows
}

/// The row indexes to remove from the old list and to insert into the new one.
struct RowChanges: Equatable {
    var removed = IndexSet()
    var inserted = IndexSet()
}

/// What turns the rows `old` into `new` by removing and inserting only.
///
/// - Returns: `nil` when rows that stay changed their order, or an ID repeats. The table then reloads.
func rowChanges(from old: [RowID], to new: [RowID]) -> RowChanges? {
    let oldSet = Set(old)
    let newSet = Set(new)
    guard oldSet.count == old.count, newSet.count == new.count else { return nil }
    var changes = RowChanges()
    for (index, id) in old.enumerated() where !newSet.contains(id) { changes.removed.insert(index) }
    for (index, id) in new.enumerated() where !oldSet.contains(id) { changes.inserted.insert(index) }
    let kept = old.lazy.filter(newSet.contains)
    guard kept.elementsEqual(new.lazy.filter(oldSet.contains)) else { return nil }
    return changes
}

/// The height of a row, before it has been on screen when SwiftUI draws it.
///
/// It is exact for a code line, a hunk header, a notice without a button, a
/// file header, and a spacer. Comments and rendered Markdown are estimates
/// that the table replaces with the measured height once the row is shown.
struct RowHeightEstimator: Equatable {
    let metrics: DiffMetrics
    /// A hunk header without and with the buttons that reveal hidden lines.
    let hunkHeight: CGFloat
    let expandableHunkHeight: CGFloat
    let noticeHeight: CGFloat

    /// Measures the heights that follow the code font by laying out one row of each kind.
    @MainActor
    init(metrics: DiffMetrics) {
        func height(_ view: some View) -> CGFloat {
            NSHostingController(rootView: view.environment(\.diffMetrics, metrics))
                .sizeThatFits(in: CGSize(width: 1_000, height: 1_000)).height
        }
        func hunk(hidden: Int) -> HunkHeader {
            HunkHeader(region: 1, range: "@@", heading: "", hidden: hidden, canExpandDown: true, canExpandUp: true)
        }
        let file = FileModel(diff: Diff(parsing: "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,1 +1,1 @@\n a\n").files[0], layout: .unified)
        self.metrics = metrics
        hunkHeight = height(HunkHeaderRow(header: hunk(hidden: 0), file: file))
        expandableHunkHeight = height(HunkHeaderRow(header: hunk(hidden: 100), file: file))
        noticeHeight = height(NoticeRow(notice: .binary) {})
    }

    @MainActor
    func height(of kind: DiffTableRow.Kind, width: CGFloat) -> CGFloat {
        switch kind {
        case .header: DiffMetrics.headerHeight
        case .spacer: DiffMetrics.fileSpacing
        case .rendered: DiffMetrics.renderedMinHeight + 16
        case .line(let row, let digits):
            switch row.kind {
            case .hunk(let header): header.hidden > 0 ? expandableHunkHeight : hunkHeight
            case .notice: noticeHeight
            case .unified, .split: lineRowHeight(lineSides(of: row.kind, digits: digits, width: width, metrics: metrics), metrics: metrics)
            }
        }
    }
}

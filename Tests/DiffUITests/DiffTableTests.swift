import AppKit
import DiffKit
import Foundation
import GitHubKit
import RepoKit
import SwiftUI
import Testing
@testable import DiffUI

private let sample = """
    diff --git a/Sources/App/Greeter.swift b/Sources/App/Greeter.swift
    index 1111111..2222222 100644
    --- a/Sources/App/Greeter.swift
    +++ b/Sources/App/Greeter.swift
    @@ -3,5 +3,6 @@ struct Greeter {
         let name: String

    -    func greet() -> String { "Hello, \\(name)" }
    +    func greet() -> String { "Hello, \\(name)!" }
    +    func part() -> String { "Bye" }

     }
    diff --git a/README.md b/README.md
    index 1111111..2222222 100644
    --- a/README.md
    +++ b/README.md
    @@ -1,2 +1,2 @@
     # Title
    -old
    +new
    diff --git a/logo.png b/logo.png
    index 1111111..2222222 100644
    Binary files a/logo.png and b/logo.png differ

    """

@MainActor
struct DiffTableRowTests {
    private let files = Diff(parsing: sample).files.map { FileModel(diff: $0, layout: .unified) }

    private func outline(_ rows: [DiffTableRow]) -> [String] {
        rows.map { row in
            switch row.kind {
            case .header: "header \(row.id.file)"
            case .line(let line, _): if case .hunk = line.kind { "hunk" } else if case .notice = line.kind { "notice" } else { "line" }
            case .attachments: "attachments"
            case .rendered: "rendered"
            case .spacer: "spacer"
            }
        }
    }

    @Test func eachFileIsAHeaderItsRowsAndASpacer() {
        let rows = tableRows(files: files)
        #expect(outline(rows) == [
            "header Sources/App/Greeter.swift", "hunk", "line", "line", "line", "line", "line", "line", "line", "spacer",
            "header README.md", "hunk", "line", "line", "line", "spacer",
            "header logo.png", "notice", "spacer",
        ])
        #expect(Set(rows.map(\.id)).count == rows.count)
        // A line keeps the ID of its diff row, which the scroll requests use.
        #expect(rows[2].id == files[0].rows[1].id)
        #expect(rows[2].kind == .line(files[0].rows[1], digits: files[0].gutterDigits))
    }

    @Test func aCollapsedFileKeepsItsHeaderAndSpacer() {
        files[0].isCollapsed = true
        files[1].setViewed(true)
        #expect(outline(tableRows(files: files)) == [
            "header Sources/App/Greeter.swift", "spacer", "header README.md", "spacer", "header logo.png", "notice", "spacer",
        ])
    }

    @Test func aRenderedFileShowsOneRowInPlaceOfItsLines() {
        files[1].showsRendered = true
        #expect(outline(tableRows(files: files))[10...12] == ["header README.md", "rendered", "spacer"])
        // Collapsing wins over the rendered view.
        files[1].isCollapsed = true
        #expect(outline(tableRows(files: files))[10...11] == ["header README.md", "spacer"])
    }

    @Test func changesAreTheRowsToRemoveAndInsert() throws {
        let before = tableRows(files: files).map(\.id)
        files[0].isCollapsed = true
        let collapsed = tableRows(files: files).map(\.id)
        #expect(rowChanges(from: before, to: collapsed) == RowChanges(removed: IndexSet(1...8), inserted: []))
        #expect(rowChanges(from: collapsed, to: before) == RowChanges(removed: [], inserted: IndexSet(1...8)))
        #expect(rowChanges(from: before, to: before) == RowChanges())

        // The split layout pairs the deletion with the first addition: one row goes, none is new.
        files[0].isCollapsed = false
        files[0].layout = .split
        let split = try #require(rowChanges(from: before, to: tableRows(files: files).map(\.id)))
        #expect(split.removed.count == 1)
        #expect(split.inserted.isEmpty)
    }

    @Test func reorderedOrRepeatedRowsHaveNoChanges() {
        let ids = tableRows(files: files).map(\.id)
        #expect(rowChanges(from: ids, to: ids.reversed()) == nil)
        #expect(rowChanges(from: ids, to: ids + [ids[0]]) == nil)
    }
}

@MainActor
struct AttachmentRowTests {
    private func outline(_ rows: [DiffTableRow]) -> [String] {
        rows.map { row in
            switch row.kind {
            case .header: "header"
            case .line(let line, _): line.cells.isEmpty ? "other" : "line"
            case .attachments(let line): "attachments \(line.text.trimmingCharacters(in: .whitespaces))"
            case .rendered: "rendered"
            case .spacer: "spacer"
            }
        }
    }

    @Test func commentsAreARowAfterTheirLine() {
        let file = FileModel(diff: Diff(parsing: sample).files[1], layout: .unified)
        let attached: [FileDiff.ID: Set<DiffLine.Numbers>] = [file.id: [.deletion(old: 2), .context(old: 1, new: 1)], "other.swift": [.addition(new: 2)]]
        let rows = tableRows(files: [file], attached: attached)
        #expect(outline(rows) == ["header", "other", "line", "attachments # Title", "line", "attachments old", "line", "spacer"])
        #expect(rows[3].id == RowID(file: file.id, item: .attachments(.context(old: 1, new: 1))))
        #expect(Set(rows.map(\.id)).count == rows.count)
        // Without comments the rows are the lines alone.
        #expect(outline(tableRows(files: [file])) == ["header", "other", "line", "line", "line", "spacer"])
    }

    @Test func aSplitRowHasARowOfCommentsPerSide() {
        let file = FileModel(diff: Diff(parsing: sample).files[1], layout: .split)
        let all: Set<DiffLine.Numbers> = [.context(old: 1, new: 1), .deletion(old: 2), .addition(new: 2)]
        // The context line is one cell on both sides and gets one row. The paired row gets the old side's comments first.
        #expect(outline(tableRows(files: [file], attached: [file.id: all])) == [
            "header", "other", "line", "attachments # Title", "line", "attachments old", "attachments new", "spacer",
        ])
    }

    @Test func aCollapsedFileShowsNoComments() {
        let file = FileModel(diff: Diff(parsing: sample).files[1], layout: .unified)
        file.isCollapsed = true
        #expect(outline(tableRows(files: [file], attached: [file.id: [.addition(new: 2)]])) == ["header", "spacer"])
    }
}

struct ReviewMarksTests {
    private let lines = Diff(parsing: sample).files[0].hunks[0].lines

    @Test func aLineIsMarkedByTheSelectionTheRangesAndTheDragOfItsFile() {
        var marks = ReviewMarks()
        marks.selectionFile = "a.swift"
        marks.selectionLines = [lines[2].numbers]
        marks.rangeLines = ["a.swift": [lines[3].numbers], "b.swift": [lines[4].numbers]]
        marks.dragFile = "a.swift"
        marks.dragLine = lines[2]

        #expect(marks.marks(of: lines[2], in: "a.swift") == LineMarks(isSelected: true, isInRange: false, isDragOrigin: true))
        #expect(marks.marks(of: lines[3], in: "a.swift") == LineMarks(isSelected: false, isInRange: true, isDragOrigin: false))
        #expect(marks.marks(of: lines[4], in: "a.swift") == LineMarks())
        // The same line numbers in another file.
        #expect(marks.marks(of: lines[2], in: "b.swift") == LineMarks())
        #expect(marks.marks(of: lines[4], in: "b.swift") == LineMarks(isSelected: false, isInRange: true, isDragOrigin: false))
    }
}

@MainActor
struct RowHeightTests {
    private let metrics = DiffMetrics()
    private var estimator: RowHeightEstimator { RowHeightEstimator(metrics: metrics) }
    private let file = Diff(parsing: sample).files[0]

    /// A line with `text`, taken from a parsed diff.
    private func cell(text: String, kind: DiffLine.Kind = .context) -> LineCell {
        let marker = switch kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "-"
        }
        let diff = Diff(parsing: "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,1 +1,1 @@\n\(marker)\(text)\n")
        let line = diff.files[0].hunks[0].lines[0]
        return LineCell(line: line, text: LineStyler.plain(line))
    }

    private func cell(_ characters: Int, kind: DiffLine.Kind = .context) -> LineCell {
        cell(text: String(repeating: "x", count: characters), kind: kind)
    }

    private func row(_ kind: DiffRow.Kind) -> DiffTableRow.Kind {
        .line(DiffRow(id: RowID(file: file.id, item: .end), kind: kind), digits: 3)
    }

    /// The width of a list that fits `columns` characters of code beside a unified gutter of 3 digits.
    private func width(columns: Int) -> CGFloat {
        CGFloat(columns) * metrics.characterWidth + metrics.gutterWidth(digits: 3, columns: 2) + metrics.markerWidth + 1
    }

    @Test func aLineThatFitsIsOneLineTall() {
        let one = metrics.lineHeight + 2 * DiffMetrics.rowPadding
        #expect(estimator.height(of: row(.unified(cell(0))), width: width(columns: 80)) == one)
        #expect(estimator.height(of: row(.unified(cell(80))), width: width(columns: 80)) == one)
        #expect(estimator.height(of: row(.unified(cell(81))), width: width(columns: 80)) == one + metrics.lineHeight)
        // Before the table has a width.
        #expect(estimator.height(of: row(.unified(cell(80))), width: 0) == one)
    }

    /// The height SwiftUI gives a view at `width`.
    private func measured(_ view: some View, width: CGFloat, metrics: DiffMetrics) -> CGFloat {
        let controller = NSHostingController(
            rootView: view.frame(maxWidth: .infinity, alignment: .leading).environment(\.diffMetrics, metrics)
        )
        return controller.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
    }

    /// One side of a code line as SwiftUI lays it out: the gutter, then the code in a `Text` that wraps.
    /// The definition pane shows code this way, and the diff's lines keep the same wrapping.
    private func swiftUISide(_ cell: LineCell?, numbers: Int, metrics: DiffMetrics) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let cell {
                Text(verbatim: "1")
                    .frame(width: metrics.gutterWidth(digits: 3, columns: numbers) + metrics.markerWidth, alignment: .trailing)
                Text(cell.text).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
        .padding(.vertical, DiffMetrics.rowPadding)
        .font(metrics.font)
    }

    private static let texts = [
        "", "let a = 1", String(repeating: "x", count: 81), String(repeating: "x", count: 300),
        (0..<60).map { "word\($0)" }.joined(separator: " "),
        "\tlet tabbed = 1\t// " + String(repeating: "tab ", count: 40),
        "let name = \"日本語のテキスト\" // コメント", String(repeating: "日本語 word 🎉 ", count: 30), "print(\"🎉 done 👍🏽 — café ∑ ≠ →\")",
    ]

    /// A line's height comes from its own text layout. It has to be the height SwiftUI's wrapping gives.
    @Test(arguments: [9.0, 11, 12, 13, 14, 15, 16, 20, 24])
    func aCodeLineIsAsTallAsSwiftUILaysItOut(fontSize: Double) {
        let metrics = DiffMetrics(fontSize: fontSize)
        let estimator = RowHeightEstimator(metrics: metrics)
        for text in Self.texts {
            let line = cell(text: text, kind: .addition)
            let other = cell(30, kind: .deletion)
            for width: CGFloat in [420, 517, 700, 1_100, 1_400] {
                #expect(
                    estimator.height(of: row(.unified(line)), width: width)
                        == measured(swiftUISide(line, numbers: 2, metrics: metrics), width: width, metrics: metrics),
                    "unified \(text.prefix(20)) at \(width)"
                )
                for old in [other, nil] {
                    let split = HStack(alignment: .top, spacing: 0) {
                        swiftUISide(old, numbers: 1, metrics: metrics)
                        swiftUISide(line, numbers: 1, metrics: metrics)
                    }
                    #expect(
                        estimator.height(of: row(.split(old: old, new: line)), width: width)
                            == measured(split, width: width, metrics: metrics),
                        "split \(text.prefix(20)) at \(width)"
                    )
                }
            }
        }
    }

    @Test func aLineWithoutANewlineHasRoomForItsNote() {
        let diff = Diff(parsing: "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,1 +1,1 @@\n-a\n+b\n\\ No newline at end of file\n")
        let line = diff.files[0].hunks[0].lines[1]
        #expect(line.ending == .none)
        let height = estimator.height(of: row(.unified(LineCell(line: line, text: LineStyler.plain(line)))), width: 800)
        #expect(height == (metrics.lineHeight + NoNewlineNote.spacing + NoNewlineNote.size.height + 2 * DiffMetrics.rowPadding).rounded(.up))
    }

    /// An estimate that is off moves the scroll bar when the row comes on screen.
    @Test(arguments: [9.0, 11, 12, 13, 14, 16, 20, 24])
    func theEstimateOfAHunkHeaderIsItsRealHeight(fontSize: Double) {
        let metrics = DiffMetrics(fontSize: fontSize)
        let estimator = RowHeightEstimator(metrics: metrics)
        let model = FileModel(diff: file, layout: .unified)
        for hidden in [0, 1, 300] {
            let header = HunkHeader(
                region: 1, range: "@@ -1,2 +1,2 @@", heading: "func a()", hidden: hidden, canExpandDown: true, canExpandUp: true
            )
            #expect(
                estimator.height(of: row(.hunk(header)), width: 1_100)
                    == measured(HunkHeaderRow(header: header, file: model), width: 1_100, metrics: metrics)
            )
        }
    }

    @Test func fileHeadersAndNoticesHaveTheirFixedHeights() {
        let model = DiffModel(
            source: .workingTree(directory: URL(filePath: "/nonexistent"), baseRef: "main"), client: GitHubClient(), repoCache: RepoCache()
        )
        let fileModel = FileModel(diff: file, layout: .unified)
        #expect(
            measured(FileHeader(file: fileModel, model: model, gitHubURL: nil), width: 1_100, metrics: metrics) == DiffMetrics.headerHeight
        )
        // Other notices differ by a fraction of a point with their symbol.
        let notice = FileNotice.binary
        #expect(measured(NoticeRow(notice: notice) {}, width: 1_100, metrics: metrics) == estimator.height(of: row(.notice(notice)), width: 1_100))
        #expect(estimator.height(of: .header, width: 1_100) == DiffMetrics.headerHeight)
        #expect(estimator.height(of: .spacer, width: 1_100) == DiffMetrics.fileSpacing)
    }
}

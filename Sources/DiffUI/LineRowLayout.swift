import AppKit
import DiffKit
import HermesUI
import SwiftUI

/// One side of a code-line row and where it is in the row. A unified row has
/// one side as wide as the row. A split row has two halves, old then new.
struct LineSide {
    /// `nil` for the half of a split row whose line has no counterpart.
    let cell: LineCell?
    /// How many digits a line number is padded to.
    let digits: Int
    /// Whether the gutter shows the old and the new number, as a unified row does.
    let showsBothNumbers: Bool
    /// Whether this is the old half of a split row, which shows old line numbers.
    let isOldSide: Bool
    let x: CGFloat
    let width: CGFloat
    /// The width of the tinted band behind the line numbers.
    let gutterWidth: CGFloat
    /// Where the code starts, past the line numbers and the marker.
    let codeX: CGFloat

    var codeWidth: CGFloat { x + width - codeX }

    /// The line numbers and the change marker, as one string that ends where the code starts.
    var gutter: String {
        guard let line = cell?.line else { return "" }
        func padded(_ number: Int?) -> String {
            let text = number.map(String.init) ?? ""
            return String(repeating: " ", count: max(digits - text.count, 0)) + text
        }
        let numbers = showsBothNumbers
            ? padded(line.oldNumber) + " " + padded(line.newNumber) : padded(isOldSide ? line.oldNumber : line.newNumber)
        let marker = switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        }
        return numbers + " " + marker + " "
    }
}

/// The sides of a code-line row `width` wide. Empty for a hunk header or a notice.
func lineSides(of kind: DiffRow.Kind, digits: Int, width: CGFloat, metrics: DiffMetrics) -> [LineSide] {
    func side(_ cell: LineCell?, x: CGFloat, width: CGFloat, isUnified: Bool, isOld: Bool = false) -> LineSide {
        let gutter = metrics.gutterWidth(digits: digits, columns: isUnified ? 2 : 1)
        return LineSide(
            cell: cell, digits: digits, showsBothNumbers: isUnified, isOldSide: isOld, x: x, width: width, gutterWidth: gutter,
            codeX: x + gutter + metrics.markerWidth
        )
    }
    switch kind {
    case .unified(let cell):
        return [side(cell, x: 0, width: width, isUnified: true)]
    case .split(let old, let new):
        let half = width / 2
        return [side(old, x: 0, width: half, isUnified: false, isOld: true), side(new, x: half, width: half, isUnified: false)]
    case .hunk, .notice:
        return []
    }
}

/// The text a line is drawn as: every tab is four spaces, and an empty line is
/// one space so it keeps the height of a line.
func displayedText(_ text: String) -> String {
    text.isEmpty ? " " : text.replacingOccurrences(of: "\t", with: "    ")
}

/// The height of a line's code wrapped at `width`.
func codeHeight(_ line: DiffLine, width: CGFloat, metrics: DiffMetrics) -> CGFloat {
    // Before the table has a width.
    guard width > 0 else { return metrics.lineHeight }
    // Most lines are printable ASCII, where every character is one advance wide, and fit.
    var columns = 0
    var isPlain = true
    for byte in line.text.utf8 {
        if byte == 9 {
            columns += 4
        } else if byte >= 0x20, byte < 0x7F {
            columns += 1
        } else {
            isPlain = false
            break
        }
    }
    if isPlain, CGFloat(columns) * metrics.characterWidth <= width - 1 { return metrics.lineHeight }
    // The options SwiftUI lays a `Text` out with, so the wrapping and the height are the same.
    return NSAttributedString(string: displayedText(line.text), attributes: [.font: metrics.nsFont])
        .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
        .height.rounded(.up)
}

/// The "No newline at end of file" note under a file's last line.
@MainActor
enum NoNewlineNote {
    private struct NoteLabel: View {
        var body: some View {
            Label("No newline at end of file", systemImage: "nosign")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
        }
    }

    /// The gap between the code and the note.
    static let spacing: CGFloat = 2
    static let size = NSHostingController(rootView: NoteLabel()).sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
    private static var images: [String: NSImage] = [:]

    /// The note as a picture. A symbol beside text is a SwiftUI `Label`, and
    /// the one or two notes on screen are not worth a hosting view each.
    static func image(isDark: Bool, scale: CGFloat) -> NSImage? {
        let key = "\(isDark) \(scale)"
        if let image = images[key] { return image }
        let renderer = ImageRenderer(content: NoteLabel().environment(\.colorScheme, isDark ? .dark : .light))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        images[key] = NSImage(cgImage: image, size: size)
        return images[key]
    }
}

/// The height of a code-line row with these sides: its taller side and the padding above and below.
@MainActor
func lineRowHeight(_ sides: [LineSide], metrics: DiffMetrics) -> CGFloat {
    let heights = sides.map { side -> CGFloat in
        guard let line = side.cell?.line else { return 0 }
        let note = line.ending == .none ? NoNewlineNote.spacing + NoNewlineNote.size.height : 0
        return codeHeight(line, width: side.codeWidth, metrics: metrics) + note
    }
    // A whole number of points, so the rows below stay on whole pixels.
    return (max(heights.max() ?? 0, metrics.lineHeight) + 2 * DiffMetrics.rowPadding).rounded(.up)
}

/// The review marks in one line's gutter.
struct LineMarks: Equatable {
    /// The line is in the range being selected or commented on.
    var isSelected = false
    /// The line is in the range of a thread or a draft.
    var isInRange = false
    /// A gutter drag started on the line, so it keeps its "+" while the pointer is elsewhere.
    var isDragOrigin = false
}

/// The review state that the gutters of code lines show.
struct ReviewMarks: Equatable {
    var selectionFile: FileDiff.ID?
    var selectionLines: Set<DiffLine.Numbers> = []
    var rangeLines: [FileDiff.ID: Set<DiffLine.Numbers>] = [:]
    var dragFile: FileDiff.ID?
    var dragLine: DiffLine?

    init() {}

    @MainActor
    init(_ review: ReviewModel?) {
        guard let review else { return }
        selectionFile = review.selection?.file
        selectionLines = review.selection?.lines ?? []
        rangeLines = review.layout.rangeLines
        dragFile = review.dragOrigin?.file
        dragLine = review.dragOrigin?.line
    }

    func marks(of line: DiffLine, in file: FileDiff.ID) -> LineMarks {
        LineMarks(
            isSelected: selectionFile == file && selectionLines.contains(line.numbers),
            isInRange: rangeLines[file]?.contains(line.numbers) == true,
            isDragOrigin: dragFile == file && dragLine == line
        )
    }
}

/// What VoiceOver reads for a line: "Added line 12", then its text.
func spokenLine(_ line: DiffLine) -> String {
    let label = switch line.numbers {
    case .addition(let new): "Added line \(new)"
    case .deletion(let old): "Removed line \(old)"
    case .context(_, let new): "Line \(new)"
    }
    return line.text.isEmpty ? label : "\(label): \(line.text)"
}

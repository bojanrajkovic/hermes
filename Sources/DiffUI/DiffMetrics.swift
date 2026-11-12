import AppKit
import SwiftUI

/// User defaults the diff viewer remembers across launches.
enum DiffDefaults {
    static let layoutKey = "DiffUI.layout"
    static let fontSizeKey = "DiffUI.codeFontSize"
    static let fontSize = 12.0
    static let fontSizeRange = 9.0...24.0
}

/// Sizes that follow the code font size.
struct DiffMetrics: Equatable {
    let font: Font
    /// The same font, for the code lines the table draws itself.
    let nsFont: NSFont
    /// The advance of one character of the code font.
    let characterWidth: CGFloat
    /// The height of one line of code. String drawing without font leading gives the height SwiftUI gives a `Text`.
    let lineHeight: CGFloat
    static let gutterPadding: CGFloat = 8
    static let rowPadding: CGFloat = 1
    static let headerPaddingHorizontal: CGFloat = 10
    static let headerPaddingVertical: CGFloat = 6
    static let fileSpacing: CGFloat = 14
    /// The height of the bars above the file list and the diff, so their bottom edges line up.
    static let barHeight: CGFloat = 34
    static let hunkPadding: CGFloat = 3
    /// The height of a file header. The table uses it until it has measured the row.
    static let headerHeight: CGFloat = 29
    static let listMinWidth: CGFloat = 420
    static let listMinHeight: CGFloat = 160
    static let paneMinHeight: CGFloat = 220
    static let paneIdealHeight: CGFloat = 320
    static let renderedMinHeight: CGFloat = 120
    static let definitionPopoverSize = CGSize(width: 640, height: 360)

    init(fontSize: Double = DiffDefaults.fontSize) {
        let size = min(max(fontSize, DiffDefaults.fontSizeRange.lowerBound), DiffDefaults.fontSizeRange.upperBound)
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        self.font = Font(font)
        nsFont = font
        characterWidth = font.maximumAdvancement.width
        lineHeight = NSAttributedString(string: "x", attributes: [.font: font])
            .boundingRect(with: CGSize(width: 1_000, height: 1_000), options: .usesLineFragmentOrigin).height.rounded(.up)
    }

    /// The width of a gutter that shows `columns` line numbers of up to `digits` digits each.
    func gutterWidth(digits: Int, columns: Int) -> CGFloat {
        // One character of padding on each side.
        CGFloat(digits * columns + columns + 1) * characterWidth
    }

    /// The width of the `+` / `−` column.
    var markerWidth: CGFloat { characterWidth * 2 }
}

extension EnvironmentValues {
    @Entry var diffMetrics = DiffMetrics()
}

extension FocusedValues {
    /// The diff on screen in the focused window, for ``DiffCommands``.
    @Entry var diffModel: DiffModel?
}

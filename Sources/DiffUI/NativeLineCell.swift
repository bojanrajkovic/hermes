import AppKit
import DiffKit
import SwiftUI
import SyntaxKit

/// A code-line row of the diff table: one line, or the two sides of a split row.
///
/// It draws itself, because a SwiftUI view per row made every scrolled frame
/// lay out a screenful of hosting views. The text is drawn with the string
/// drawing options SwiftUI uses for a `Text`, so it wraps and measures the same.
///
/// The table's coordinator tells the cell where the pointer is. The cell draws
/// the "+" and the identifier underline, and answers what is under a point.
final class NativeLineCell: NSView {
    private var row: DiffRow?
    private var digits = 0
    private var metrics = DiffMetrics()
    private(set) var file: FileModel?
    private weak var model: DiffModel?
    /// The review marks of each side.
    private var marks: [LineMarks] = []
    /// The side under the pointer, and the identifier under it as a range of the displayed text.
    private var hover: (side: Int, underline: Range<Int>?)?
    /// The gutter and code of each side, ready to draw. Built on the first draw and after the appearance changes.
    private var strings: [(gutter: NSAttributedString, code: NSAttributedString)?]?
    /// The identifiers of each side's line, once parsed. A line is parsed when the pointer first reaches it.
    private var identifiers: [Int: [Identifier]] = [:]
    /// The text layout of the side under the pointer, for finding the character at a point.
    private var hitLayout: (side: Int, width: CGFloat, storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer)?
    private var menuLine: DiffLine?
    /// The tint over a line that was just revealed.
    private var highlightView: NSView?
    /// How long the highlight stays before it fades, and how long the fade takes.
    static let highlightHold: TimeInterval = 0.3
    static let highlightFade: TimeInterval = 0.9

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var sides: [LineSide] {
        row.map { lineSides(of: $0.kind, digits: digits, width: bounds.width, metrics: metrics) } ?? []
    }

    /// The row's lines: one, or the old and new line of a split row.
    var lines: [DiffLine] { row?.cells.map(\.line) ?? [] }

    // MARK: Content

    func show(_ row: DiffRow, digits: Int, metrics: DiffMetrics, file: FileModel, model: DiffModel, marks: ReviewMarks) {
        if row.id != self.row?.id || file !== self.file {
            hover = nil
            identifiers = [:]
            highlightView?.removeFromSuperview()
            highlightView = nil
        }
        self.row = row
        self.digits = digits
        self.metrics = metrics
        self.file = file
        self.model = model
        strings = nil
        hitLayout = nil
        self.marks = []
        show(marks: marks)
        needsDisplay = true
    }

    func show(marks: ReviewMarks) {
        guard let file else { return }
        let new = sides.map { side in side.cell.map { marks.marks(of: $0.line, in: file.id) } ?? LineMarks() }
        guard new != self.marks else { return }
        self.marks = new
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { needsDisplay = true }
        super.setFrameSize(newSize)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        strings = nil
        needsDisplay = true
    }

    // MARK: Drawing

    private func codeString(_ text: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: String(text.characters), attributes: [.font: metrics.nsFont, .foregroundColor: NSColor.labelColor]
        )
        var location = 0
        for run in text.runs {
            let length = String(text[run.range].characters).utf16.count
            let range = NSRange(location: location, length: length)
            location += length
            if let color = run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] {
                result.addAttribute(.foregroundColor, value: NSColor(color), range: range)
            }
            if let color = run[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] {
                result.addAttribute(.backgroundColor, value: NSColor(color), range: range)
            }
        }
        return result
    }

    private func makeStrings(_ sides: [LineSide]) -> [(gutter: NSAttributedString, code: NSAttributedString)?] {
        sides.map { side in
            guard let cell = side.cell else { return nil }
            let gutter = NSAttributedString(
                string: side.gutter, attributes: [.font: metrics.nsFont, .foregroundColor: NSColor.secondaryLabelColor]
            )
            return (gutter, codeString(cell.text))
        }
    }

    /// The square the "+" is drawn in and takes clicks in: the end of the gutter, over the change marker.
    private func plusRect(_ side: LineSide) -> CGRect {
        CGRect(
            x: side.codeX - ReviewMetrics.plusWidth, y: DiffMetrics.rowPadding, width: ReviewMetrics.plusWidth, height: metrics.lineHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let sides = sides
        let strings = strings ?? makeStrings(sides)
        self.strings = strings
        func fill(_ color: NSColor, _ rect: CGRect) {
            color.setFill()
            rect.fill(using: .sourceOver)
        }
        // Text starts on a whole pixel, as SwiftUI places it. The gutter's width is a fraction of a point.
        let scale = abs(NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2)
        func snapped(_ x: CGFloat) -> CGFloat { (x * scale).rounded() / scale }

        // A row of context lines has no tint. In any other split row, a side without a line is grayed.
        if !row.cells.allSatisfy({ $0.line.kind == .context }) {
            for side in sides {
                let rect = CGRect(x: side.x, y: 0, width: side.width, height: bounds.height)
                guard let kind = side.cell?.line.kind else {
                    fill(NSColor(Color.primary.opacity(0.04)), rect)
                    continue
                }
                guard kind != .context else { continue }
                fill(NSColor(DiffColors.row(kind)), rect)
                fill(NSColor(DiffColors.gutter(kind)), CGRect(x: side.x, y: 0, width: side.gutterWidth, height: bounds.height))
            }
        }
        if sides.count == 2 {
            fill(.separatorColor, CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height))
        }

        let top = DiffMetrics.rowPadding
        for (index, side) in sides.enumerated() {
            guard let cell = side.cell, let text = strings[index] else { continue }
            let marks = marks.indices.contains(index) ? marks[index] : LineMarks()
            if marks.isSelected || marks.isInRange {
                // The bar marks every line of a comment's range. The tint is added while the range is being chosen.
                let gutter = CGRect(x: side.x, y: top, width: side.codeX - side.x, height: metrics.lineHeight)
                if marks.isSelected { fill(NSColor.controlAccentColor.withAlphaComponent(0.18), gutter) }
                fill(
                    NSColor.controlAccentColor.withAlphaComponent(marks.isSelected ? 1 : 0.45),
                    CGRect(x: side.x, y: top, width: 3, height: metrics.lineHeight)
                )
            }

            // SwiftUI sizes a `Text` to whole pixels and right-aligns that box.
            let gutterWidth = (text.gutter.size().width * scale).rounded(.up) / scale
            text.gutter.draw(
                with: CGRect(x: snapped(side.codeX - gutterWidth), y: top, width: gutterWidth, height: metrics.lineHeight),
                options: .usesLineFragmentOrigin
            )
            let height = codeHeight(cell.line, width: side.codeWidth, metrics: metrics)
            let codeX = snapped(side.codeX)
            text.code.draw(with: CGRect(x: codeX, y: top, width: side.codeWidth, height: height), options: .usesLineFragmentOrigin)

            if cell.line.ending == .none {
                let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let origin = CGPoint(x: codeX, y: top + height + NoNewlineNote.spacing)
                NoNewlineNote.image(isDark: isDark, scale: scale)?.draw(
                    in: CGRect(origin: origin, size: NoNewlineNote.size), from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil
                )
            }
            // The "+" stays on the line a drag started from while the pointer is over other rows.
            if model?.review != nil, hover?.side == index || marks.isDragOrigin { drawPlus(in: plusRect(side)) }
            if let hover, hover.side == index, let underline = hover.underline, let layout = layout(side: index) {
                let glyphs = layout.manager.glyphRange(forCharacterRange: NSRange(underline), actualCharacterRange: nil)
                layout.manager.enumerateEnclosingRects(
                    forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: layout.container
                ) { rect, _ in
                    fill(.labelColor, CGRect(x: codeX + rect.minX, y: top + rect.maxY - 1.5, width: rect.width, height: 1))
                }
            }
        }
    }

    private func drawPlus(in rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: metrics.nsFont.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor]))
        guard let image = NSImage(systemSymbolName: "plus.square.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = image.size
        image.draw(
            in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }

    // MARK: Highlight

    /// A tint that takes no clicks.
    private final class Tint: NSView {
        init(frame: CGRect, color: NSColor) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = color.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Tints the row for a moment, and `symbol` in its code more strongly, then fades the tint out.
    /// The tint is a view over the row, so the row keeps its height and does not redraw.
    func highlight(symbol: String?) {
        highlightView?.removeFromSuperview()
        var tint: Tint!
        // Yellow reads as a mark on both the red and the green rows, in light and dark.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = Tint(frame: bounds, color: NSColor.systemYellow.withAlphaComponent(0.2))
            tint.autoresizingMask = [.width, .height]
            for rect in symbolRects(symbol) {
                let mark = Tint(frame: rect.insetBy(dx: -1, dy: 0), color: NSColor.systemYellow.withAlphaComponent(0.45))
                mark.layer?.cornerRadius = 2
                tint.addSubview(mark)
            }
        }
        addSubview(tint)
        highlightView = tint

        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DispatchQueue.main.asyncAfter(deadline: .now() + (reducesMotion ? Self.highlightHold + Self.highlightFade : Self.highlightHold)) {
            guard tint.superview != nil else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reducesMotion ? 0 : Self.highlightFade
                tint.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { tint.removeFromSuperview() }
            }
        }
    }

    /// Where `symbol` first is in each side's code, in the cell's coordinates.
    private func symbolRects(_ symbol: String?) -> [CGRect] {
        guard let symbol, !symbol.isEmpty else { return [] }
        var rects: [CGRect] = []
        for (index, side) in sides.enumerated() {
            guard let cell = side.cell, let layout = layout(side: index) else { continue }
            let range = (displayedText(cell.line.text) as NSString).range(of: symbol)
            guard range.location != NSNotFound else { continue }
            let glyphs = layout.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.manager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: layout.container
            ) { rect, _ in
                rects.append(rect.offsetBy(dx: side.codeX, dy: DiffMetrics.rowPadding))
            }
        }
        return rects
    }

    // MARK: Pointer

    private func sideIndex(at point: CGPoint) -> Int? {
        sides.firstIndex { $0.cell != nil && point.x >= $0.x && point.x < $0.x + $0.width }
    }

    /// Tells the cell where the pointer is, in its coordinates, or that it left.
    /// - Returns: Whether the pointer is over an identifier, which a click looks up.
    func pointerMoved(to point: CGPoint?) -> Bool {
        var new: (side: Int, underline: Range<Int>?)?
        if let point, let index = sideIndex(at: point), let line = sides[index].cell?.line {
            loadIdentifiers(side: index, line: line)
            new = (index, identifier(at: point).map { displayRange(of: $0.range, in: line.text) })
        }
        if new?.side != hover?.side || new?.underline != hover?.underline {
            hover = new
            needsDisplay = true
        }
        return new?.underline != nil
    }

    /// The line whose "+" is at `point`. `nil` away from the "+", and for a diff that takes no comments.
    func plusLine(at point: CGPoint) -> DiffLine? {
        guard model?.review != nil, let index = sideIndex(at: point), plusRect(sides[index]).contains(point) else { return nil }
        return sides[index].cell?.line
    }

    func identifier(at point: CGPoint) -> Identifier? {
        guard let index = sideIndex(at: point), let line = sides[index].cell?.line, let layout = layout(side: index),
              layout.manager.numberOfGlyphs > 0
        else { return nil }
        let local = CGPoint(x: point.x - sides[index].codeX, y: point.y - DiffMetrics.rowPadding)
        let glyph = layout.manager.glyphIndex(for: local, in: layout.container)
        guard layout.manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: layout.container).contains(local)
        else { return nil }
        let offset = layout.manager.characterIndexForGlyph(at: glyph)
        return identifiers[index]?.first { displayRange(of: $0.range, in: line.text).contains(offset) }
    }

    private func layout(side index: Int) -> (manager: NSLayoutManager, container: NSTextContainer)? {
        let side = sides[index]
        if let hitLayout, hitLayout.side == index, hitLayout.width == side.codeWidth { return (hitLayout.manager, hitLayout.container) }
        guard let cell = side.cell else { return nil }
        let storage = NSTextStorage(attributedString: codeString(cell.text))
        // As the string drawing that draws the line: its line height, no font leading, no padding at
        // the sides. At some font sizes a layout manager's own line is a point shorter.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = metrics.lineHeight
        paragraph.maximumLineHeight = metrics.lineHeight
        storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        let container = NSTextContainer(size: CGSize(width: side.codeWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        hitLayout = (index, side.codeWidth, storage, manager, container)
        return (manager, container)
    }

    private func loadIdentifiers(side index: Int, line: DiffLine) {
        guard identifiers[index] == nil, let file, let id = row?.id else { return }
        identifiers[index] = []
        let source = line.text
        let language = Language(path: file.diff.path)
        Task { [weak self] in
            let parsed = await Task.detached { Syntax.identifiers(in: source, language: language).lines.first ?? [] }.value
            guard let self, self.row?.id == id, self.file === file else { return }
            self.identifiers[index] = parsed
        }
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = sideIndex(at: convert(event.locationInWindow, from: nil)), let line = sides[index].cell?.line else { return nil }
        menuLine = line
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Line", action: #selector(copyLine), keyEquivalent: "").target = self
        if model?.review != nil {
            menu.addItem(withTitle: "Add Comment…", action: #selector(addComment), keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func copyLine() {
        guard let menuLine else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(menuLine.text, forType: .string)
    }

    @objc private func addComment() {
        guard let menuLine, let file else { return }
        model?.review?.startComment(file: file.id, from: menuLine, to: menuLine)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityLabel() -> String? {
        lines.map(spokenLine).joined(separator: "\n")
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let review = model?.review, let file else { return nil }
        return lines.map { line in
            NSAccessibilityCustomAction(name: "Comment on \(lineRangeLabel(CommentAnchor(path: "", end: line.commentPosition)))") {
                review.startComment(file: file.id, from: line, to: line)
                return true
            }
        }
    }
}

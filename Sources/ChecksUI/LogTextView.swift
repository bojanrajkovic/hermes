import AppKit
import SwiftUI

/// The log text. An `NSTextView` rather than a SwiftUI stack because a log can
/// be 50,000 lines or more, and TextKit lays out only what is on screen.
struct LogTextView: NSViewRepresentable {
    let rendered: RenderedLog
    let wrapsLines: Bool
    let matches: [LogMatch]
    let focus: LogFocus?
    /// Called with the log line of a group title that was clicked.
    let onToggle: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: its non-contiguous layout scrolls a huge document without laying all of it out.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        layoutManager.addTextContainer(container)

        let textView = GroupClickTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Job log")

        let scrollView = ResizeReportingScrollView()
        scrollView.onResize = { [coordinator = context.coordinator, weak scrollView] in
            if let scrollView { coordinator.applyFocus(scrollView) }
        }
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self, scrollView: scrollView)
    }

    @MainActor
    final class Coordinator {
        var textView: GroupClickTextView?
        private var shown: NSAttributedString?
        private var rendered = RenderedLog.empty
        private var wrapsLines: Bool?
        private var matches: [LogMatch] = []
        private var appliedFocus: Int?
        private var pendingFocus: LogFocus?

        func update(_ view: LogTextView, scrollView: NSScrollView) {
            guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }

            textView.onClick = { [rendered = view.rendered, onToggle = view.onToggle] character in
                guard let row = rendered.row(atCharacter: character), rendered.isGroupTitle(row: row) else { return false }
                onToggle(rendered.lines[row])
                return true
            }

            if wrapsLines != view.wrapsLines {
                wrapsLines = view.wrapsLines
                setWrapping(view.wrapsLines, textView: textView, scrollView: scrollView)
            }

            let textChanged = shown !== view.rendered.text
            if textChanged {
                let old = rendered, new = view.rendered
                shown = new.text
                rendered = new
                if let section = new.singleToggledSection(comparedTo: old) {
                    // Replacing the whole text of a long log takes a visible
                    // moment; one group opening or closing only touches its own rows.
                    let lines = section.header..<section.body.upperBound
                    storage.replaceCharacters(
                        in: old.characterRange(ofLines: lines),
                        with: new.text.attributedSubstring(from: new.characterRange(ofLines: lines))
                    )
                } else {
                    storage.setAttributedString(new.text)
                    // New text starts at its left edge.
                    textView.sizeToFit()
                    scroll(scrollView, toY: scrollView.contentView.bounds.minY)
                }
            }

            if textChanged || matches != view.matches {
                matches = view.matches
                highlight(matches, layoutManager: layoutManager, length: storage.length)
            }

            pendingFocus = view.focus
            applyFocus(scrollView)
        }

        /// Scrolls to the pending focus once its line is displayed and the
        /// view has a size. Before the first layout a scroll position means nothing.
        func applyFocus(_ scrollView: NSScrollView) {
            guard let textView, let focus = pendingFocus, focus.id != appliedFocus,
                  let row = rendered.row(ofLine: focus.line),
                  // Without a size yet, the scroll view calls again when it gets one.
                  scrollView.contentSize.height > 0 else { return }
            appliedFocus = focus.id

            // Non-contiguous layout only estimates where a far line is, and the
            // view's height with it. Laying out the text above the line makes
            // both exact. It costs about 5 ms per 1,000 lines, once.
            let rowRange = rendered.characterRange(ofRow: row)
            textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: rowRange.upperBound))
            textView.sizeToFit()

            if let match = focus.match, let range = rendered.characterRange(of: match) {
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.showFindIndicator(for: range)
            } else {
                // Leave some of what led up to the line above it.
                let rect = rowRect(row, in: rendered, textView: textView)
                scroll(scrollView, toY: rect.minY - scrollView.contentSize.height / 3)
            }
        }

        private func setWrapping(_ wraps: Bool, textView: NSTextView, scrollView: NSScrollView) {
            guard let container = textView.textContainer else { return }
            let unlimited = CGFloat.greatestFiniteMagnitude
            scrollView.hasHorizontalScroller = !wraps
            textView.isHorizontallyResizable = !wraps
            container.widthTracksTextView = wraps
            if wraps {
                let width = scrollView.contentSize.width
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
                container.containerSize = NSSize(width: width - textView.textContainerInset.width * 2, height: unlimited)
            } else {
                container.containerSize = NSSize(width: unlimited, height: unlimited)
            }
        }

        private func rowRect(_ row: Int, in rendered: RenderedLog, textView: NSTextView) -> NSRect {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return .zero }
            let glyphs = layoutManager.glyphRange(forCharacterRange: rendered.characterRange(ofRow: row), actualCharacterRange: nil)
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
        }

        private func scroll(_ scrollView: NSScrollView, toY y: CGFloat) {
            guard let documentView = scrollView.documentView else { return }
            let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func highlight(_ matches: [LogMatch], layoutManager: NSLayoutManager, length: Int) {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            // shortcut: only the first 5,000 matches are tinted (the count and
            // next/previous cover all of them); tint per viewport if that matters.
            for match in matches.prefix(5000) {
                guard let range = rendered.characterRange(of: match) else { continue }
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.45), forCharacterRange: range
                )
            }
        }
    }
}

/// A scroll view that reports each change of its size, so a scroll requested
/// before the view had a size can happen once it has one.
final class ResizeReportingScrollView: NSScrollView {
    var onResize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

/// A text view that reports clicks before handling them, so a click on a
/// group's title row can toggle the group.
final class GroupClickTextView: NSTextView {
    /// Returns true when it handled a click on the character at the given offset.
    var onClick: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let character = character(at: convert(event.locationInWindow, from: nil)),
           onClick?(character) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager, let textContainer, let textStorage else { return }
        let visible = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        textStorage.enumerateAttribute(LogRenderer.groupTitle, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            rect.origin.y += textContainerOrigin.y
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    private func character(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard (line.minY..<line.maxY).contains(inContainer.y) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }
}

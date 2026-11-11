import SwiftUI
import SyntaxKit

/// Where an identifier's characters are in a line's displayed text, in which
/// every tab of the source has become four spaces.
///
/// - Parameter range: UTF-16 offsets in `source`.
func displayRange(of range: Range<Int>, in source: String) -> Range<Int> {
    let units = Array(source.utf16)
    let tab: UInt16 = 9
    func shift(_ offset: Int) -> Int { offset + 3 * units.prefix(offset).count { $0 == tab } }
    return shift(range.lowerBound)..<shift(range.upperBound)
}

/// Every glyph's frame and its UTF-16 offset in the laid-out text.
///
/// - Parameter origin: Where the layout's origin is in the caller's coordinate space.
@MainActor
func glyphFrames(in layout: Text.Layout, origin: CGPoint) -> [(rect: CGRect, offset: Int)] {
    // Character indices are opaque; the first one is the start of the text.
    guard let first = layout.first?.first?.characterIndices.first else { return [] }
    var glyphs: [(CGRect, Int)] = []
    for line in layout {
        for run in line {
            for (slice, index) in zip(run, run.characterIndices) {
                glyphs.append((slice.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y), first.distance(to: index)))
            }
        }
    }
    return glyphs
}

/// One line of code. While the pointer is over the line, its identifiers
/// underline under the pointer and a click looks up their definition.
struct CodeText: View {
    let text: AttributedString
    /// The line as it is in the file.
    let source: String
    let path: String
    /// The line's identifiers when they are known. Otherwise the line is parsed when it is first hovered.
    var identifiers: [Identifier]?
    let isHovered: Bool
    @Environment(DefinitionModel.self) private var definitions: DefinitionModel?

    var body: some View {
        // The layout is read only on the hovered line, so scrolling pays nothing for it.
        if isHovered, let definitions {
            Text(text).overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                if let anchored = layouts.first {
                    GeometryReader { proxy in
                        IdentifierLayer(
                            layout: anchored.layout, origin: proxy[anchored.origin], source: source, path: path,
                            known: identifiers, definitions: definitions
                        )
                    }
                }
            }
        } else {
            Text(text)
        }
    }
}

private struct IdentifierLayer: View {
    let layout: Text.Layout
    let origin: CGPoint
    let source: String
    let path: String
    let known: [Identifier]?
    let definitions: DefinitionModel

    @State private var parsed: [Identifier] = []
    @State private var hovered: Identifier?

    private var identifiers: [Identifier] { known ?? parsed }

    var body: some View {
        Path { path in
            guard let hovered else { return }
            let range = displayRange(of: hovered.range, in: source)
            for rect in glyphFrames(in: layout, origin: origin).filter({ range.contains($0.offset) }).map(\.rect) {
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 1))
            }
        }
        .stroke(.primary, lineWidth: 1)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = identifier(at: point)
            case .ended: hovered = nil
            }
        }
        .pointerStyle(hovered == nil ? nil : .link)
        // The click's own position, not the hover state: a click can arrive without a hover before it.
        .onTapGesture { point in
            if let identifier = identifier(at: point) { definitions.lookUp(name: identifier.name, from: path) }
        }
        .task {
            guard known == nil else { return }
            let source = source
            let language = Language(path: path)
            parsed = await Task.detached { Syntax.identifiers(in: source, language: language).lines.first ?? [] }.value
        }
        .accessibilityHidden(true)
    }

    private func identifier(at point: CGPoint) -> Identifier? {
        guard let offset = glyphFrames(in: layout, origin: origin).first(where: { $0.rect.contains(point) })?.offset else { return nil }
        return identifiers.first { displayRange(of: $0.range, in: source).contains(offset) }
    }
}

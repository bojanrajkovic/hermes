import AppKit
import DiffKit
import SwiftUI
import SyntaxKit

/// A stretch of one line that is drawn with one set of attributes.
struct StyledSpan: Hashable, Sendable {
    /// UTF-16 offsets within the line.
    let range: Range<Int>
    let kind: TokenKind
    /// Whether the stretch is part of an intraline change.
    let isEmphasized: Bool
}

/// Colors for diff rows and syntax tokens. Each adapts to light and dark.
enum DiffColors {
    static let addedRow = Color(nsColor: .systemGreen).opacity(0.13)
    static let addedGutter = Color(nsColor: .systemGreen).opacity(0.22)
    static let addedEmphasis = Color(nsColor: .systemGreen).opacity(0.36)
    static let removedRow = Color(nsColor: .systemRed).opacity(0.12)
    static let removedGutter = Color(nsColor: .systemRed).opacity(0.21)
    static let removedEmphasis = Color(nsColor: .systemRed).opacity(0.36)
    /// The text of `+12` and `−3` counts.
    static let addedText = adaptive(light: 0x1A7F37, dark: 0x3FB950)
    static let removedText = adaptive(light: 0xCF222E, dark: 0xF85149)

    static func row(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: addedRow
        case .deletion: removedRow
        case .context: .clear
        }
    }

    static func gutter(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: addedGutter
        case .deletion: removedGutter
        case .context: .clear
        }
    }

    /// The color of a syntax token, or `nil` for the default text color.
    static func token(_ kind: TokenKind) -> Color? {
        switch kind {
        case .plain, .variable, .operator, .punctuation: nil
        case .keyword: keyword
        case .string: string
        case .number, .constant: number
        case .comment: comment
        case .type: type
        case .function: function
        case .property: property
        case .attribute: attribute
        case .tag: tag
        }
    }

    private static let keyword = adaptive(light: 0xAD3DA4, dark: 0xFF7AB2)
    private static let string = adaptive(light: 0xC41A16, dark: 0xFF8170)
    private static let number = adaptive(light: 0x1C00CF, dark: 0xD9C97C)
    private static let comment = adaptive(light: 0x5D6C79, dark: 0x7F8C98)
    private static let type = adaptive(light: 0x0B4F79, dark: 0x5DD8FF)
    private static let function = adaptive(light: 0x326D74, dark: 0x67B7A4)
    private static let property = adaptive(light: 0x6C36A9, dark: 0xD0A8FF)
    private static let attribute = adaptive(light: 0x815F03, dark: 0xFFA14F)
    private static let tag = adaptive(light: 0x116329, dark: 0x7EE787)

    private static func adaptive(light: Int, dark: Int) -> Color {
        func color(_ hex: Int) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}

/// Turns diff lines into styled text. Everything here is pure and runs off the main actor.
enum LineStyler {
    /// Splits a line into runs that share a token kind and emphasis.
    ///
    /// - Parameters:
    ///   - length: The line's length in UTF-16 code units.
    ///   - tokens: Syntax tokens. Gaps and anything out of bounds are plain.
    ///   - emphasis: UTF-16 ranges of intraline changes.
    /// - Returns: Runs in order that cover the line exactly.
    static func spans(length: Int, tokens: [Token], emphasis: [Range<Int>]) -> [StyledSpan] {
        guard length > 0 else { return [] }
        var kinds = [TokenKind](repeating: .plain, count: length)
        var marked = [Bool](repeating: false, count: length)
        for token in tokens {
            for index in token.range.clamped(to: 0..<length) { kinds[index] = token.kind }
        }
        for range in emphasis {
            for index in range.clamped(to: 0..<length) { marked[index] = true }
        }
        var result: [StyledSpan] = []
        var start = 0
        for index in 1...length where index == length || kinds[index] != kinds[start] || marked[index] != marked[start] {
            result.append(StyledSpan(range: start..<index, kind: kinds[start], isEmphasized: marked[start]))
            start = index
        }
        return result
    }

    /// Builds the styled text of one line. Tabs become four spaces, and an
    /// empty line becomes one space so its row keeps the height of a line.
    ///
    /// Stage 2 sets its identifier link attribute here: this is the one place
    /// where a token's range becomes text attributes.
    static func attributed(_ text: String, spans: [StyledSpan], emphasisColor: Color) -> AttributedString {
        guard !text.isEmpty else { return AttributedString(" ") }
        let units = Array(text.utf16)
        var result = AttributedString()
        for span in spans {
            let piece = String(decoding: units[span.range], as: UTF16.self)
            var run = AttributedString(piece.replacingOccurrences(of: "\t", with: "    "))
            if let color = DiffColors.token(span.kind) { run.foregroundColor = color }
            if span.isEmphasized { run.backgroundColor = emphasisColor }
            result.append(run)
        }
        return result
    }

    /// The text of a line that has not been styled yet.
    static func plain(_ line: DiffLine) -> AttributedString {
        AttributedString(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
    }

    /// Styles every line of a file's hunks: syntax colors from highlighting
    /// each hunk's old side and new side as fragments, and intraline emphasis
    /// on the lines the split layout pairs.
    static func style(_ file: FileDiff) -> [DiffLine.Numbers: AttributedString] {
        let language = Language(path: file.path)
        var styled: [DiffLine.Numbers: AttributedString] = [:]
        for hunk in file.hunks {
            var emphasis: [DiffLine.Numbers: [Range<Int>]] = [:]
            for case .paired(let deletion, let addition) in hunk.splitRows {
                guard let change = intralineChange(old: deletion.text, new: addition.text) else { continue }
                emphasis[deletion.numbers] = change.old.map { utf16Range($0, in: deletion.text) }
                emphasis[addition.numbers] = change.new.map { utf16Range($0, in: addition.text) }
            }
            let old = hunk.lines.filter { $0.kind != .addition }
            let new = hunk.lines.filter { $0.kind != .deletion }
            // Context lines take their colors from the new side.
            style(old.filter { $0.kind == .deletion }, tokens: tokens(old, language), emphasis: emphasis, into: &styled)
            style(new, tokens: tokens(new, language), emphasis: emphasis, into: &styled)
        }
        return styled
    }

    /// Styles unchanged lines revealed by context expansion. `lines` must be consecutive.
    static func style(context lines: [DiffLine], path: String) -> [DiffLine.Numbers: AttributedString] {
        var styled: [DiffLine.Numbers: AttributedString] = [:]
        style(lines, tokens: tokens(lines, Language(path: path)), emphasis: [:], into: &styled)
        return styled
    }

    private static func tokens(_ lines: [DiffLine], _ language: Language) -> [DiffLine.Numbers: [Token]] {
        guard !lines.isEmpty, language != .plainText else { return [:] }
        let highlighted = Syntax.highlight(lines.map(\.text).joined(separator: "\n"), language: language)
        // A line holding a separator the highlighter splits on would shift every later line.
        guard highlighted.count == lines.count else { return [:] }
        return Dictionary(zip(lines.map(\.numbers), highlighted)) { first, _ in first }
    }

    private static func style(
        _ lines: [DiffLine], tokens: [DiffLine.Numbers: [Token]], emphasis: [DiffLine.Numbers: [Range<Int>]],
        into styled: inout [DiffLine.Numbers: AttributedString]
    ) {
        for line in lines {
            let spans = spans(
                length: line.text.utf16.count, tokens: tokens[line.numbers] ?? [], emphasis: emphasis[line.numbers] ?? []
            )
            let color = line.kind == .deletion ? DiffColors.removedEmphasis : DiffColors.addedEmphasis
            styled[line.numbers] = attributed(line.text, spans: spans, emphasisColor: color)
        }
    }

    private static func utf16Range(_ range: Range<String.Index>, in text: String) -> Range<Int> {
        range.lowerBound.utf16Offset(in: text)..<range.upperBound.utf16Offset(in: text)
    }
}

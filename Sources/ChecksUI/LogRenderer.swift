import AppKit

/// A search hit. `range` is in UTF-16 units of the line's text.
struct LogMatch: Sendable, Equatable {
    var line: Int
    var range: NSRange
}

enum LogSearch {
    /// Every case-insensitive occurrence of `query`, in log order, including
    /// lines inside collapsed groups.
    static func matches(of query: String, in document: LogDocument) -> [LogMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [LogMatch] = []
        for (index, line) in document.lines.enumerated() {
            let text = line.text as NSString
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                matches.append(LogMatch(line: index, range: found))
                searchRange = NSRange(location: found.upperBound, length: text.length - found.upperBound)
            }
        }
        return matches
    }
}

/// The text the log view displays for one set of expanded groups, with the
/// offsets needed to map between log lines and characters.
///
/// Immutable after creation, which is what makes it safe to build off the
/// main actor and hand over.
struct RenderedLog: @unchecked Sendable {
    let text: NSAttributedString
    /// The log line shown on each displayed row.
    let lines: [Int]
    /// The character offset where each row starts.
    let rowStarts: [Int]
    /// The character offset where each row's own text starts, after the
    /// timestamp, disclosure triangle, or "Error:" label.
    let textStarts: [Int]

    /// What the text was rendered from. The text view compares these to
    /// replace only the part of its text that changed.
    let sections: [LogSection]
    let expanded: Set<Int>
    let showTimestamps: Bool

    static let empty = RenderedLog(
        text: NSAttributedString(), lines: [], rowStarts: [], textStarts: [], sections: [], expanded: [], showTimestamps: false
    )

    /// The first row showing `line` or a later line.
    private func firstRow(atOrAfterLine line: Int) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle] < line { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The row showing a log line. Nil when the line is inside a collapsed group.
    func row(ofLine line: Int) -> Int? {
        let row = firstRow(atOrAfterLine: line)
        return row < lines.count && lines[row] == line ? row : nil
    }

    /// The characters of the rows that show the given log lines.
    func characterRange(ofLines range: Range<Int>) -> NSRange {
        let first = firstRow(atOrAfterLine: range.lowerBound), end = firstRow(atOrAfterLine: range.upperBound)
        let start = first < rowStarts.count ? rowStarts[first] : text.length
        return NSRange(location: start, length: (end < rowStarts.count ? rowStarts[end] : text.length) - start)
    }

    /// The one group that is open in only one of the two, when that is the
    /// only difference between them.
    func singleToggledSection(comparedTo other: RenderedLog) -> LogSection? {
        guard showTimestamps == other.showTimestamps, sections.count == other.sections.count else { return nil }
        let changed = expanded.symmetricDifference(other.expanded)
        return changed.count == 1 ? sections[changed.first!] : nil
    }

    /// The row containing a character offset.
    func row(atCharacter offset: Int) -> Int? {
        guard !rowStarts.isEmpty else { return nil }
        var low = 0, high = rowStarts.count
        while low < high {
            let middle = (low + high) / 2
            if rowStarts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    func characterRange(ofRow row: Int) -> NSRange {
        let end = row + 1 < rowStarts.count ? rowStarts[row + 1] : text.length
        return NSRange(location: rowStarts[row], length: end - rowStarts[row])
    }

    /// Whether the row is a group's title. The title starts after the
    /// timestamp, so the row's first character does not tell.
    func isGroupTitle(row: Int) -> Bool {
        text.attribute(LogRenderer.groupTitle, at: textStarts[row], effectiveRange: nil) != nil
    }

    func characterRange(of match: LogMatch) -> NSRange? {
        row(ofLine: match.line).map { NSRange(location: textStarts[$0] + match.range.location, length: match.range.length) }
    }
}

enum LogRenderer {
    // Fonts are immutable once made, so sharing them across threads is safe.
    nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular
    )
    nonisolated(unsafe) static let boldFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)

    /// Marks a group's title row, so the text view can show a pointing hand over it.
    static let groupTitle = NSAttributedString.Key("HermesLogGroupTitle")

    /// What a line inside a group starts with.
    private static let groupIndent = "  "

    /// Builds the display text. Lines inside a group not in `expanded` are left out.
    static func render(_ document: LogDocument, expanded: Set<Int>, showTimestamps: Bool) -> RenderedLog {
        var string = ""
        var length = 0
        var lines: [Int] = []
        var rowStarts: [Int] = []
        var textStarts: [Int] = []
        var attributes: [(NSRange, [NSAttributedString.Key: Any])] = []
        var colors: [ColorKey: NSColor] = [:]

        func color(_ color: LogColor?, dim: Bool = false) -> NSColor {
            let key = ColorKey(color: color, dim: dim)
            if let cached = colors[key] { return cached }
            let made = LogPalette.color(color, dim: dim)
            colors[key] = made
            return made
        }

        func append(_ piece: String, _ pieceAttributes: [NSAttributedString.Key: Any]? = nil) {
            let pieceLength = piece.utf16.count
            if let pieceAttributes, pieceLength > 0 {
                attributes.append((NSRange(location: length, length: pieceLength), pieceAttributes))
            }
            string += piece
            length += pieceLength
        }

        for (index, line) in document.lines.enumerated() {
            if line.kind != .group, let section = line.section, !expanded.contains(section) { continue }

            let rowStart = length
            lines.append(index)
            rowStarts.append(rowStart)

            if showTimestamps {
                append(clockTime(line.timestamp) + "  ", [.foregroundColor: NSColor.tertiaryLabelColor])
            }

            if line.kind != .group, line.section != nil { append(groupIndent) }
            let contentStart = length
            var lineAttributes: [NSAttributedString.Key: Any] = [:]
            switch line.kind {
            case .plain: break
            case .group:
                let isOpen = line.section.map(expanded.contains) ?? false
                append(isOpen ? "▾ " : "▸ ", [.foregroundColor: NSColor.secondaryLabelColor])
                lineAttributes = [.font: boldFont, groupTitle: true]
            case .error:
                append("Error: ", [.font: boldFont])
                lineAttributes = [.foregroundColor: color(.palette(1)), .backgroundColor: NSColor.systemRed.withAlphaComponent(0.14)]
            case .warning:
                append("Warning: ", [.font: boldFont])
                lineAttributes = [.foregroundColor: color(.palette(3)), .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.16)]
            case .notice:
                append("Notice: ", [.font: boldFont])
                lineAttributes = [.foregroundColor: color(.palette(4)), .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.12)]
            case .command:
                lineAttributes = [.foregroundColor: color(.palette(4))]
            }

            let textStart = length
            textStarts.append(textStart)
            append(line.text)

            // Line attributes first, so a span's own color wins over them.
            if !lineAttributes.isEmpty {
                attributes.append((NSRange(location: contentStart, length: length - contentStart), lineAttributes))
            }
            for span in line.spans {
                var spanAttributes: [NSAttributedString.Key: Any] = [:]
                if span.style.color != nil || span.style.dim {
                    spanAttributes[.foregroundColor] = color(span.style.color, dim: span.style.dim)
                }
                if span.style.bold { spanAttributes[.font] = boldFont }
                if span.style.underline { spanAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                attributes.append((NSRange(location: textStart + span.range.lowerBound, length: span.range.count), spanAttributes))
            }

            append("\n")
        }

        // Wrapped lines continue under the text, not under the timestamps.
        let paragraph = NSMutableParagraphStyle()
        if showTimestamps { paragraph.headIndent = font.maximumAdvancement.width * 15 }
        let text = NSMutableAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        )
        text.beginEditing()
        for (range, rangeAttributes) in attributes { text.addAttributes(rangeAttributes, range: range) }
        text.endEditing()
        return RenderedLog(
            text: text, lines: lines, rowStarts: rowStarts, textStarts: textStarts,
            sections: document.sections, expanded: expanded, showTimestamps: showTimestamps
        )
    }

    /// The log as plain text, every group included.
    static func plainText(_ document: LogDocument, showTimestamps: Bool) -> String {
        document.lines.map { line in
            showTimestamps ? "\(line.timestamp ?? "") \(line.text)" : line.text
        }.joined(separator: "\n")
    }

    /// `2026-11-11T02:46:28.1143357Z` as `02:46:28.114Z`. Blank of the same
    /// width for a row without a timestamp, so text lines up.
    static func clockTime(_ timestamp: String?) -> String {
        // Runner timestamps always carry fractional seconds.
        guard let time = timestamp?.split(separator: "T").last?.dropLast(), time.count >= 10 else {
            return String(repeating: " ", count: 13)
        }
        return time.prefix(12).padding(toLength: 12, withPad: "0", startingAt: 0) + "Z"
    }

    private struct ColorKey: Hashable {
        var color: LogColor?
        var dim: Bool
    }
}

enum LogPalette {
    struct RGB: Equatable {
        var red: Double, green: Double, blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            (self.red, self.green, self.blue) = (red, green, blue)
        }

        init(hex: UInt32) {
            self.init(Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }

        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    /// The 16 named colors, as (light appearance, dark appearance). "Black"
    /// and "white" are grays that stay readable on either background.
    static let named: [(light: UInt32, dark: UInt32)] = [
        (0x24292F, 0xB1BAC4), (0xCF222E, 0xFF7B72), (0x116329, 0x3FB950), (0x7D4E00, 0xD29922),
        (0x0969DA, 0x58A6FF), (0x8250DF, 0xBC8CFF), (0x1B7C83, 0x39C5CF), (0x6E7781, 0xB1BAC4),
        (0x57606A, 0x8B949E), (0xA40E26, 0xFFA198), (0x1A7F37, 0x56D364), (0x633C01, 0xE3B341),
        (0x218BFF, 0x79C0FF), (0xA475F9, 0xD2A8FF), (0x3192AA, 0x56D4DD), (0x8C959F, 0xF0F6FC),
    ]

    /// Moves an arbitrary color far enough from the background to read as
    /// text: darker on a light background, lighter on a dark one.
    static func readable(_ color: RGB, onDark: Bool) -> RGB {
        let luminance = color.luminance
        if onDark {
            guard luminance < 0.5 else { return color }
            let toWhite = (0.5 - luminance) / (1 - luminance)
            return RGB(
                color.red + (1 - color.red) * toWhite,
                color.green + (1 - color.green) * toWhite,
                color.blue + (1 - color.blue) * toWhite
            )
        }
        guard luminance > 0.4 else { return color }
        let scale = 0.4 / luminance
        return RGB(color.red * scale, color.green * scale, color.blue * scale)
    }

    static func resolve(_ color: LogColor, onDark: Bool) -> RGB {
        switch color {
        case .palette(let index):
            let pair = named[Int(index) % named.count]
            return RGB(hex: onDark ? pair.dark : pair.light)
        case .rgb(let red, let green, let blue):
            return readable(RGB(Double(red) / 255, Double(green) / 255, Double(blue) / 255), onDark: onDark)
        }
    }

    /// A color that follows the view's appearance. Nil is the default text color.
    static func color(_ color: LogColor?, dim: Bool) -> NSColor {
        guard let color else { return dim ? .secondaryLabelColor : .labelColor }
        return NSColor(name: nil) { appearance in
            let onDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = resolve(color, onDark: onDark)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: dim ? 0.6 : 1)
        }
    }
}

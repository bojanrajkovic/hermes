import Foundation

/// A color set by an ANSI escape sequence.
enum LogColor: Sendable, Hashable {
    /// One of the 16 named terminal colors: 0-7 normal, 8-15 bright.
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    /// A color from the 256-color table.
    init(indexed index: UInt8) {
        switch index {
        case 0..<16:
            self = .palette(index)
        case 16..<232:
            let cube = index - 16
            let level: (UInt8) -> UInt8 = { $0 == 0 ? 0 : 55 + 40 * $0 }
            self = .rgb(level(cube / 36), level(cube / 6 % 6), level(cube % 6))
        default:
            let gray = 8 + 10 * (index - 232)
            self = .rgb(gray, gray, gray)
        }
    }
}

/// The text style ANSI SGR codes have set at some point in a line.
struct LogStyle: Sendable, Hashable {
    var color: LogColor?
    var bold = false
    var dim = false
    var underline = false

    static let plain = LogStyle()

    /// Applies the parameters of one `ESC [ ... m` sequence. Codes for things
    /// the viewer does not draw (background, italic, blink) are skipped.
    mutating func apply(sgr parameters: [Int]) {
        var index = 0
        while index < parameters.count {
            let code = parameters[index]
            index += 1
            switch code {
            case 0: self = .plain
            case 1: bold = true
            case 2: dim = true
            case 4: underline = true
            case 22: (bold, dim) = (false, false)
            case 24: underline = false
            case 30...37: color = .palette(UInt8(code - 30))
            case 39: color = nil
            case 90...97: color = .palette(UInt8(code - 90 + 8))
            case 38, 48:
                // 38;5;n and 38;2;r;g;b. The 48 forms set the background: consumed, not drawn.
                var parsed: LogColor?
                if index < parameters.count, parameters[index] == 5 {
                    if index + 1 < parameters.count, let value = UInt8(exactly: parameters[index + 1]) {
                        parsed = LogColor(indexed: value)
                    }
                    index += 2
                } else if index < parameters.count, parameters[index] == 2 {
                    if index + 3 < parameters.count,
                       let red = UInt8(exactly: parameters[index + 1]),
                       let green = UInt8(exactly: parameters[index + 2]),
                       let blue = UInt8(exactly: parameters[index + 3]) {
                        parsed = .rgb(red, green, blue)
                    }
                    index += 4
                }
                if code == 38, let parsed { color = parsed }
            default: break
            }
        }
    }
}

/// One line of a job log, with timestamps, markers, and escape sequences removed.
struct LogLine: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case plain
        /// The title line of a collapsible group.
        case group
        case error
        case warning
        case notice
        /// A command the runner echoed before running it.
        case command
    }

    /// A run of text in one style. `range` is in UTF-16 units of `text`.
    struct Span: Sendable, Equatable {
        var range: Range<Int>
        var style: LogStyle
    }

    /// The runner's timestamp, such as `2026-11-11T02:46:28.1143357Z`. Nil
    /// when the line has none.
    var timestamp: String?
    var kind: Kind = .plain
    var text: String
    /// The styled runs. Unstyled text has no span.
    var spans: [Span] = []
    /// The group this line is the title of or belongs to.
    var section: Int?
}

/// A collapsible group: a `##[group]` title line and the lines up to `##[endgroup]`.
struct LogSection: Sendable, Equatable {
    /// Index of the title line.
    var header: Int
    /// Indices of the lines inside the group.
    var body: Range<Int>
    var containsError = false
}

/// A parsed job log.
struct LogDocument: Sendable, Equatable {
    var lines: [LogLine] = []
    var sections: [LogSection] = []
    /// Index of the first `##[error]` line.
    var firstError: Int?

    /// The sections to show open when the log first appears: the ones with an error.
    var sectionsWithErrors: Set<Int> {
        Set(sections.indices.filter { sections[$0].containsError })
    }
}

enum LogParser {
    /// Parses the raw text of a GitHub Actions job log.
    ///
    /// Groups do not nest: a `##[group]` inside an open group starts a new
    /// one, as on github.com. `##[endgroup]` lines are dropped.
    static func parse(_ raw: String) -> LogDocument {
        var document = LogDocument()
        var open: Int?

        func close(at end: Int) {
            guard let section = open else { return }
            document.sections[section].body = (document.sections[section].header + 1)..<end
            open = nil
        }

        var raw = raw
        raw.withUTF8 { bytes in
            var start = bytes.startIndex
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start += 3 }

            while start < bytes.endIndex {
                let newline = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
                var end = newline
                if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                var content = bytes[start..<end]
                start = newline + 1

                var line = LogLine(timestamp: takeTimestamp(&content), text: "")
                let marker = takeMarker(&content)
                if marker == .endGroup {
                    close(at: document.lines.count)
                    continue
                }

                (line.text, line.spans) = stripEscapes(content)
                switch marker {
                case .group:
                    close(at: document.lines.count)
                    line.kind = .group
                    open = document.sections.count
                    document.sections.append(LogSection(header: document.lines.count, body: 0..<0))
                case .error:
                    line.kind = .error
                    if document.firstError == nil { document.firstError = document.lines.count }
                    if let open { document.sections[open].containsError = true }
                case .warning: line.kind = .warning
                case .notice: line.kind = .notice
                case .command: line.kind = .command
                case .endGroup, nil: break
                }
                line.section = open
                document.lines.append(line)
            }
        }
        close(at: document.lines.count)
        return document
    }

    private enum Marker { case group, endGroup, error, warning, notice, command }

    private static let markers: [(prefix: [UInt8], marker: Marker)] = ([
        ("##[group]", .group), ("##[endgroup]", .endGroup), ("##[error]", .error),
        ("##[warning]", .warning), ("##[notice]", .notice), ("##[command]", .command),
        ("[command]", .command),
    ] as [(String, Marker)]).map { (Array($0.0.utf8), $0.1) }

    private static func takeMarker(_ content: inout Slice<UnsafeBufferPointer<UInt8>>) -> Marker? {
        guard let first = content.first, first == UInt8(ascii: "#") || first == UInt8(ascii: "[") else { return nil }
        for (prefix, marker) in markers where content.starts(with: prefix) {
            content = content.dropFirst(prefix.count)
            return marker
        }
        return nil
    }

    /// Removes a leading `2026-11-11T02:46:28.1143357Z ` and returns it without the space.
    private static func takeTimestamp(_ content: inout Slice<UnsafeBufferPointer<UInt8>>) -> String? {
        let base = content.startIndex
        guard content.count >= 21,
              content[base + 4] == UInt8(ascii: "-"), content[base + 7] == UInt8(ascii: "-"),
              content[base + 10] == UInt8(ascii: "T"), content[base + 13] == UInt8(ascii: ":"),
              content[base].isDigit, content[base + 11].isDigit,
              let zulu = content.prefix(40).firstIndex(of: UInt8(ascii: "Z")),
              zulu + 1 == content.endIndex || content[zulu + 1] == UInt8(ascii: " ")
        else { return nil }
        let timestamp = String(decoding: content[base...zulu], as: UTF8.self)
        content = content[min(zulu + 2, content.endIndex)...]
        return timestamp
    }

    /// Removes escape sequences. SGR sequences become spans; any other
    /// sequence and stray control characters are dropped.
    private static func stripEscapes(_ content: Slice<UnsafeBufferPointer<UInt8>>) -> (String, [LogLine.Span]) {
        guard content.contains(where: { $0 < 0x20 && $0 != 0x09 }) else {
            return (String(decoding: content, as: UTF8.self), [])
        }

        var text = ""
        var length = 0
        var spans: [LogLine.Span] = []
        var style = LogStyle.plain
        var index = content.startIndex

        func append(_ piece: Slice<UnsafeBufferPointer<UInt8>>) {
            guard !piece.isEmpty else { return }
            let string = String(decoding: piece, as: UTF8.self)
            let pieceLength = string.utf16.count
            if style != .plain {
                if let last = spans.last, last.style == style, last.range.upperBound == length {
                    spans[spans.count - 1].range = last.range.lowerBound..<(length + pieceLength)
                } else {
                    spans.append(.init(range: length..<(length + pieceLength), style: style))
                }
            }
            text += string
            length += pieceLength
        }

        while index < content.endIndex {
            let control = content[index...].firstIndex(where: { $0 < 0x20 && $0 != 0x09 }) ?? content.endIndex
            append(content[index..<control])
            guard control < content.endIndex else { break }
            index = control + 1
            guard content[control] == 0x1B, index < content.endIndex else { continue }

            switch content[index] {
            case UInt8(ascii: "["):
                // CSI: parameters, then a final byte in 0x40...0x7E.
                let final = content[(index + 1)...].firstIndex(where: { (0x40...0x7E).contains($0) }) ?? content.endIndex
                if final < content.endIndex, content[final] == UInt8(ascii: "m") {
                    let parameters = content[(index + 1)..<final].split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
                        .map { Int(String(decoding: $0, as: UTF8.self)) ?? 0 }
                    style.apply(sgr: parameters)
                }
                index = min(final + 1, content.endIndex)
            case UInt8(ascii: "]"):
                // OSC: ends at BEL or ESC \.
                let rest = content[(index + 1)...]
                if let bell = rest.firstIndex(of: 0x07) {
                    index = bell + 1
                } else if let escape = rest.firstIndex(of: 0x1B) {
                    index = min(escape + 2, content.endIndex)
                } else {
                    index = content.endIndex
                }
            default:
                // A two-byte sequence such as ESC c.
                index += 1
            }
        }
        return (text, spans)
    }
}

private extension UInt8 {
    var isDigit: Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) }
}

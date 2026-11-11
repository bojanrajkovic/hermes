import Foundation

/// A line-at-a-time parser over the diff's UTF-8 bytes. Lines are byte ranges;
/// a `String` is only built for text the result keeps.
struct DiffParser {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var position = 0
    /// The current line, without its `\n`. `nil` at the end of input.
    private var line: Range<Int>?

    static func parse(_ text: String) -> [FileDiff] {
        var text = text
        return text.withUTF8 { bytes in
            guard !bytes.isEmpty else { return [] }
            var parser = DiffParser(bytes: bytes)
            parser.advance()
            var files: [FileDiff] = []
            var entriesByPath: [String: Int] = [:]
            while let line = parser.line {
                if let rest = parser.dropPrefix("diff --git ", from: line) {
                    files.append(parser.parseFile(gitLine: rest, entriesByPath: &entriesByPath))
                } else {
                    parser.advance()
                }
            }
            return files
        }
    }

    private init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    // MARK: Lines

    private mutating func advance() {
        guard position < bytes.count, let base = bytes.baseAddress else {
            line = nil
            return
        }
        let start = position
        if let newline = memchr(base + start, 0x0A, bytes.count - start) {
            let end = base.distance(to: newline.assumingMemoryBound(to: UInt8.self))
            line = start..<end
            position = end + 1
        } else {
            line = start..<bytes.count
            position = bytes.count
        }
    }

    /// The part of `line` after `prefix`, or `nil` when the line does not start with it.
    private func dropPrefix(_ prefix: StaticString, from line: Range<Int>) -> Range<Int>? {
        let count = prefix.utf8CodeUnitCount
        guard line.count >= count, let base = bytes.baseAddress,
              memcmp(base + line.lowerBound, prefix.utf8Start, count) == 0
        else { return nil }
        return (line.lowerBound + count)..<line.upperBound
    }

    private func string(_ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    // MARK: Files

    private mutating func parseFile(gitLine: Range<Int>, entriesByPath: inout [String: Int]) -> FileDiff {
        advance()
        var oldMode: String?, newMode: String?
        var isNew = false, isDeleted = false, isBinary = false
        var renameFrom: String?, renameTo: String?, copyFrom: String?, copyTo: String?
        var minusPath: String?, plusPath: String?

        // "diff --" also stops at a combined entry ("diff --cc"), whose
        // ---/+++ lines would otherwise replace this file's paths.
        while let line, dropPrefix("diff --", from: line) == nil, dropPrefix("@@ ", from: line) == nil {
            if let rest = dropPrefix("old mode ", from: line) {
                oldMode = string(rest)
            } else if let rest = dropPrefix("new mode ", from: line) {
                newMode = string(rest)
            } else if let rest = dropPrefix("new file mode ", from: line) {
                isNew = true
                newMode = string(rest)
            } else if let rest = dropPrefix("deleted file mode ", from: line) {
                isDeleted = true
                oldMode = string(rest)
            } else if let rest = dropPrefix("rename from ", from: line) {
                renameFrom = path(rest)
            } else if let rest = dropPrefix("rename to ", from: line) {
                renameTo = path(rest)
            } else if let rest = dropPrefix("copy from ", from: line) {
                copyFrom = path(rest)
            } else if let rest = dropPrefix("copy to ", from: line) {
                copyTo = path(rest)
            } else if let rest = dropPrefix("index ", from: line) {
                // "index abc..def 100644" states the unchanged mode of a modified file.
                if let space = bytes[rest].lastIndex(of: 0x20) {
                    let mode = string((space + 1)..<rest.upperBound)
                    oldMode = oldMode ?? mode
                    newMode = newMode ?? mode
                }
            } else if let rest = dropPrefix("--- ", from: line) {
                minusPath = path(rest, strippingPrefix: true)
                isNew = isNew || minusPath == nil
            } else if let rest = dropPrefix("+++ ", from: line) {
                plusPath = path(rest, strippingPrefix: true)
                isDeleted = isDeleted || plusPath == nil
            } else if dropPrefix("Binary files ", from: line) != nil || dropPrefix("GIT binary patch", from: line) != nil {
                isBinary = true
            }
            advance()
        }

        var hunks: [Hunk] = []
        var additions = 0, deletions = 0
        while let line, let header = dropPrefix("@@ ", from: line),
              let hunk = parseHunk(header: header, additions: &additions, deletions: &deletions) {
            hunks.append(hunk)
        }

        // Without rename lines or ---/+++ lines (mode change, empty file,
        // binary), the only path is on the "diff --git" line.
        let old = renameFrom ?? copyFrom ?? minusPath
        let new = renameTo ?? copyTo ?? plusPath
        let fallback = pathFromGitLine(gitLine)
        let change: FileChange =
            if isNew {
                .added(path: new ?? fallback)
            } else if isDeleted {
                .deleted(path: old ?? fallback)
            } else if let renameFrom, let renameTo {
                .renamed(from: renameFrom, to: renameTo)
            } else if let copyFrom, let copyTo {
                .copied(from: copyFrom, to: copyTo)
            } else {
                .modified(path: new ?? old ?? fallback)
            }

        // A type change (file to symlink, say) is a deleted entry and an added
        // entry with the same path. NUL cannot occur in a path.
        let path = change.path
        let earlier = entriesByPath[path, default: 0]
        entriesByPath[path] = earlier + 1

        return FileDiff(
            id: earlier == 0 ? path : "\(path)\0\(earlier)",
            change: change,
            content: isBinary ? .binary : .text(hunks),
            oldMode: isNew ? nil : oldMode,
            newMode: isDeleted ? nil : newMode,
            additions: additions,
            deletions: deletions
        )
    }

    // MARK: Hunks

    /// Parses the hunk whose header is the current line. The line counts in
    /// the header decide where the hunk ends, so content that looks like a
    /// header (a deleted line reading `-- x`, say) is read as content.
    private mutating func parseHunk(header: Range<Int>, additions: inout Int, deletions: inout Int) -> Hunk? {
        var cursor = header.lowerBound
        guard let (oldStart, oldCount) = parseRange(sign: 0x2D, at: &cursor, end: header.upperBound),
              cursor < header.upperBound, bytes[cursor] == 0x20
        else { return nil }
        cursor += 1
        guard let (newStart, newCount) = parseRange(sign: 0x2B, at: &cursor, end: header.upperBound),
              let afterMarker = dropPrefix(" @@", from: cursor..<header.upperBound)
        else { return nil }
        let heading = dropPrefix(" ", from: afterMarker) ?? afterMarker
        advance()

        var lines: [DiffLine] = []
        // A line takes at least one byte, so a bogus count cannot reserve more than the input holds.
        lines.reserveCapacity(min(oldCount + newCount, bytes.count - position))
        var old = oldStart, new = newStart
        var oldLeft = oldCount, newLeft = newCount

        scan: while oldLeft > 0 || newLeft > 0, let line {
            // A tool that strips trailing whitespace turns an empty context line into an empty line.
            let marker = line.isEmpty ? 0x20 : bytes[line.lowerBound]
            let numbers: DiffLine.Numbers
            switch marker {
            case 0x20 where oldLeft > 0 && newLeft > 0:
                numbers = .context(old: old, new: new)
                old += 1; new += 1; oldLeft -= 1; newLeft -= 1
            case 0x2B where newLeft > 0:
                numbers = .addition(new: new)
                new += 1; newLeft -= 1; additions += 1
            case 0x2D where oldLeft > 0:
                numbers = .deletion(old: old)
                old += 1; oldLeft -= 1; deletions += 1
            case 0x5C:
                markNoNewline(&lines)
                advance()
                continue scan
            default:
                break scan
            }
            var content = line.isEmpty ? line : (line.lowerBound + 1)..<line.upperBound
            var ending = LineEnding.lf
            if let last = content.last, bytes[last] == 0x0D {
                content = content.lowerBound..<last
                ending = .crlf
            }
            lines.append(DiffLine(numbers: numbers, text: string(content), ending: ending))
            advance()
        }
        if let line, !line.isEmpty, bytes[line.lowerBound] == 0x5C {
            markNoNewline(&lines)
            advance()
        }

        return Hunk(
            oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
            sectionHeading: string(heading), lines: lines
        )
    }

    /// Applies `\ No newline at end of file` to the line before it.
    private func markNoNewline(_ lines: inout [DiffLine]) {
        guard let last = lines.popLast() else { return }
        // A "\r" before the missing newline is content, not half of a CRLF.
        let text = last.ending == .crlf ? last.text + "\r" : last.text
        lines.append(DiffLine(numbers: last.numbers, text: text, ending: .none))
    }

    /// Parses `-12,3` or `+12` (count 1) starting at `cursor`.
    private func parseRange(sign: UInt8, at cursor: inout Int, end: Int) -> (start: Int, count: Int)? {
        guard cursor < end, bytes[cursor] == sign else { return nil }
        cursor += 1
        guard let start = parseInt(at: &cursor, end: end) else { return nil }
        guard cursor < end, bytes[cursor] == 0x2C else { return (start, 1) }
        cursor += 1
        guard let count = parseInt(at: &cursor, end: end) else { return nil }
        return (start, count)
    }

    private func parseInt(at cursor: inout Int, end: Int) -> Int? {
        let start = cursor
        var value = 0
        // 15 digits cannot overflow Int.
        while cursor < end, cursor - start < 15, case let digit = bytes[cursor], digit >= 0x30, digit <= 0x39 {
            value = value * 10 + Int(digit - 0x30)
            cursor += 1
        }
        return cursor > start ? value : nil
    }

    // MARK: Paths

    /// Reads a path from a header line. Returns `nil` for `/dev/null`.
    ///
    /// - Parameter strippingPrefix: Drop the leading `a/` or `b/` that `---`
    ///   and `+++` lines carry. Rename and copy lines have no prefix.
    private func path(_ range: Range<Int>, strippingPrefix: Bool = false) -> String? {
        var path: String
        if let quoted = unquote(range) {
            path = quoted.path
        } else {
            // Git puts a tab after a ---/+++ path that contains a space.
            // A path that contains a tab is always quoted.
            let end = bytes[range].firstIndex(of: 0x09) ?? range.upperBound
            path = string(range.lowerBound..<end)
        }
        if !strippingPrefix { return path }
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path.removeFirst(2) }
        return path
    }

    /// Reads the path from `a/<path> b/<path>`. Only used when both paths are
    /// the same, which is what makes an unquoted line with spaces splittable.
    private func pathFromGitLine(_ range: Range<Int>) -> String {
        if let quoted = unquote(range) {
            return String(quoted.path.dropFirst(2))
        }
        let half = (range.count - 1) / 2
        if range.count >= 7, range.count % 2 == 1, bytes[range.lowerBound + half] == 0x20 {
            return string((range.lowerBound + 2)..<(range.lowerBound + half))
        }
        return string(range).split(separator: " ").first.map { String($0.dropFirst(2)) } ?? ""
    }

    /// Decodes a C-style quoted path (`"dir/\303\251.txt"`), which git uses for
    /// paths with control characters, quotes, backslashes, or non-ASCII bytes.
    /// Returns `nil` when `range` does not start with a quote.
    private func unquote(_ range: Range<Int>) -> (path: String, end: Int)? {
        guard let first = range.first, bytes[first] == 0x22 else { return nil }
        var out: [UInt8] = []
        var cursor = first + 1
        while cursor < range.upperBound, bytes[cursor] != 0x22 {
            var byte = bytes[cursor]
            cursor += 1
            if byte == 0x5C, cursor < range.upperBound {
                let escape = bytes[cursor]
                cursor += 1
                switch escape {
                case UInt8(ascii: "n"): byte = 0x0A
                case UInt8(ascii: "t"): byte = 0x09
                case UInt8(ascii: "r"): byte = 0x0D
                case UInt8(ascii: "a"): byte = 0x07
                case UInt8(ascii: "b"): byte = 0x08
                case UInt8(ascii: "f"): byte = 0x0C
                case UInt8(ascii: "v"): byte = 0x0B
                case 0x30...0x37:
                    var value = Int(escape - 0x30)
                    var digits = 1
                    while digits < 3, cursor < range.upperBound, case let digit = bytes[cursor], (0x30...0x37).contains(digit) {
                        value = value * 8 + Int(digit - 0x30)
                        cursor += 1
                        digits += 1
                    }
                    byte = UInt8(truncatingIfNeeded: value)
                default: byte = escape
                }
            }
            out.append(byte)
        }
        return (String(decoding: out, as: UTF8.self), cursor + 1)
    }
}

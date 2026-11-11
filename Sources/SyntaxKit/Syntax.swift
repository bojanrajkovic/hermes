import Foundation
import SwiftTreeSitter

/// Syntax highlighting, identifier lookup, and definition search, built on tree-sitter.
///
/// Every function is synchronous, keeps no state between calls except compiled
/// queries, and is safe to call from any task or thread.
///
/// ## Lines and columns
///
/// Lines are the pieces of the source between line feeds (U+000A), so a result has
/// one entry per element of `source.components(separatedBy: "\n")`. A source that
/// ends in a line feed has an empty last line. In a CRLF file the carriage return is
/// the last code unit of its line. Do not count lines with `String.split`: Swift
/// treats `"\r\n"` as one `Character`, which is not equal to `"\n"`.
///
/// Line indexes and columns are zero-based. Columns and ranges count UTF-16 code units
/// from the start of the line, which matches `NSString` and `NSAttributedString`.
///
/// ## Fragments
///
/// The source does not have to be a whole file. Tree-sitter recovers from syntax
/// errors, so a diff hunk still gets tokens for the parts it can recognize. Recovery
/// is approximate: a hunk that starts inside a function can lose a keyword or two
/// near its edges. Highlight the whole file when it is available.
///
/// ## Limits
///
/// Sources larger than ``maximumSourceBytes`` or with a line longer than
/// ``maximumLineLength`` (minified code) are not parsed. They highlight as plain
/// text and have no identifiers or definitions.
///
/// ## Resources
///
/// The queries live in SwiftPM resource bundles: one per grammar package plus
/// `Hermes_SyntaxKit.bundle`. They are found next to the test bundle under `swift test`
/// and in `Contents/Resources` of the running app, so the app bundle must contain
/// every `*.bundle` directory from the build's products directory. When a bundle is
/// missing, the affected language highlights as plain text and an error is logged
/// under the `SyntaxKit` subsystem.
public enum Syntax {
    /// Sources with more UTF-8 bytes than this are not parsed.
    public static let maximumSourceBytes = 1_000_000
    /// Sources with a line of more UTF-16 code units than this are not parsed.
    public static let maximumLineLength = 5_000

    /// Splits each line of `source` into tokens.
    ///
    /// - Parameters:
    ///   - source: A whole file or a fragment of one.
    ///   - language: The language to parse as, usually from ``Language/init(path:firstLine:)``.
    /// - Returns: One array per line. A line's tokens are in order and cover it
    ///   completely, with ``TokenKind/plain`` filling whatever has no highlight, so an
    ///   empty line has no tokens. Plain-text and over-limit sources yield one plain
    ///   token per non-empty line.
    public static func highlight(_ source: String, language: Language) -> [[Token]] {
        let text = SourceText(source)
        var paint = [UInt8](repeating: TokenKind.plain.rawValue, count: text.units.count)

        if text.isParseable, let highlights = Grammar.highlights(for: language),
            let tree = parse(source, as: language)
        {
            var captures: [(range: NSRange, kind: TokenKind, pattern: Int)] = []
            let context = text.predicateContext
            for match in highlights.query.execute(in: tree) where match.allowed(in: context) {
                // Ruby captures every identifier as a method call unless it is a local
                // variable. Locals are not tracked, so such a pattern never applies.
                // shortcut: a bare call such as `name` highlights as a variable; run
                // locals.scm to tell the two apart.
                if !match.predicates.isEmpty, match.predicates.allSatisfy({ if case .isNot = $0 { true } else { false } }) {
                    continue
                }
                for capture in match.captures {
                    guard var kind = highlights.kinds[capture.index] else { continue }
                    // After a syntax error a Swift keyword can come back as an identifier.
                    if kind == .variable, language == .swift, capture.range.length <= 14,
                        capture.range.upperBound <= text.units.count,
                        swiftReservedWords.contains(text.string(in: capture.range))
                    {
                        kind = .keyword
                    }
                    captures.append((capture.range, kind, match.patternIndex))
                }
            }
            // Paint outer nodes first so the nodes inside them show through, and for
            // captures of one node paint the winner last.
            captures.sort {
                ($1.range.length, $0.kind.rank, $0.pattern) < ($0.range.length, $1.kind.rank, $1.pattern)
            }
            for capture in captures {
                let end = min(capture.range.upperBound, paint.count)
                for index in capture.range.location..<max(end, capture.range.location) {
                    paint[index] = capture.kind.rawValue
                }
            }
            if let root = tree.rootNode, root.hasError {
                paintStrayKeywords(under: root, into: &paint)
            }
        }

        return text.lineStarts.indices.map { index in
            let line = text.lineRange(index)
            var tokens: [Token] = []
            var start = line.lowerBound
            for index in line where index + 1 == line.upperBound || paint[index + 1] != paint[start] {
                // Every value in `paint` came from a TokenKind raw value.
                let kind = TokenKind(rawValue: paint[start]) ?? .plain
                tokens.append(Token(range: (start - line.lowerBound)..<(index + 1 - line.lowerBound), kind: kind))
                start = index + 1
            }
            return tokens
        }
    }

    /// Paints the keywords the highlight query missed because of a syntax error.
    ///
    /// Most highlight patterns name a keyword inside its statement, such as
    /// `(if_statement "if")`. In a fragment the statement often fails to parse, which
    /// leaves the keyword as a bare token no pattern matches. A keyword is an
    /// anonymous token spelled in lowercase letters; only unpainted ones change.
    private static func paintStrayKeywords(under root: Node, into paint: inout [UInt8]) {
        let cursor = root.treeCursor
        walk: while true {
            guard let node = cursor.currentNode else { break }
            if node.childCount == 0, !node.isNamed, !node.isMissing {
                let range = node.range
                if range.length > 1, range.upperBound <= paint.count,
                    paint[range.location..<range.upperBound].allSatisfy({ $0 == TokenKind.plain.rawValue }),
                    node.nodeType?.utf8.allSatisfy({ (0x61...0x7A).contains($0) }) == true
                {
                    for index in range.location..<range.upperBound { paint[index] = TokenKind.keyword.rawValue }
                }
            }
            // Subtrees without errors were matched by the query as usual.
            if node.hasError, cursor.goToFirstChild() { continue }
            while !cursor.gotoNextSibling() {
                if !cursor.gotoParent() { break walk }
            }
        }
    }

    /// Words Swift reserves, so none of them can be a variable name without backticks.
    private static let swiftReservedWords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "private", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
        "switch", "where", "while", "as", "is", "throws", "try",
    ]

    /// Finds the identifiers go-to-definition can start from: names of functions,
    /// types, variables, and properties. Keywords, literals, and comments are excluded.
    ///
    /// - Returns: One entry per line. Every line is empty for languages without
    ///   definition support (JSON, YAML, TOML, HTML, CSS, plain text) and for
    ///   over-limit sources.
    public static func identifiers(in source: String, language: Language) -> IdentifierMap {
        let text = SourceText(source)
        var lines = [[Identifier]](repeating: [], count: text.lineStarts.count)
        let symbols = Grammar.identifierSymbols(for: language)
        guard text.isParseable, !symbols.isEmpty, let root = parse(source, as: language)?.rootNode else {
            return IdentifierMap(lines: lines)
        }

        let cursor = root.treeCursor
        walk: while true {
            if let node = cursor.currentNode, node.childCount == 0, symbols.contains(node.symbol),
                // In Bash a `word` is only a name where it is the command being run.
                node.nodeType != "word" || node.parent?.nodeType == "command_name"
            {
                let start = node.pointRange.lowerBound
                // Tree-sitter counts columns in bytes of the UTF-16 input.
                let column = Int(start.column) / 2
                let range = node.range
                if range.length > 0, lines.indices.contains(Int(start.row)) {
                    lines[Int(start.row)].append(Identifier(name: text.string(in: range), range: column..<(column + range.length)))
                }
            }
            if cursor.goToFirstChild() { continue }
            while !cursor.gotoNextSibling() {
                if !cursor.gotoParent() { break walk }
            }
        }
        return IdentifierMap(lines: lines)
    }

    /// Finds where `source` defines `name`.
    ///
    /// Definitions are functions, methods, types, type aliases, modules, fields and
    /// properties, enum cases, top-level constants and variables, and in HCL the
    /// `resource`, `data`, `variable`, `output`, `module`, and `locals` entries.
    /// Local variables and parameters are not definitions.
    ///
    /// A file that does not contain `name` returns without being parsed, so this is
    /// cheap to run over every file a repository search turns up.
    ///
    /// - Parameters:
    ///   - name: The exact, case-sensitive identifier.
    ///   - source: A whole source file.
    ///   - language: The file's language.
    /// - Returns: The definitions in source order. Empty when there are none, the
    ///   language has no definition support, or the source is over the limits.
    public static func definitions(named name: String, in source: String, language: Language) -> [Definition] {
        guard !name.isEmpty, source.contains(name), let definitions = Grammar.definitions(for: language) else {
            return []
        }
        let text = SourceText(source)
        guard text.isParseable, let tree = parse(source, as: language) else { return [] }

        let needle = Array(name.utf16)
        let context = text.predicateContext
        var found: [Int: (kind: DefinitionKind, start: Point)] = [:]
        for match in definitions.query.execute(in: tree) {
            guard let nameCapture = match.captures.first(where: { $0.index == definitions.nameCapture }),
                let kind = match.captures.lazy.compactMap({ definitions.kinds[$0.index] }).first
            else { continue }
            var range = nameCapture.range
            var start = nameCapture.node.pointRange.lowerBound
            // A Ruby symbol names a definition without its colon: `attr_reader :size`.
            if nameCapture.node.nodeType == "simple_symbol" {
                range = NSRange(location: range.location + 1, length: range.length - 1)
                // Columns count bytes of the UTF-16 input.
                start = Point(row: Int(start.row), column: Int(start.column) + 2)
            }
            guard range.length == needle.count, text.units[range.location..<range.upperBound].elementsEqual(needle),
                match.allowed(in: context)
            else { continue }
            // Several patterns can match one name. Keep the most specific kind.
            if let existing = found[range.location], existing.kind.specificity >= kind.specificity { continue }
            found[range.location] = (kind, start)
        }

        return found.sorted { $0.key < $1.key }.map { _, definition in
            let line = Int(definition.start.row)
            return Definition(
                line: line,
                utf16Column: Int(definition.start.column) / 2,
                kind: definition.kind,
                lineText: text.string(in: NSRange(text.lineRange(line))).trimmingCharacters(in: ["\r"])
            )
        }
    }

    /// Parses with a fresh parser. Parsers are cheap to create and not thread-safe.
    private static func parse(_ source: String, as language: Language) -> MutableTree? {
        guard let grammar = language.treeSitter else { return nil }
        let parser = Parser()
        do {
            try parser.setLanguage(grammar)
        } catch {
            return nil
        }
        return parser.parse(source)
    }
}

extension DefinitionKind {
    /// Ranks kinds for a name that matched more than one pattern. A Rust function
    /// in an `impl` matches as both function and method; a TypeScript
    /// `const f = () => {}` matches as both function and constant.
    fileprivate var specificity: Int {
        switch self {
        case .method: 2
        case .function: 1
        default: 0
        }
    }
}

/// A source string as UTF-16, with its line boundaries.
private struct SourceText {
    let units: [UInt16]
    /// Offset of the first code unit of each line.
    let lineStarts: [Int]
    /// False when the source is over the size or line-length limit.
    let isParseable: Bool

    init(_ source: String) {
        units = Array(source.utf16)
        var starts = [0]
        var longest = 0
        for (index, unit) in units.enumerated() where unit == 0x0A {
            longest = max(longest, index - starts[starts.count - 1])
            starts.append(index + 1)
        }
        longest = max(longest, units.count - starts[starts.count - 1])
        lineStarts = starts
        isParseable = source.utf8.count <= Syntax.maximumSourceBytes && longest <= Syntax.maximumLineLength
    }

    /// The range of a line, without its `"\n"`.
    func lineRange(_ line: Int) -> Range<Int> {
        lineStarts[line]..<(line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : units.count)
    }

    func string(in range: NSRange) -> String {
        String(decoding: units[range.location..<range.upperBound], as: UTF16.self)
    }

    /// Gives query predicates such as `#match?` the text of a node.
    var predicateContext: SwiftTreeSitter.Predicate.Context {
        SwiftTreeSitter.Predicate.Context(textProvider: { range, _ in
            range.upperBound <= units.count ? string(in: range) : nil
        })
    }
}

/// What a highlighted token is. The renderer maps each kind to a color.
public enum TokenKind: UInt8, Sendable, Hashable, CaseIterable {
    /// Text with no highlight: whitespace, unrecognized syntax, and all of a plain-text file.
    case plain
    case keyword, string, number, comment, type, function, property, variable
    case constant, `operator`, punctuation, attribute, tag

    /// Maps a capture name from a `highlights.scm` query (`function.method`,
    /// `punctuation.bracket`) to a kind. Returns `nil` for captures that carry no color.
    init?(captureName: String) {
        let parts = captureName.split(separator: ".")
        switch parts.first {
        case "keyword", "include", "conditional", "repeat", "exception",
            "import", "charset", "media", "supports", "keyframes":
            self = .keyword
        case "string":
            // JSON object keys.
            self = captureName == "string.special.key" ? .property : .string
        case "character", "escape": self = .string
        case "number", "float": self = .number
        case "boolean", "constant": self = .constant
        case "comment": self = .comment
        case "type", "constructor", "namespace", "module": self = .type
        case "function", "method": self = .function
        case "property", "field": self = .property
        case "variable":
            switch parts.dropFirst().first {
            case "builtin": self = .keyword  // self, this, super
            case "member": self = .property
            default: self = .variable
            }
        case "parameter": self = .variable
        case "operator": self = .operator
        case "punctuation", "delimiter": self = .punctuation
        case "attribute": self = .attribute
        case "tag": self = .tag
        // Code inside a string, such as `${x}`: paint plain over the string color.
        case "embedded", "none": self = .plain
        default: return nil
        }
    }

    /// Decides which capture wins when several patterns capture the same node: the
    /// higher rank wins and the later pattern breaks ties.
    ///
    /// The grammars disagree on pattern order, so order alone cannot decide. Go lists
    /// `(identifier) @variable` after its function patterns and JavaScript lists it
    /// before; JSON lists object keys before `(string) @string` and YAML after. Ranking
    /// the kinds from generic to specific reads all of them the way they intend.
    var rank: UInt8 {
        switch self {
        case .variable: 0
        case .string: 1
        case .property: 2
        case .constant: 4
        case .function: 5
        default: 3
        }
    }
}

/// A run of one line that shares a ``TokenKind``.
public struct Token: Sendable, Hashable {
    /// UTF-16 offsets within the line.
    public let range: Range<Int>
    public let kind: TokenKind

    public init(range: Range<Int>, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// An identifier that go-to-definition can start from.
public struct Identifier: Sendable, Hashable {
    public let name: String
    /// UTF-16 offsets within the line.
    public let range: Range<Int>

    public init(name: String, range: Range<Int>) {
        self.name = name
        self.range = range
    }
}

/// The identifiers of a source text, grouped by line.
public struct IdentifierMap: Sendable, Hashable {
    /// One entry per line of the source, each in column order. ``Syntax`` describes
    /// how lines are counted.
    public let lines: [[Identifier]]

    public init(lines: [[Identifier]]) {
        self.lines = lines
    }

    /// Returns the identifier covering a position, or `nil` when the position is
    /// outside every identifier or outside the text.
    ///
    /// - Parameters:
    ///   - line: Zero-based line index.
    ///   - utf16Column: Zero-based UTF-16 offset within the line.
    public func identifier(atLine line: Int, utf16Column: Int) -> Identifier? {
        guard lines.indices.contains(line) else { return nil }
        return lines[line].first { $0.range.contains(utf16Column) }
    }
}

/// What a ``Definition`` defines.
public enum DefinitionKind: String, Sendable, Hashable, CaseIterable {
    case function
    case method
    /// A class, struct, enum, interface, protocol, trait, type alias, or extension.
    case type
    case constant
    /// A variable. Also a Terraform `resource`, `data`, `variable`, `output`, or local.
    case variable
    /// A field or property of a type.
    case property
    case module

    /// Maps the suffix of a `@definition.*` capture from a `tags.scm` query.
    init?(tagName: some StringProtocol) {
        switch tagName {
        case "function", "macro": self = .function
        case "method": self = .method
        case "class", "interface", "type": self = .type
        case "constant": self = .constant
        case "variable": self = .variable
        case "property", "field": self = .property
        case "module": self = .module
        default: return nil
        }
    }
}

/// A place in a source file that defines a name.
public struct Definition: Sendable, Hashable {
    /// Zero-based line of the defined name.
    public let line: Int
    /// Zero-based UTF-16 offset of the defined name within its line.
    public let utf16Column: Int
    public let kind: DefinitionKind
    /// The full text of the line, without its line ending.
    public let lineText: String

    public init(line: Int, utf16Column: Int, kind: DefinitionKind, lineText: String) {
        self.line = line
        self.utf16Column = utf16Column
        self.kind = kind
        self.lineText = lineText
    }
}

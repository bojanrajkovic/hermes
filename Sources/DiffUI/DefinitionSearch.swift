import Foundation
import RepoKit
import SyntaxKit

/// A place that defines a name.
struct DefinitionLocation: Hashable, Sendable, Identifiable {
    /// Path relative to the source tree's root.
    let path: String
    /// Zero-based.
    let line: Int
    let kind: DefinitionKind
    let lineText: String

    var id: String { "\(path):\(line)" }
}

extension Language {
    /// Whether SyntaxKit can find definitions in the language.
    var hasDefinitions: Bool {
        switch self {
        case .json, .yaml, .toml, .html, .css, .plainText: false
        default: true
        }
    }
}

/// Finds definitions in a source tree. Nothing here touches the main actor.
enum DefinitionSearch {
    enum Outcome: Hashable, Sendable {
        case found([DefinitionLocation])
        case notFound
        /// The name appears in this many files, none in a language with definition support.
        case unsupported(files: Int)
    }

    /// The most files that are read and parsed for one lookup.
    static let candidateLimit = 40

    /// Picks the files to look for a definition in, most likely first: the
    /// file the name was clicked in, then files in its directory, then files
    /// in its language, then the rest. Files in languages without definition
    /// support are dropped.
    ///
    /// - Parameters:
    ///   - paths: Files that contain the name, in any order, possibly repeated.
    ///   - origin: The file the name was clicked in.
    static func candidates(among paths: [String], origin: String, limit: Int = candidateLimit) -> [String] {
        func directory(_ path: String) -> Substring { path[..<(path.lastIndex(of: "/") ?? path.startIndex)] }
        let language = Language(path: origin)
        var seen: Set<String> = []
        let ranked = paths.filter { seen.insert($0).inserted && Language(path: $0).hasDefinitions }
            .map { path -> (rank: Int, path: String) in
                if path == origin { return (0, path) }
                if directory(path) == directory(origin) { return (1, path) }
                return (Language(path: path) == language ? 2 : 3, path)
            }
            .sorted { ($0.rank, $0.path) < ($1.rank, $1.path) }
        return ranked.prefix(limit).map(\.path)
    }

    /// Looks for the definitions of `name`, in candidate order.
    static func find(name: String, origin: String, in tree: any SourceTree) async throws -> Outcome {
        let paths = try await tree.grep(word: name).map(\.path)
        let candidates = candidates(among: paths, origin: origin)
        guard !candidates.isEmpty else { return paths.isEmpty ? .notFound : .unsupported(files: Set(paths).count) }

        let found = await withTaskGroup(of: (Int, [DefinitionLocation]).self) { group in
            for (index, path) in candidates.enumerated() {
                group.addTask {
                    guard let source = try? await tree.readFile(path) else { return (index, []) }
                    let definitions = Syntax.definitions(named: name, in: source, language: Language(path: path))
                    return (index, definitions.map {
                        DefinitionLocation(path: path, line: $0.line, kind: $0.kind, lineText: $0.lineText)
                    })
                }
            }
            var byIndex: [Int: [DefinitionLocation]] = [:]
            for await (index, locations) in group { byIndex[index] = locations }
            return candidates.indices.flatMap { byIndex[$0] ?? [] }
        }
        return found.isEmpty ? .notFound : .found(found)
    }
}

/// A source file prepared for display.
struct CodeFile: Sendable {
    struct Line: Sendable, Identifiable {
        /// Zero-based line index.
        let id: Int
        let source: String
        let text: AttributedString
        let identifiers: [Identifier]
    }

    let lines: [Line]

    /// Highlights a whole file and finds its identifiers.
    init(source: String, path: String) {
        let language = Language(path: path)
        let tokens = Syntax.highlight(source, language: language)
        let identifiers = Syntax.identifiers(in: source, language: language).lines
        var texts = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if texts.last == "" { texts.removeLast() }
        // The highlighter may count lines differently for unusual separators. Then the file shows plain.
        let isAligned = tokens.count >= texts.count && identifiers.count >= texts.count
        lines = texts.enumerated().map { index, text in
            let spans = LineStyler.spans(length: text.utf16.count, tokens: isAligned ? tokens[index] : [], emphasis: [])
            return Line(
                id: index, source: text, text: LineStyler.attributed(text, spans: spans, emphasisColor: .clear),
                identifiers: isAligned ? identifiers[index] : []
            )
        }
    }
}

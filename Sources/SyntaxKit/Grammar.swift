import Foundation
import SwiftTreeSitter
import Synchronization
import TreeSitterBash
import TreeSitterCSS
import TreeSitterCSharp
import TreeSitterGo
import TreeSitterHCL
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML
import os

/// A `.scm` query file inside a SwiftPM resource bundle.
struct QueryFile: Sendable, Hashable {
    /// Bundle name without the `.bundle` extension. SwiftPM names it `<Package>_<Target>`.
    let bundle: String
    /// Path below the bundle's resource directory.
    let path: String

    /// A query shipped by a grammar package.
    static func grammar(_ target: String, _ file: String, package: String? = nil) -> QueryFile {
        QueryFile(bundle: "\(package ?? target)_\(target)", path: "queries/\(file).scm")
    }

    /// A query shipped in SyntaxKit's own resources.
    static func own(_ file: String) -> QueryFile {
        QueryFile(bundle: "Hermes_SyntaxKit", path: "Queries/\(file).scm")
    }
}

/// Reads query files from resource bundles found under a list of directories.
struct QueryStore: Sendable {
    /// Directories that may contain the `*.bundle` directories, searched in order.
    let roots: [URL]

    /// Searches the places SwiftPM resource bundles end up:
    /// - `Hermes.app/Contents/Resources`, where `build.sh` copies them (`Bundle.main.resourceURL`);
    /// - next to a command-line executable (`Bundle.main.bundleURL`);
    /// - next to the `.xctest` bundle under `swift test`. There `Bundle.main` is the
    ///   test runner, so the store walks up from the binary that contains this code.
    static let standard: QueryStore = {
        var roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let path = info.dli_fname {
            var url = URL(fileURLWithPath: String(cString: path))
            // X.xctest/Contents/MacOS/X -> the directory holding X.xctest.
            for _ in 0..<4 {
                url.deleteLastPathComponent()
                roots.append(url)
            }
        }
        return QueryStore(roots: roots)
    }()

    /// Returns the file's text, or `nil` when no root has the bundle or the file.
    func text(of file: QueryFile) -> String? {
        for root in roots {
            let bundle = root.appendingPathComponent("\(file.bundle).bundle")
            // The swiftbuild backend nests resources under Contents/Resources; the
            // native SwiftPM build system puts them at the bundle root.
            for directory in ["Contents/Resources", ""] {
                let url = bundle.appendingPathComponent(directory).appendingPathComponent(file.path)
                if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            }
        }
        return nil
    }
}

extension Language {
    /// The tree-sitter parser table, or `nil` for plain text.
    var treeSitter: SwiftTreeSitter.Language? {
        switch self {
        case .swift: .init(tree_sitter_swift())
        case .typescript: .init(tree_sitter_typescript())
        case .tsx: .init(tree_sitter_tsx())
        case .javascript: .init(tree_sitter_javascript())
        case .go: .init(tree_sitter_go())
        case .rust: .init(tree_sitter_rust())
        case .csharp: .init(tree_sitter_c_sharp())
        case .python: .init(tree_sitter_python())
        case .ruby: .init(tree_sitter_ruby())
        case .json: .init(tree_sitter_json())
        case .bash: .init(tree_sitter_bash())
        case .hcl: .init(tree_sitter_hcl())
        case .yaml: .init(tree_sitter_yaml())
        case .toml: .init(tree_sitter_toml())
        case .html: .init(tree_sitter_html())
        case .css: .init(tree_sitter_css())
        case .plainText: nil
        }
    }

    /// The files that make up the highlight query, concatenated in order.
    var highlightFiles: [QueryFile] {
        let javaScript = QueryFile.grammar("TreeSitterJavaScript", "highlights")
        let jsx = QueryFile.grammar("TreeSitterJavaScript", "highlights-jsx")
        return switch self {
        case .swift: [.grammar("TreeSitterSwift", "highlights")]
        // The TypeScript queries only cover what TypeScript adds to JavaScript.
        case .typescript: [.grammar("TreeSitterTypeScript", "highlights"), javaScript]
        case .tsx: [.grammar("TreeSitterTSX", "highlights", package: "TreeSitterTypeScript"), jsx, javaScript]
        case .javascript: [jsx, .grammar("TreeSitterJavaScript", "highlights-params"), javaScript]
        case .go: [.grammar("TreeSitterGo", "highlights")]
        case .rust: [.grammar("TreeSitterRust", "highlights")]
        case .csharp: [.grammar("TreeSitterCSharp", "highlights")]
        case .python: [.grammar("TreeSitterPython", "highlights")]
        case .ruby: [.grammar("TreeSitterRuby", "highlights")]
        case .json: [.grammar("TreeSitterJSON", "highlights")]
        case .bash: [.grammar("TreeSitterBash", "highlights")]
        // tree-sitter-hcl ships no queries.
        case .hcl: [.own("highlights-hcl")]
        case .yaml: [.grammar("TreeSitterYAML", "highlights")]
        case .toml: [.grammar("TreeSitterTOML", "highlights")]
        case .html: [.grammar("TreeSitterHTML", "highlights")]
        case .css: [.grammar("TreeSitterCSS", "highlights")]
        case .plainText: []
        }
    }

    /// The files that make up the definition query: the grammar's `tags.scm` where
    /// it has one, then SyntaxKit's additions. Empty for languages without definitions.
    var definitionFiles: [QueryFile] {
        let javaScript = QueryFile.grammar("TreeSitterJavaScript", "tags")
        return switch self {
        case .swift: [.grammar("TreeSitterSwift", "tags"), .own("definitions-swift")]
        case .typescript:
            [.grammar("TreeSitterTypeScript", "tags"), javaScript, .own("definitions-typescript")]
        case .tsx:
            [.grammar("TreeSitterTSX", "tags", package: "TreeSitterTypeScript"), javaScript, .own("definitions-typescript")]
        case .javascript: [javaScript, .own("definitions-javascript")]
        case .go: [.grammar("TreeSitterGo", "tags"), .own("definitions-go")]
        case .rust: [.grammar("TreeSitterRust", "tags"), .own("definitions-rust")]
        case .csharp: [.grammar("TreeSitterCSharp", "tags"), .own("definitions-csharp")]
        case .python: [.grammar("TreeSitterPython", "tags"), .own("definitions-python")]
        case .ruby: [.grammar("TreeSitterRuby", "tags"), .own("definitions-ruby")]
        case .bash: [.own("definitions-bash")]
        case .hcl: [.own("definitions-hcl")]
        case .json, .yaml, .toml, .html, .css, .plainText: []
        }
    }
}

/// A compiled highlight query and the token kind of each of its captures.
struct HighlightQuery: Sendable {
    let query: Query
    /// Indexed by capture index.
    let kinds: [TokenKind?]
}

/// A compiled definition query. A match defines something when it has both a
/// `@name` capture and a `@definition.<kind>` capture.
struct DefinitionQuery: Sendable {
    let query: Query
    /// Indexed by capture index.
    let kinds: [DefinitionKind?]
    let nameCapture: Int
}

/// Compiles and caches the per-language queries. Compiling one takes tens of
/// milliseconds, so each is built once per process.
enum Grammar {
    private static let log = Logger(subsystem: "SyntaxKit", category: "queries")

    private struct Cache {
        var highlights: [Language: HighlightQuery?] = [:]
        var definitions: [Language: DefinitionQuery?] = [:]
        var identifierSymbols: [Language: Set<Int>] = [:]
    }

    private static let cache = Mutex(Cache())

    static func highlights(for language: Language) -> HighlightQuery? {
        cache.withLock { cache in
            if let cached = cache.highlights[language] { return cached }
            let query = highlights(for: language, store: .standard)
            cache.highlights[language] = .some(query)
            return query
        }
    }

    static func definitions(for language: Language) -> DefinitionQuery? {
        cache.withLock { cache in
            if let cached = cache.definitions[language] { return cached }
            let query = definitions(for: language, store: .standard)
            cache.definitions[language] = .some(query)
            return query
        }
    }

    /// The node symbols that are identifiers in `language`: every leaf node type
    /// named `identifier` or `*_identifier`, plus Bash variable and command names and
    /// Ruby constants and instance variables.
    static func identifierSymbols(for language: Language) -> Set<Int> {
        cache.withLock { cache in
            if let cached = cache.identifierSymbols[language] { return cached }
            var symbols = Set<Int>()
            if let grammar = language.treeSitter, !language.definitionFiles.isEmpty {
                for symbol in 0..<grammar.symbolCount {
                    guard let name = grammar.symbolName(for: symbol) else { continue }
                    let isIdentifier = name == "identifier"
                        || (name.hasSuffix("_identifier") && name != "heredoc_identifier")
                        || (language == .bash && (name == "variable_name" || name == "word"))
                        || (language == .ruby && (name == "constant" || name == "instance_variable"))
                    if isIdentifier { symbols.insert(symbol) }
                }
            }
            cache.identifierSymbols[language] = symbols
            return symbols
        }
    }

    static func highlights(for language: Language, store: QueryStore) -> HighlightQuery? {
        guard let query = compile(language.highlightFiles, for: language, store: store) else { return nil }
        let kinds = (0..<query.captureCount).map { index in
            query.captureName(for: index).flatMap(TokenKind.init(captureName:))
        }
        return HighlightQuery(query: query, kinds: kinds)
    }

    static func definitions(for language: Language, store: QueryStore) -> DefinitionQuery? {
        guard let query = compile(language.definitionFiles, for: language, store: store) else { return nil }
        let names = (0..<query.captureCount).map { query.captureName(for: $0) ?? "" }
        guard let nameCapture = names.firstIndex(of: "name") else { return nil }
        let kinds = names.map { name in
            name.hasPrefix("definition.") ? DefinitionKind(tagName: name.dropFirst("definition.".count)) : nil
        }
        return DefinitionQuery(query: query, kinds: kinds, nameCapture: nameCapture)
    }

    /// Concatenates `files` and compiles them for `language`. Returns `nil`, and logs
    /// why, when a file cannot be found or the query does not compile.
    private static func compile(_ files: [QueryFile], for language: Language, store: QueryStore) -> Query? {
        guard let grammar = language.treeSitter, !files.isEmpty else { return nil }
        var source = ""
        for file in files {
            guard let text = store.text(of: file) else {
                log.error("Missing query \(file.bundle).bundle/\(file.path) for \(language.rawValue). Searched \(store.roots.map(\.path))")
                return nil
            }
            source += text + "\n"
        }
        do {
            return try Query(language: grammar, data: Data(source.utf8))
        } catch {
            log.error("Query for \(language.rawValue) does not compile: \(String(describing: error))")
            return nil
        }
    }
}

import Foundation
import RepoKit
import SyntaxKit

/// One line in a source tree that uses a name.
struct ReferenceLocation: Hashable, Sendable, Identifiable {
    /// The file's path, relative to the source tree's root.
    let path: String
    /// The zero-based line index.
    let line: Int
    let lineText: String

    var id: String { "\(path):\(line)" }
}

/// Finds the lines in a source tree that use a name. All of its work runs off the main actor.
///
/// `git grep` finds the lines that contain the name as a whole word. In a file
/// that tree-sitter can parse, the search keeps only the lines where the name
/// is an identifier, so it leaves out comments and strings. In other files,
/// such as Markdown or YAML, it keeps every line that grep found.
enum ReferenceSearch {
    struct Found: Hashable, Sendable {
        /// The matching lines, sorted by file in `DefinitionSearch.ranked` order, then by line.
        let locations: [ReferenceLocation]
        /// True when grep stopped at its match limit or more files matched than the search read.
        let isTruncated: Bool
    }

    /// The maximum number of files that one search reads and parses.
    static let fileLimit = 100

    static func find(name: String, origin: String, in tree: any SourceTree, fileLimit: Int = fileLimit) async throws -> Found {
        let matches = try await tree.grep(word: name)
        // Treat exactly the limit as capped, because grep doesn't report whether more matches remained.
        let isCapped = matches.count >= SourceTreeLimits.matches
        var byPath = Dictionary(grouping: matches, by: \.path)
        // Grep returns matches in path order, so the cap can drop the clicked file's matches. Then read that file whole.
        if isCapped, byPath[origin] == nil, let source = try? await tree.readFile(origin),
           let lines = Syntax.references(named: name, in: source, language: Language(path: origin)), !lines.isEmpty
        {
            let texts = source.components(separatedBy: "\n")
            byPath[origin] = lines.map {
                GrepMatch(path: origin, line: $0 + 1, text: String(texts[$0].prefix(SourceTreeLimits.lineLength)))
            }
        }
        let paths = DefinitionSearch.ranked(Array(byPath.keys), origin: origin)
        let read = Array(paths.prefix(fileLimit))

        let found = await withTaskGroup(of: (Int, [ReferenceLocation]).self) { group in
            for (index, path) in read.enumerated() {
                let matches = byPath[path] ?? []
                group.addTask {
                    // Keep every grep match in a file that can't be read or parsed.
                    let source = try? await tree.readFile(path)
                    let lines = source.flatMap { Syntax.references(named: name, in: $0, language: Language(path: path)) }
                    return (index, confirmed(matches, lines: lines.map(Set.init)))
                }
            }
            var byIndex: [Int: [ReferenceLocation]] = [:]
            for await (index, locations) in group { byIndex[index] = locations }
            return read.indices.flatMap { byIndex[$0] ?? [] }
        }
        return Found(locations: found, isTruncated: isCapped || paths.count > read.count)
    }

    /// Returns one file's grep matches that are on `lines`, sorted by line.
    ///
    /// - Parameter lines: Zero-based lines that use the name, or `nil` to keep every match.
    static func confirmed(_ matches: [GrepMatch], lines: Set<Int>?) -> [ReferenceLocation] {
        matches
            .map { ReferenceLocation(path: $0.path, line: $0.line - 1, lineText: $0.text.trimmingCharacters(in: ["\r"])) }
            .filter { lines?.contains($0.line) ?? true }
            .sorted { $0.line < $1.line }
    }
}

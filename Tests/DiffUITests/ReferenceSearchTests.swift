import Foundation
import RepoKit
import Testing
@testable import DiffUI

/// Serves files from a dictionary. `grep` matches whole words the way `git grep -w` does.
struct MemoryTree: SourceTree {
    var files: [String: String]

    func readFile(_ path: String) async throws -> String {
        guard let source = files[path] else { throw CocoaError(.fileNoSuchFile) }
        return source
    }

    func listFiles() async throws -> [String] { files.keys.sorted() }

    func grep(word: String) async throws -> [GrepMatch] {
        let pattern = try Regex("\\b\(NSRegularExpression.escapedPattern(for: word))\\b")
        let matches = files.keys.sorted().flatMap { path in
            files[path]!.components(separatedBy: "\n").enumerated().compactMap { index, text in
                text.contains(pattern) ? GrepMatch(path: path, line: index + 1, text: text) : nil
            }
        }
        return Array(matches.prefix(SourceTreeLimits.matches))
    }
}

struct ReferenceSearchTests {
    @Test func codeFilesKeepOnlyLinesThatUseTheName() async throws {
        let tree = MemoryTree(files: [
            "Sources/Cart.swift": "// total is cached\nlet total = 1\nprint(\"total\")\nprint(total)",
        ])
        let found = try await ReferenceSearch.find(name: "total", origin: "Sources/Cart.swift", in: tree)
        #expect(found.locations.map(\.line) == [1, 3])
        #expect(found.locations.map(\.lineText) == ["let total = 1", "print(total)"])
        #expect(!found.isTruncated)
    }

    @Test func filesWithoutAGrammarKeepEveryTextMatch() async throws {
        let tree = MemoryTree(files: ["README.md": "Call total.\n\nThe total is cached."])
        let found = try await ReferenceSearch.find(name: "total", origin: "a.swift", in: tree)
        #expect(found.locations.map(\.id) == ["README.md:0", "README.md:2"])
    }

    @Test func theClickedFileComesFirst() async throws {
        let tree = MemoryTree(files: [
            "a/first.swift": "total()", "b/origin.swift": "total()", "b/sibling.swift": "total()", "c/doc.md": "total",
        ])
        let found = try await ReferenceSearch.find(name: "total", origin: "b/origin.swift", in: tree)
        #expect(found.locations.map(\.path) == ["b/origin.swift", "b/sibling.swift", "a/first.swift", "c/doc.md"])
    }

    @Test func aSearchPastTheFileLimitIsTruncated() async throws {
        let files = Dictionary(uniqueKeysWithValues: (0..<5).map { ("f\($0).swift", "total()") })
        let found = try await ReferenceSearch.find(name: "total", origin: "f0.swift", in: MemoryTree(files: files), fileLimit: 3)
        #expect(found.locations.count == 3)
        #expect(found.isTruncated)
    }

    @Test func theClickedFileIsReadWhenGrepStopsBeforeIt() async throws {
        var files = Dictionary(uniqueKeysWithValues: (0..<SourceTreeLimits.matches).map { (String(format: "a%03d.swift", $0), "total()") })
        files["z.swift"] = "// total\nlet total = 1"
        let found = try await ReferenceSearch.find(name: "total", origin: "z.swift", in: MemoryTree(files: files))
        #expect(found.locations.first?.id == "z.swift:1")
        #expect(found.isTruncated)
    }

    @Test func carriageReturnsAreTrimmed() async throws {
        let tree = MemoryTree(files: ["a.swift": "let total = 1\r\nprint(total)\r\n"])
        let found = try await ReferenceSearch.find(name: "total", origin: "a.swift", in: tree)
        #expect(found.locations.map(\.lineText) == ["let total = 1", "print(total)"])
    }

    @Test func aNameUsedOnlyInCommentsHasNoReferences() async throws {
        let tree = MemoryTree(files: ["a.swift": "// total\nlet x = 1"])
        #expect(try await ReferenceSearch.find(name: "total", origin: "a.swift", in: tree).locations.isEmpty)
    }
}

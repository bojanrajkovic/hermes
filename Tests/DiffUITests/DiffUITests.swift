import DiffKit
import Foundation
import GitHubKit
@testable import RepoKit
import SyntaxKit
import Testing
@testable import DiffUI

private let sample = """
    diff --git a/Sources/App/Greeter.swift b/Sources/App/Greeter.swift
    index 1111111..2222222 100644
    --- a/Sources/App/Greeter.swift
    +++ b/Sources/App/Greeter.swift
    @@ -3,5 +3,6 @@ struct Greeter {
         let name: String

    -    func greet() -> String { "Hello, \\(name)" }
    +    func greet() -> String { "Hello, \\(name)!" }
    +    func part() -> String { "Bye" }

     }
    @@ -20,3 +21,3 @@ extension Greeter {
     // a
    -// b
    +// c
     // d
    diff --git a/Sources/App/Old.swift b/Sources/App/New.swift
    similarity index 100%
    rename from Sources/App/Old.swift
    rename to Sources/App/New.swift
    diff --git a/logo.png b/logo.png
    index 1111111..2222222 100644
    Binary files a/logo.png and b/logo.png differ

    """

/// A 30-line file whose lines 3-8 and 21-23 match the first file of `sample`.
private let greeterText = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"

private func plain(_ line: DiffLine) -> AttributedString { AttributedString(line.text) }

private func lineNumbers(_ rows: [DiffRow]) -> [String] {
    rows.map { row in
        switch row.kind {
        case .unified(let cell): "\(cell.line.oldNumber.map(String.init) ?? "-"):\(cell.line.newNumber.map(String.init) ?? "-")"
        case .split(let old, let new):
            "\(old?.line.oldNumber.map(String.init) ?? "-")|\(new?.line.newNumber.map(String.init) ?? "-")"
        case .hunk(let header): "@\(header.region)h\(header.hidden)"
        case .notice: "notice"
        }
    }
}

struct RowTests {
    private let files = Diff(parsing: sample).files

    @Test func unifiedRowsFollowTheHunks() {
        let rows = diffRows(file: files[0], expansion: FileExpansion(), layout: .unified, text: plain)
        #expect(lineNumbers(rows) == [
            "@0h0", "3:3", "4:4", "5:-", "-:5", "-:6", "6:7", "7:8",
            "@1h0", "20:21", "21:-", "-:22", "22:23",
        ])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func splitRowsPairDeletionsWithAdditionsAndReuseUnifiedIDs() {
        let unified = diffRows(file: files[0], expansion: FileExpansion(), layout: .unified, text: plain)
        let split = diffRows(file: files[0], expansion: FileExpansion(), layout: .split, text: plain)
        #expect(lineNumbers(split) == [
            "@0h0", "3|3", "4|4", "5|5", "-|6", "6|7", "7|8",
            "@1h0", "20|21", "21|22", "22|23",
        ])
        #expect(Set(split.map(\.id)).isSubset(of: Set(unified.map(\.id))))
    }

    @Test func expansionRevealsLinesOnTheSideThatWasAsked() throws {
        var expansion = FileExpansion(regions: files[0].hiddenRegions(newText: greeterText))
        #expect([0, 1, 2].map(expansion.hidden) == [2, 12, 7])

        expansion.expand(region: 1, .down(2))
        expansion.expand(region: 1, .up(3))
        var rows = diffRows(file: files[0], expansion: expansion, layout: .unified, text: plain)
        #expect(Array(lineNumbers(rows)[7...15]) == [
            "7:8", "8:9", "9:10", "@1h7", "17:18", "18:19", "19:20", "20:21", "21:-",
        ])
        #expect(lineNumbers(rows).last == "@2h7")

        // A fully revealed region loses its header, so the hunks read as one.
        expansion.expand(region: 1, .all)
        expansion.expand(region: 2, .all)
        rows = diffRows(file: files[0], expansion: expansion, layout: .unified, text: plain)
        #expect(!lineNumbers(rows).contains { $0.hasPrefix("@1") || $0.hasPrefix("@2") })
        #expect(lineNumbers(rows).last == "29:30")
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func filesWithoutLinesGetANotice() {
        func notices(_ file: FileDiff) -> [FileNotice] {
            diffRows(file: file, expansion: FileExpansion(), layout: .unified, text: plain).compactMap {
                if case .notice(let notice) = $0.kind { notice } else { nil }
            }
        }
        #expect(notices(files[1]) == [.renamed(from: "Sources/App/Old.swift", to: "Sources/App/New.swift")])
        #expect(notices(files[2]) == [.binary])

        let mode = Diff(parsing: "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n").files[0]
        #expect(notices(mode) == [.modeChanged(old: "100644", new: "100755")])
    }

    @Test func aLargeDiffWaitsForTheUser() {
        let lines = (1...(largeFileLineLimit + 1)).map { "+line \($0)" }.joined(separator: "\n")
        let text = "diff --git a/big.txt b/big.txt\nnew file mode 100644\n--- /dev/null\n+++ b/big.txt\n@@ -0,0 +1,\(largeFileLineLimit + 1) @@\n\(lines)\n"
        let file = Diff(parsing: text).files[0]
        let held = diffRows(file: file, expansion: FileExpansion(), layout: .unified, text: plain)
        #expect(held.map(\.kind) == [.notice(.large(lines: largeFileLineLimit + 1))])
        let shown = diffRows(file: file, expansion: FileExpansion(), layout: .unified, showsLargeDiff: true, text: plain)
        #expect(shown.count == largeFileLineLimit + 2)
    }
}

struct StylerTests {
    @Test func spansCoverTheLineAndSplitOnKindAndEmphasis() {
        let spans = LineStyler.spans(
            length: 10, tokens: [Token(range: 0..<3, kind: .keyword), Token(range: 6..<99, kind: .string)],
            emphasis: [2..<7]
        )
        #expect(spans == [
            StyledSpan(range: 0..<2, kind: .keyword, isEmphasized: false),
            StyledSpan(range: 2..<3, kind: .keyword, isEmphasized: true),
            StyledSpan(range: 3..<6, kind: .plain, isEmphasized: true),
            StyledSpan(range: 6..<7, kind: .string, isEmphasized: true),
            StyledSpan(range: 7..<10, kind: .string, isEmphasized: false),
        ])
        #expect(LineStyler.spans(length: 0, tokens: [], emphasis: []).isEmpty)
    }

    @Test func styledTextKeepsTheLineAndExpandsTabs() {
        let text = "\tlet 🙂 = 1"
        let spans = LineStyler.spans(length: text.utf16.count, tokens: [Token(range: 1..<4, kind: .keyword)], emphasis: [5..<7])
        let styled = LineStyler.attributed(text, spans: spans, emphasisColor: .red)
        #expect(String(styled.characters) == "    let 🙂 = 1")
        #expect(styled.runs.contains { $0.backgroundColor == .red && String(styled[$0.range].characters) == "🙂" })
        #expect(String(LineStyler.attributed("", spans: [], emphasisColor: .red).characters) == " ")
    }

    @Test func aFileIsStyledLineByLineWithIntralineEmphasis() throws {
        let file = Diff(parsing: sample).files[0]
        let styled = LineStyler.style(file)
        #expect(styled.count == file.hunks.reduce(0) { $0 + $1.lines.count })

        let addition = try #require(styled[.addition(new: 5)])
        let emphasized = addition.runs.filter { $0.backgroundColor != nil }.map { String(addition[$0.range].characters) }
        #expect(emphasized == ["!"])
        // Swift keywords are colored.
        #expect(addition.runs.contains { $0.foregroundColor != nil && String(addition[$0.range].characters) == "func" })
    }
}

struct FileTreeTests {
    @Test func directoriesNestInDiffOrderAndSingleChildChainsJoin() {
        let paths = ["README.md", "Sources/App/A.swift", "Sources/App/Sub/B.swift", "Sources/Lib/C.swift", "docs/guide/intro.md"]
        let tree = fileTree(paths.map { ($0, $0) })

        func outline(_ nodes: [FileTreeNode], depth: Int = 0) -> [String] {
            nodes.flatMap { [String(repeating: " ", count: depth) + $0.name] + outline($0.children, depth: depth + 1) }
        }
        #expect(outline(tree) == [
            "README.md", "Sources", " App", "  A.swift", "  Sub", "   B.swift", " Lib", "  C.swift",
            "docs/guide", " intro.md",
        ])
        #expect(tree[2].id == "docs/guide")
    }

    @Test func aLockFileNestsUnderItsManifestInTheSameDirectory() {
        let paths = ["pnpm-lock.yaml", "package.json", "web/Cargo.lock", "web/package.json", "api/go.sum", "api/go.mod", "api/main.go"]
        let tree = fileTree(paths.map { ($0, $0) })

        func outline(_ nodes: [FileTreeNode], depth: Int = 0) -> [String] {
            nodes.flatMap { [String(repeating: " ", count: depth) + $0.name] + outline($0.children, depth: depth + 1) }
        }
        // Cargo.lock stays put: its manifest did not change in that directory.
        #expect(outline(tree) == [
            "package.json", " pnpm-lock.yaml", "web", " Cargo.lock", " package.json", "api", " go.mod", "  go.sum", " main.go",
        ])
    }

    @Test func collapsedNodesHideTheirChildren() {
        let tree = fileTree(["a/x.ts", "a/b/y.ts", "package.json", "yarn.lock"].map { ($0, $0) })
        let rows = visibleRows(tree, collapsed: ["a/b", "package.json"])
        #expect(rows.map { "\($0.depth) \($0.node.name)" } == ["0 a", "1 x.ts", "1 b", "0 package.json"])
    }

    @Test func filterMatchesAnyPartOfThePath() {
        #expect(pathMatches("Sources/App/A.swift", filter: " app "))
        #expect(pathMatches("Sources/App/A.swift", filter: ""))
        #expect(!pathMatches("Sources/App/A.swift", filter: "lib"))
    }
}

@MainActor
struct ModelTests {
    private func model() -> DiffModel {
        DiffModel(
            source: .workingTree(directory: URL(filePath: "/nonexistent"), baseRef: "main"),
            client: GitHubClient(token: { "" }), repoCache: RepoCache(root: URL(filePath: "/nonexistent"))
        )
    }

    @Test func markingTheCurrentFileViewedMovesToTheNextFile() async {
        let model = model()
        await model.show(text: sample)
        let (first, second) = (model.files[0], model.files[1])
        model.scroll.scroll(to: first.id)

        model.setViewed(true, for: first)
        #expect(first.isCollapsed)
        #expect(model.scroll.request?.row == RowID(file: second.id, item: .header))

        // A file that is not the current one collapses where it is.
        let serial = model.scroll.request?.serial
        model.setViewed(true, for: model.files[2])
        #expect(model.scroll.request?.serial == serial)
        // Unmarking does not move the list.
        model.setViewed(false, for: second)
        #expect(model.scroll.request?.serial == serial)
    }

    @Test func aReloadKeepsUnchangedFilesAndTheirState() async {
        let model = model()
        await model.show(text: sample)
        let (greeter, renamed) = (model.files[0], model.files[1])
        greeter.setViewed(true)
        renamed.isCollapsed = true
        #expect(model.updatedAt == nil)

        // The first file changes, the second stays, the third goes away, and a new one arrives.
        let changed = sample
            .replacingOccurrences(of: "// c", with: "// e")
            .replacingOccurrences(of: "logo.png", with: "icon.png")
        await model.show(text: changed)

        #expect(model.files.map(\.id) == ["Sources/App/Greeter.swift", "Sources/App/New.swift", "icon.png"])
        #expect(model.files[0] === greeter)
        #expect(model.files[1] === renamed)
        // The changed file has something new to read. The unchanged one stays as it was.
        #expect(!greeter.isViewed && !greeter.isCollapsed && renamed.isCollapsed)
        #expect(lineNumbers(greeter.rows).count == 13)
        #expect(model.updatedAt != nil)
        #expect((model.additions, model.deletions) == (3, 2))
    }

    @Test func aReloadThatChangesRowsAboveScrollsBackToTheRowOnScreen() async throws {
        let model = model()
        await model.show(text: sample)
        let greeter = model.files[0].id
        // The second hunk of the first file is on screen, under the file's pinned header.
        let onScreen = model.files[0].rows.suffix(4).map(\.id) + [RowID(file: greeter, item: .header)]
        model.visibleRowsChanged(onScreen.shuffled())

        // A change in a file further down leaves the list alone.
        await model.show(text: sample.replacingOccurrences(of: "logo.png", with: "icon.png"))
        #expect(model.scroll.request == nil)

        // A change above the rows on screen brings the top one back.
        await model.show(text: sample.replacingOccurrences(of: "\"Bye\"", with: "\"Ciao\""))
        #expect(model.scroll.request?.row == RowID(file: greeter, item: .line(.context(old: 20, new: 21))))

        // Switching layout does too. The deletion on screen has no row of its own in the split layout.
        model.visibleRowsChanged(Array(model.files[0].rows.suffix(3).map(\.id)))
        model.layout = .split
        #expect(model.scroll.request?.row == RowID(file: greeter, item: .line(.addition(new: 22))))
    }

    @Test func showingTheSameTextIsNotAnUpdate() async {
        let model = model()
        await model.show(text: sample)
        let rows = model.files[0].rows
        await model.show(text: sample)
        #expect(model.updatedAt == nil)
        #expect(model.files[0].rows == rows)
    }

    @Test func highlightingArrivesInTheBackgroundAndLayoutRebuildsRows() async {
        let model = model()
        await model.show(text: sample)
        await model.background?.value
        #expect(model.files[0].isStyled)

        model.layout = .split
        #expect(model.files[0].rows.contains { if case .split = $0.kind { true } else { false } })
    }

    @Test func nextAndPreviousFileStopAtTheEnds() async {
        let model = model()
        await model.show(text: sample)
        model.selectFile(offset: -1)
        #expect(model.currentFile === model.files[0])
        model.selectFile(offset: 1)
        model.selectFile(offset: 1)
        model.selectFile(offset: 1)
        #expect(model.currentFile === model.files[2])
        model.toggleCurrentFileViewed()
        #expect(model.files[2].isViewed && model.viewedCount == 1)
    }

    @Test func aFileThatWasScrolledToStaysCurrentWhileItIsOnScreen() async {
        let model = model()
        await model.show(text: sample)
        let headers = model.files.map { RowID(file: $0.id, item: .header) }

        // The last file is too short to reach the top, so an earlier file is still the first on screen.
        model.selectFile(offset: 2)
        model.visibleRowsChanged(headers)
        #expect(model.currentFile === model.files[2])

        // Once it scrolls out of view, the first file on screen is current again.
        model.visibleRowsChanged([headers[0], headers[1]])
        #expect(model.currentFile === model.files[0])
        model.visibleRowsChanged(headers)
        #expect(model.currentFile === model.files[0])
    }

    private let guide = """
        diff --git a/guide.md b/guide.md
        index 1111111..2222222 100644
        --- a/guide.md
        +++ b/guide.md
        @@ -1,2 +1,2 @@
         # Guide
        -old
        +new

        """

    @Test func aFailedMarkdownLoadIsTriedAgain() async {
        let model = model()
        await model.show(text: guide)
        let file = model.files[0]
        file.markdown = .failed("offline")
        model.setRendered(true, for: file)
        #expect(file.markdown == .loading)
    }

    @Test func anUnreadableSourceTreeIsReportedAndReadAgainOnTheNextReload() async throws {
        // Listing the worktrees of a checkout that does not exist fails.
        let checkout = Checkout(repo: RepoID(owner: "acme", name: "app"), directory: URL(filePath: "/nonexistent"))
        let model = DiffModel(
            source: .localBranch(checkout: checkout, branch: LocalStack.Branch(name: "guide", parent: "main")),
            client: GitHubClient(token: { "" }), repoCache: RepoCache(root: URL(filePath: "/nonexistent"))
        )
        await model.show(text: guide)
        await model.background?.value
        #expect(model.refreshError != nil)

        // The same diff again reads the tree again, and a rendered file shows the error.
        let file = model.files[0]
        file.showsRendered = true
        await model.show(text: guide)
        await model.background?.value
        for _ in 0..<200 where file.markdown == .loading { try await Task.sleep(for: .milliseconds(10)) }
        guard case .failed = file.markdown else {
            Issue.record("markdown is \(String(describing: file.markdown))")
            return
        }
    }

    @Test func gitHubLinksPointAtTheFileInThePullRequest() {
        let url = DiffLoader.gitHubURL(pullRequest: URL(string: "https://github.com/o/r/pull/7")!, path: "README.md")
        #expect(url?.absoluteString == "https://github.com/o/r/pull/7/files#diff-b335630551682c19a781afebcf4d07bf978fb1f8ac04c6bf87428ed5106870f5")
    }
}

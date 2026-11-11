import Foundation
import JavaScriptCore
import Testing
@testable import MarkdownUI

/// Runs `mdcore.js` and the vendored parser in JavaScriptCore, without a web view.
struct MarkdownCore {
    let context = JSContext()!

    init() throws {
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript exception: \(exception?.toString() ?? "unknown")")
        }
        let files = [
            "vendor/markdown-it.min.js", "vendor/markdown-it-task-lists.min.js", "vendor/markdown-it-footnote.min.js",
            "vendor/markdown-it-anchor.min.js", "vendor/markdown-it-emoji.min.js", "vendor/highlight.min.js", "mdcore.js",
        ]
        for file in files {
            let url = BundleSchemeHandler.root.appendingPathComponent(file)
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
        }
        context.evaluateScript("""
            var md = MDCore.createMarkdown({
              markdownit: markdownit, taskLists: markdownitTaskLists, footnote: markdownitFootnote,
              anchor: markdownItAnchor, emoji: markdownitEmoji, hljs: hljs
            });
            """)
    }

    func render(_ markdown: String) -> String {
        context.objectForKeyedSubscript("md").invokeMethod("render", withArguments: [markdown]).toString()
    }

    func diff(old: String, new: String) -> String {
        let md = context.objectForKeyedSubscript("md")!
        return context.objectForKeyedSubscript("MDCore").invokeMethod("renderDiff", withArguments: [md, old, new]).toString()
    }

    func htmlDiff(_ old: String, _ new: String) -> String {
        context.objectForKeyedSubscript("MDCore").invokeMethod("htmlDiff", withArguments: [old, new]).toString()
    }

    /// Returns "unit:count:line" for each badge.
    func assignMarkers(units: [ClosedRange<Int>], markers: [Int: Int]) -> [String] {
        let units = units.map { ["start": $0.lowerBound, "end": $0.upperBound] }
        let markers = Dictionary(uniqueKeysWithValues: markers.map { (String($0.key), $0.value) })
        let result = context.objectForKeyedSubscript("MDCore").invokeMethod("assignMarkers", withArguments: [units, markers])!
        return (result.toArray() as? [[String: Int]] ?? []).map { "\($0["unit"]!):\($0["count"]!):\($0["line"]!)" }
    }
}

@Suite struct RenderingTests {
    let core = try! MarkdownCore()

    @Test func rendersGitHubAlerts() {
        let html = core.render("> [!WARNING]\n> Mind the **gap**.\n\n> [!NOTE] text on the marker line is a plain quote\n\n> [!tip]\n> Any case works.")
        #expect(html.contains(#"<blockquote class="markdown-alert markdown-alert-warning">"#))
        #expect(html.contains(#"<p class="markdown-alert-title">Warning</p>"#))
        #expect(html.contains("<p>Mind the <strong>gap</strong>.</p>"))
        #expect(!html.contains("[!WARNING]"))
        #expect(html.contains("<p>[!NOTE] text on the marker line"))
        #expect(html.contains(#"<blockquote class="markdown-alert markdown-alert-tip">"#))
        #expect(html.contains(#"<p class="markdown-alert-title">Tip</p>"#))
    }

    /// A README's own table of contents links to ids made the way github.com makes them.
    @Test func headingIdsMatchGitHub() {
        let html = core.render("## What's new? (v2.0) & more_stuff\n\n## Dup\n\n## Dup\n\n## Ünï `code`")
        #expect(html.contains(#"<h2 id="whats-new-v20--more_stuff""#))
        #expect(html.contains(#"<h2 id="dup""#))
        #expect(html.contains(#"<h2 id="dup-1""#))
        #expect(html.contains(#"<h2 id="ünï-code""#))
    }

    @Test func rendersGitHubFlavoredSyntax() {
        let html = core.render("""
            ## Set up

            - [x] done
            - [ ] todo

            | a | b |
            |---|--:|
            | 1 | 2 |

            ~~gone~~ :rocket: https://example.com[^1]

            [^1]: A note.
            """)
        #expect(html.contains(#"<h2 id="set-up""#))
        #expect(html.contains("task-list-item"))
        #expect(html.contains(#"type="checkbox""#))
        #expect(html.contains("<table>"))
        #expect(html.contains("<s>gone</s>"))
        #expect(html.contains("🚀"))
        #expect(html.contains(#"<a href="https://example.com">"#))
        #expect(html.contains("footnote-ref"))
    }

    @Test func highlightsCodeAndLeavesMermaidForThePage() {
        let html = core.render("```swift\nlet x = 1\n```\n\n```mermaid\ngraph TD\n  A --> B\n```")
        #expect(html.contains(#"<span class="hljs-keyword">let</span>"#))
        #expect(html.contains("<pre class=\"mermaid-src\">graph TD\n  A --&gt; B\n</pre>"))
    }
}

@Suite struct DiffTests {
    let core = try! MarkdownCore()

    static let old = """
        # Title

        Intro paragraph stays.

        Old paragraph that goes away entirely.

        - one
        - two
        - three

        The quick brown fox jumps over the lazy dog.
        """

    static let new = """
        # Title

        Intro paragraph stays.

        - one
        - two changed
        - three
        - four

        The quick red fox jumps over the lazy dog.

        Brand new paragraph.
        """

    @Test func marksBlocksWithStatusAndNewLineRange() {
        let html = core.diff(old: Self.old, new: Self.new)

        #expect(html.contains(#"<div class="md-block md-unchanged" data-start="1" data-end="1">"# + "\n<h1"))
        #expect(html.contains(#"<div class="md-block md-unchanged" data-start="3" data-end="3">"#))
        #expect(html.contains(#"<div class="md-block md-removed">"# + "\n<p>Old paragraph that goes away entirely.</p>"))
        #expect(html.contains(#"<div class="md-block md-modified" data-start="10" data-end="10">"#))
        #expect(html.contains("The quick <del>brown</del><ins>red</ins> fox"))
        #expect(html.contains(#"<div class="md-block md-added" data-start="12" data-end="12">"# + "\n<p>Brand new paragraph.</p>"))
    }

    @Test func diffsListsItemByItem() {
        let html = core.diff(old: Self.old, new: Self.new)

        #expect(html.contains(#"<li class="md-unchanged" data-start="5" data-end="5">one</li>"#))
        #expect(html.contains(#"<li class="md-modified" data-start="6" data-end="6">"# + "\ntwo<ins> changed</ins></li>"))
        #expect(html.contains(#"<li class="md-added" data-start="8" data-end="8">four</li>"#))
        #expect(!html.contains("md-block md-added\" data-start=\"5\""))
    }

    @Test func showsRemovedBlocksWhereTheyWere() throws {
        let html = core.diff(old: "First.\n\nSecond.\n\nThird.", new: "First.\n\nThird.")
        let first = try #require(html.range(of: "First."))
        let removed = try #require(html.range(of: #"<div class="md-block md-removed">"#))
        let third = try #require(html.range(of: "Third."))
        #expect(first.upperBound < removed.lowerBound && removed.upperBound < third.lowerBound)
    }

    @Test func removedListItemStaysInTheList() {
        let html = core.diff(old: "- a\n- b\n- c", new: "- a\n- c")
        #expect(html.contains(#"<li class="md-unchanged" data-start="1" data-end="1">a</li>"# + "\n" + #"<li class="md-removed">b</li>"#))
    }

    @Test func unrelatedReplacementIsRemovedPlusAdded() {
        let html = core.diff(old: "Apples and oranges are fruit.", new: "Deploy with the release script.")
        #expect(html.contains("md-block md-removed"))
        #expect(html.contains("md-block md-added"))
        #expect(!html.contains("<ins>"))
    }

    @Test func changedMermaidBlockKeepsBothDiagrams() {
        let html = core.diff(old: "```mermaid\ngraph TD\n  A --> B\n```", new: "```mermaid\ngraph TD\n  A --> C\n```")
        #expect(html.contains(#"<div class="md-block md-modified" data-start="1" data-end="4">"#))
        #expect(html.contains("<div class=\"md-removed\"><pre class=\"mermaid-src\">graph TD\n  A --&gt; B\n</pre>"))
        #expect(html.contains("<div class=\"md-added\"><pre class=\"mermaid-src\">graph TD\n  A --&gt; C\n</pre>"))
    }

    @Test func multiLineBlockRangeExcludesTrailingBlankLines() {
        let html = core.diff(old: "", new: "- item\n  continues\n\n\nPara one\nstill para\n")
        #expect(html.contains(#"<li class="md-added" data-start="1" data-end="2">"#))
        #expect(html.contains(#"<div class="md-block md-added" data-start="5" data-end="6">"#))
    }

    @Test func sourceChangesThatRenderTheSameAreUnchanged() {
        let rewrapped = core.diff(old: "one two\nthree four five", new: "one\ntwo three\nfour five")
        #expect(rewrapped.contains(#"<div class="md-block md-unchanged" data-start="1" data-end="3">"#))
        #expect(!rewrapped.contains("<ins>") && !rewrapped.contains("<del>"))

        let renumbered = core.diff(old: "1. a\n2. b\n3. c", new: "1. a\n2. c")
        #expect(renumbered.contains(#"<li class="md-removed">b</li>"#))
        #expect(renumbered.contains(#"<li class="md-unchanged" data-start="2" data-end="2">c</li>"#))
    }

    @Test func rewrappedParagraphMarksOnlyTheChangedWords() {
        let html = core.diff(old: "one two\nthree four five", new: "one\ntwo three\nfour six")
        #expect(html.contains("<p>one\ntwo three\nfour <del>five</del><ins>six</ins></p>"))
    }

    @Test func joinedLinesInACodeBlockAreAChange() {
        let html = core.diff(old: "```\na\nb\n```", new: "```\na b\n```")
        #expect(html.contains("md-block md-modified"))
        #expect(html.contains("<del>") && html.contains("<ins>"))
    }

    /// Pairing compares every removed block with every added one, so the
    /// comparison must be cheap. The time limit is the check.
    @Test(.timeLimit(.minutes(1))) func rewritingALongDocumentStaysFast() {
        func document(_ prefix: String) -> String {
            (0..<400).map { block in (0..<60).map { "\(prefix)\(block)x\($0)" }.joined(separator: " ") }.joined(separator: "\n\n")
        }
        let html = core.diff(old: document("a"), new: document("b"))
        #expect(html.components(separatedBy: "md-block md-added").count == 401)
    }

    @Test func marksGeneratedElementsWhenAskedTo() {
        let md = core.context.objectForKeyedSubscript("md")!
        let html = core.context.objectForKeyedSubscript("MDCore")
            .invokeMethod("renderDiff", withArguments: [md, "Gone.\n\n- a", "- a\n- b\n\nNew.", "k9"]).toString()!
        #expect(html.contains(#"<div class="md-block md-removed" data-md="k9">"#))
        #expect(html.contains(#"<div class="md-block md-added" data-start="4" data-end="4" data-md="k9">"#))
        #expect(html.contains(#"<li class="md-added" data-md="k9" data-start="2" data-end="2">b</li>"#))
    }

    @Test func rawHTMLThatSpansBlocksKeepsItsContentInside() {
        let new = "<details><summary>More</summary>\n\nBody text.\n\n</details>"
        let html = core.diff(old: new + "\n\n<div align=\"center\">\n\nGone.\n\n</div>", new: new)
        #expect(html.contains("<details><summary>More</summary>\n<div class=\"md-block md-unchanged\""))
        #expect(html.contains("<p>Body text.</p>\n</div>\n</details>"))
        #expect(html.contains("md-block md-removed\">\n<p>Gone.</p>"))
        #expect(!html.contains("align"))
    }

    @Test func emptyDocuments() {
        #expect(core.diff(old: "", new: "") == "")
        #expect(core.diff(old: "Gone.", new: "").contains("md-block md-removed"))
    }

    @Test func wordDiffKeepsTheNewTagStructure() {
        #expect(core.htmlDiff("<p>a b</p>", "<p>a <strong>c</strong></p>") == "<p>a <del>b</del><strong><ins>c</ins></strong></p>")
        #expect(core.htmlDiff("<p>x &amp; y</p>", "<p>x &amp; y</p>") == "<p>x &amp; y</p>")
        #expect(core.htmlDiff(#"<p><img src="a.png"></p>"#, #"<p><img src="b.png"></p>"#)
            == #"<p><del><img src="a.png"></del><ins><img src="b.png"></ins></p>"#)
    }

    /// Text outside a cell would be moved out of the table by the HTML parser.
    @Test func changedTableRowsKeepTheirTextInCells() {
        let head = "| a | b |\n|---|:--|\n"
        let both = head + "| one | two |\n| three | four |"

        let removedLast = core.diff(old: both, new: head + "| one | two |")
        #expect(removedLast.contains("<tr><td><del>three</del></td><td style=\"text-align:left\"><del>four</del></td></tr></tbody>"))

        let removedFirst = core.diff(old: both, new: head + "| three | four |")
        #expect(removedFirst.contains("<td><del>one</del></td><td style=\"text-align:left\"><del>two</del></td></tr><tr><td>three</td>"))

        let added = core.diff(old: head + "| one | two |", new: both)
        #expect(added.contains("<td><ins>three</ins></td>"))
        #expect(!added.contains("<ins>\n"))

        // A changed alignment is the same cell, not a deleted and an inserted one.
        let realigned = core.diff(old: head + "| one | two |", new: "| a | b |\n|---|--:|\n| one | two |")
        #expect(!realigned.contains("<del>") && !realigned.contains("<td style=\"text-align:left\">"))

        // A removed column keeps a cell in every row.
        #expect(core.htmlDiff("<tr><td>a</td><td>b</td></tr>", "<tr><td>a</td></tr>") == "<tr><td>a</td><td><del>b</del></td></tr>")
        // Deleted text between cells gets a cell of its own.
        #expect(core.htmlDiff("<table><tbody>x</tbody></table>", "<table><tbody></tbody></table>") == "<table><tbody><tr><td><del>x</del></tbody></table>")
    }

    @Test func markersGoToTheContainingOrPrecedingBlock() {
        let units = [1...1, 3...5, 8...8]
        #expect(core.assignMarkers(units: units, markers: [4: 2, 5: 1]) == ["1:3:4"])
        #expect(core.assignMarkers(units: units, markers: [6: 1, 9: 1]) == ["1:1:6", "2:1:9"])
        #expect(core.assignMarkers(units: [3...4], markers: [1: 1]) == ["0:1:1"])
        #expect(core.assignMarkers(units: units, markers: [3: 0]) == [])
        #expect(core.assignMarkers(units: [], markers: [3: 1]) == [])
    }
}

@MainActor
@Suite struct BundleSchemeHandlerTests {
    func path(_ url: String, localRoot: URL? = URL(fileURLWithPath: "/work/tree/", isDirectory: true)) -> String? {
        let handler = BundleSchemeHandler()
        handler.localRoot = localRoot
        return handler.resource(for: URL(string: url)!).map { "\($0.file.path) \($0.mimeType)" }
    }

    @Test func servesBundleFilesAndLocalImages() {
        #expect(path("hermes-md://bundle/mdcore.js") == "\(BundleSchemeHandler.root.path)/mdcore.js text/javascript")
        #expect(path("hermes-md://bundle/local/docs/a%20shot.PNG") == "/work/tree/docs/a shot.PNG image/png")
    }

    @Test(arguments: [
        "hermes-md://bundle/local/%2E%2E/secret.png", "hermes-md://bundle/local/docs/../../secret.png",
        "hermes-md://bundle/local/.env", "hermes-md://bundle/local/notes.html", "hermes-md://bundle/%2E%2E/Info.plist",
    ])
    func refusesPathsOutsideTheRootAndLocalFilesThatAreNotImages(url: String) {
        #expect(path(url) == nil)
    }

    @Test func servesNoLocalFilesWithoutALocalRoot() {
        #expect(path("hermes-md://bundle/local/a.png", localRoot: nil) == nil)
    }
}

@Suite struct PageMessageTests {
    @Test func parsesValidMessages() {
        #expect(PageMessage(body: ["type": "ready"]) == .ready)
        #expect(PageMessage(body: ["type": "height", "value": 120.0]) == .height(120))
        #expect(PageMessage(body: ["type": "comment", "start": 3, "end": 7]) == .comment(3...7))
        #expect(PageMessage(body: ["type": "marker", "line": 4]) == .marker(line: 4))
        #expect(PageMessage(body: ["type": "scroll", "top": 812.5]) == .scroll(top: 812.5))
        #expect(PageMessage(body: ["type": "link", "url": "https://github.com/a/b"]) == .link(URL(string: "https://github.com/a/b")!))
    }

    @Test func rejectsMalformedMessages() {
        #expect(PageMessage(body: "ready") == nil)
        #expect(PageMessage(body: ["type": "comment", "start": 7, "end": 3]) == nil)
        #expect(PageMessage(body: ["type": "comment", "start": 0, "end": 3]) == nil)
        #expect(PageMessage(body: ["type": "marker", "line": "4"]) == nil)
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "hermes-md://bundle/index.html", "x-apple.systempreferences:"])
    func rejectsLinksThatAreNotWebOrMail(url: String) {
        #expect(PageMessage(body: ["type": "link", "url": url]) == nil)
    }
}

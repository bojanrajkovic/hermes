import AppKit
import SwiftUI
import Testing
import WebKit
@testable import MarkdownUI

/// A web view in an offscreen window, driven the same way the SwiftUI views drive it.
@MainActor
struct Page {
    let controller = MarkdownWebController()
    let window: NSWindow
    private(set) var openedURLs: Box<[URL]> = Box([])

    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    init(width: CGFloat = 820, dark: Bool = false) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = controller.webView
        controller.openURL = { [openedURLs] in openedURLs.value.append($0) }
    }

    func render(_ content: MarkdownPayload.Content, baseURL: URL? = nil, sizing: MarkdownView.Sizing = .fill) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !controller.isReady {
            try #require(ContinuousClock.now < deadline, "the page never became ready")
            try await Task.sleep(for: .milliseconds(20))
        }
        controller.update(MarkdownPayload(content: content, baseURL: baseURL, sizing: sizing))
        await controller.push()
    }

    func evaluate(_ script: String) async throws -> Any? {
        try await controller.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    /// Writes the whole rendered page to a PNG, on the window background color.
    func snapshot(to url: URL) async throws {
        let height = try #require(try await evaluate("return document.getElementById('content').getBoundingClientRect().height") as? Double)
        window.setContentSize(NSSize(width: window.frame.width, height: max(height, 50)))
        try await Task.sleep(for: .milliseconds(300))

        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            controller.webView.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown)) }
            }
        }
        let dark = window.appearance?.name == .darkAqua
        let flattened = NSImage(size: image.size, flipped: false) { rect in
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
            rect.fill()
            image.draw(in: rect)
            return true
        }
        let bitmap = try #require(flattened.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor
@Suite struct WebViewTests {
    @Test func scriptsInMarkdownNeverRun() async throws {
        let page = Page()
        try await page.render(.document(markdown: """
            <script>window.pwned = 'script'</script>
            <img src="hermes-md://bundle/missing.png" onerror="window.pwned = 'onerror'">
            <svg onload="window.pwned = 'svg'"></svg>
            <iframe srcdoc="<script>parent.pwned = 'iframe'</script>"></iframe>
            <style>#content { display: none }</style>

            [link](javascript:window.pwned='link')
            <a id="raw" href="javascript:window.pwned='raw'">raw</a>

            Still **rendered**.
            """))
        _ = try await page.evaluate("document.querySelectorAll('#content a').forEach(a => a.click())")
        try await Task.sleep(for: .milliseconds(300))

        #expect(try await page.evaluate("return window.pwned ?? null") is NSNull)
        #expect(try await page.evaluate("return document.querySelectorAll('#content script, #content iframe, #content style, #content [onerror], #content [onload]').length") as? Int == 0)
        #expect(try await page.evaluate("return getComputedStyle(document.getElementById('content')).display") as? String == "block")
        #expect(try await page.evaluate("return document.querySelector('#content strong').textContent") as? String == "rendered")
        #expect(page.openedURLs.value.isEmpty)
    }

    /// A pull request's Markdown must not be able to cover the page or fake
    /// a commentable block with line numbers of its choosing.
    @Test func rawHTMLCannotRestyleThePageOrPassForDiffMarkup() async throws {
        let page = Page()
        var comments: [ClosedRange<Int>] = []
        var markers: [Int] = []
        page.controller.onStartComment = { comments.append($0) }
        page.controller.onSelectMarker = { markers.append($0) }

        let new = """
            Real.

            <div id="fake" class="md-block md-added keep" data-start="90" data-end="99" data-md="x" style="position:fixed;inset:0">fake</div>

            <span id="badge" class="md-badge" data-line="77">9</span>

            | a |
            |--:|
            | 1 |
            """
        try await page.render(.diff(old: "Real.", new: new, markers: [:]))

        #expect(try await page.evaluate("return document.getElementById('fake').className") as? String == "keep")
        #expect(try await page.evaluate("return document.getElementById('fake').hasAttribute('style')") as? Bool == false)
        #expect(try await page.evaluate("return document.querySelectorAll('[data-start=\"90\"], [data-line]').length") as? Int == 0)
        #expect(try await page.evaluate("return document.querySelector('#content th').style.textAlign") as? String == "right")
        #expect(try await page.evaluate("return document.querySelectorAll('.md-block[data-start]').length") as? Int == 3)

        _ = try await page.evaluate("""
            document.getElementById('badge').click();
            const fake = document.getElementById('fake');
            fake.dispatchEvent(new MouseEvent('mouseover', {bubbles: true}));
            document.querySelector('.md-add')?.click();
            """)
        try await Task.sleep(for: .milliseconds(200))
        #expect(markers.isEmpty)
        // A raw HTML block is not wrapped, so it has no comment button.
        #expect(comments.isEmpty)
    }

    @Test func mermaidLoadsWithTheFirstDiagram() async throws {
        let page = Page()
        try await page.render(.document(markdown: "No diagram."))
        #expect(try await page.evaluate("return typeof mermaid") as? String == "undefined")

        try await page.render(.document(markdown: "```mermaid\ngraph TD\n  A[Start] --> B[End]\n```\n\n```mermaid\nnot a diagram\n```"))
        #expect(try await page.evaluate("return document.querySelectorAll('#content .mermaid-diagram svg').length") as? Int == 1)
        #expect(try await page.evaluate("return document.querySelector('#content .mermaid-diagram').textContent.includes('Start')") as? Bool == true)
        // A diagram that does not parse shows its source and one line of the error.
        #expect(try await page.evaluate("return document.querySelectorAll('#content .mermaid-error').length") as? Int == 1)
        #expect(try await page.evaluate("return document.querySelector('#content pre').textContent.trim()") as? String == "not a diagram")
        #expect(try await page.evaluate("return document.querySelectorAll('body > :not(article, script)').length") as? Int == 0)
    }

    @Test func keepsTheScrollPositionWhenTheMarkdownChanges() async throws {
        let page = Page()
        let paragraphs = (1...200).map { "Paragraph \($0)." }
        try await page.render(.document(markdown: paragraphs.joined(separator: "\n\n")))
        _ = try await page.evaluate("window.scrollTo(0, 1500)")
        #expect(try await page.evaluate("return window.scrollY") as? Double == 1500)

        try await page.render(.document(markdown: (paragraphs + ["One more."]).joined(separator: "\n\n")))
        #expect(try await page.evaluate("return window.scrollY") as? Double == 1500)
    }

    @Test func linksOpenExternallyAndResolveAgainstTheBaseURL() async throws {
        let page = Page()
        let base = URL(string: "https://github.com/owner/repo/blob/main/docs/")!
        try await page.render(.document(markdown: "[guide](guide.md) [abs](https://example.com/x) ![shot](img/a.png) [top](#top)"), baseURL: base)
        _ = try await page.evaluate("document.querySelectorAll('#content a').forEach(a => a.click())")
        try await Task.sleep(for: .milliseconds(200))

        #expect(page.openedURLs.value.map(\.absoluteString) == ["https://github.com/owner/repo/blob/main/docs/guide.md", "https://example.com/x"])
        #expect(try await page.evaluate("return document.querySelector('#content img').src") as? String == "https://github.com/owner/repo/blob/main/docs/img/a.png")
        #expect(page.controller.webView.url == BundleSchemeHandler.shellURL)
    }

    /// A view sized to its content cannot scroll itself, so the enclosing scroll view moves.
    @Test func inPageLinkScrollsTheEnclosingScrollView() async throws {
        let page = Page()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        page.window.contentView = scrollView
        page.controller.webView.frame = NSRect(x: 0, y: 0, width: 820, height: 3000)
        scrollView.documentView = page.controller.webView

        let filler = Array(repeating: "Paragraph.", count: 40).joined(separator: "\n\n")
        try await page.render(.document(markdown: "[go](#deep-heading)\n\n\(filler)\n\n## Deep heading\n\n\(filler)"), sizing: .fitContent)
        let top = try #require(try await page.evaluate("return document.getElementById('deep-heading').getBoundingClientRect().top") as? Double)
        _ = try await page.evaluate("document.querySelector('#content a').click()")
        try await Task.sleep(for: .milliseconds(200))

        #expect(top > 600)
        #expect(abs(scrollView.contentView.bounds.minY - top) < 1)
    }

    @Test func relativeImagesLoadFromALocalBaseDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hermes-md-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        try #require(Data(base64Encoded: pixel)).write(to: directory.appending(path: "docs/a shot.png"))

        let page = Page()
        try await page.render(.document(markdown: "![in](docs/a%20shot.png) ![out](../outside.png)"), baseURL: directory)
        let widths = try await page.evaluate("""
            const images = [...document.querySelectorAll('#content img')];
            await Promise.all(images.map(image => image.complete || new Promise(done => { image.onload = image.onerror = done; })));
            return images.map(image => image.naturalWidth);
            """)
        #expect(widths as? [Int] == [1, 0])
    }

    @Test func updatesInPlaceWithoutReloading() async throws {
        let page = Page()
        try await page.render(.document(markdown: "one"))
        _ = try await page.evaluate("window.survivor = true")
        try await page.render(.document(markdown: "two"))

        #expect(try await page.evaluate("return window.survivor === true") as? Bool == true)
        #expect(try await page.evaluate("return document.getElementById('content').textContent.trim()") as? String == "two")
    }

    @Test func diffButtonsReportLinesAndMarkers() async throws {
        let page = Page()
        var comments: [ClosedRange<Int>] = []
        var markers: [Int] = []
        page.controller.onStartComment = { comments.append($0) }
        page.controller.onSelectMarker = { markers.append($0) }

        try await page.render(.diff(old: "Keep.\n\nOld text here.", new: "Keep.\n\nNew para\nspans two lines.\n\n- item", markers: [4: 2]))
        #expect(try await page.evaluate("return document.querySelector('.md-badge').textContent") as? String == "2")

        _ = try await page.evaluate("""
            document.querySelector('.md-badge').click();
            const block = document.querySelector('.md-added');
            block.dispatchEvent(new MouseEvent('mouseover', {bubbles: true}));
            block.querySelector('.md-add').click();
            """)
        try await Task.sleep(for: .milliseconds(200))

        #expect(markers == [4])
        #expect(comments == [3...4])
    }

    @Test func reportsContentHeightWhenItGrowsAndShrinks() async throws {
        let page = Page()
        var heights: [CGFloat] = []
        page.controller.onHeight = { heights.append($0) }

        try await page.render(.document(markdown: "one\n\ntwo\n\nthree"), sizing: .fitContent)
        try await Task.sleep(for: .milliseconds(300))
        let tall = try #require(heights.last)
        #expect(tall > 40 && tall < 200)

        try await page.render(.document(markdown: "one"), sizing: .fitContent)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try #require(heights.last) < tall)
    }

    /// The view must settle on its content height instead of resizing forever.
    @Test func fitContentViewSettlesOnItsContentHeight() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ScrollView {
            MarkdownView(markdown: "# Title\n\nA paragraph.\n\n- a\n- b", sizing: .fitContent)
        })
        window.contentView = host

        func webViewHeight() -> CGFloat? {
            var stack: [NSView] = [host]
            while let view = stack.popLast() {
                if view is WKWebView { return view.frame.height }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }

        var samples: [CGFloat] = []
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            if let height = webViewHeight() { samples.append(height) }
        }
        let settled = try #require(samples.last)
        #expect(settled > 60 && settled < 300)
        #expect(samples.suffix(10).allSatisfy { $0 == settled })
    }

    /// Writes PNGs for visual checks. Runs only when `MARKDOWNUI_SNAPSHOT_DIR`
    /// is set. Every `*.md` file in that directory is rendered in light and
    /// dark; `NAME.old.md` next to `NAME.md` also produces a rich diff.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARKDOWNUI_SNAPSHOT_DIR"] != nil))
    func writeSnapshots() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MARKDOWNUI_SNAPSHOT_DIR"]!)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasSuffix(".old.md") }

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let markdown = try String(contentsOf: file, encoding: .utf8)
            let old = try? String(contentsOf: directory.appendingPathComponent("\(name).old.md"), encoding: .utf8)

            for dark in [false, true] {
                let suffix = dark ? "dark" : "light"
                let page = Page(dark: dark)
                try await page.render(.document(markdown: markdown))
                try await page.snapshot(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
                if let old {
                    try await page.render(.diff(old: old, new: markdown, markers: [1: 3]))
                    _ = try await page.evaluate("document.querySelector('li.md-added, .md-added')?.dispatchEvent(new MouseEvent('mouseover', {bubbles: true}))")
                    try await page.snapshot(to: directory.appendingPathComponent("\(name)-diff-\(suffix).png"))
                }
            }
        }
    }
}

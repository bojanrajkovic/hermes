import AppKit
import OSLog
import SwiftUI
import WebKit

private let log = Logger(subsystem: "Hermes", category: "MarkdownUI")

/// What the page renders. Mirrors the `payload` object documented in `renderer.js`.
struct MarkdownPayload: Equatable {
    enum Content: Equatable {
        case document(markdown: String)
        case diff(old: String, new: String, markers: [Int: Int])
    }

    var content: Content
    var baseURL: URL?
    var sizing: MarkdownView.Sizing

    var json: [String: Any] {
        var json: [String: Any] = [
            "baseURL": baseURL?.absoluteString ?? NSNull(),
            "fit": sizing == .fitContent,
        ]
        switch content {
        case .document(let markdown):
            json["mode"] = "document"
            json["markdown"] = markdown
        case .diff(let old, let new, let markers):
            json["mode"] = "diff"
            json["old"] = old
            json["new"] = new
            json["markers"] = Dictionary(uniqueKeysWithValues: markers.map { (String($0.key), $0.value) })
        }
        return json
    }
}

/// A message the page posts to Swift.
enum PageMessage: Equatable {
    case ready
    case height(CGFloat)
    case link(URL)
    case comment(ClosedRange<Int>)
    case marker(line: Int)
    case scroll(top: CGFloat)

    /// Parses a script message body. Returns `nil` for anything malformed,
    /// including a link whose scheme is not http, https, or mailto: the page
    /// shows untrusted Markdown, so it must not be able to open `file:` or
    /// app-specific URLs.
    init?(body: Any) {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
        switch type {
        case "ready":
            self = .ready
        case "height":
            guard let value = body["value"] as? Double, value >= 0 else { return nil }
            self = .height(value)
        case "link":
            guard let string = body["url"] as? String, let url = URL(string: string),
                  let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme)
            else { return nil }
            self = .link(url)
        case "comment":
            guard let start = body["start"] as? Int, let end = body["end"] as? Int, start >= 1, end >= start else { return nil }
            self = .comment(start...end)
        case "marker":
            guard let line = body["line"] as? Int, line >= 1 else { return nil }
            self = .marker(line: line)
        case "scroll":
            guard let top = body["top"] as? Double, top >= 0 else { return nil }
            self = .scroll(top: top)
        default:
            return nil
        }
    }
}

/// Serves the bundled page and libraries under `hermes-md://bundle/`, and the
/// images of a local base directory under `hermes-md://bundle/local/`.
/// A custom scheme gives the page a real origin, which the page's content
/// security policy needs for `'self'`. The page cannot load `file:` URLs, so
/// local images come through this handler too.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "hermes-md"
    static let shellURL = URL(string: "\(scheme)://bundle/index.html")!

    nonisolated static let root = Bundle.module.url(forResource: "Resources", withExtension: nil)!.standardizedFileURL

    private static let localPrefix = "/local/"
    private static let mimeTypes = ["html": "text/html", "js": "text/javascript", "css": "text/css"]
    private static let imageTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
        "webp": "image/webp", "avif": "image/avif", "bmp": "image/bmp", "ico": "image/x-icon",
    ]

    /// The directory whose images are served under `local/`. With `nil`, none are.
    var localRoot: URL?

    /// The file a URL maps to, and its MIME type. Returns `nil` for a path
    /// that leaves its root directory and for a local file that is not an
    /// image: the page shows untrusted Markdown, which must not reach other files.
    func resource(for url: URL) -> (file: URL, mimeType: String)? {
        var root = Self.root, types = Self.mimeTypes, path = url.path
        if path.hasPrefix(Self.localPrefix) {
            guard let localRoot else { return nil }
            root = localRoot.standardizedFileURL
            types = Self.imageTypes
            path = String(path.dropFirst(Self.localPrefix.count))
        }
        let file = root.appendingPathComponent(path).standardizedFileURL

        guard file.path.hasPrefix(root.path + "/"), let mimeType = types[file.pathExtension.lowercased()] else { return nil }
        return (file, mimeType)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (file, mimeType) = resource(for: url), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let encoding = mimeType.hasPrefix("text/") ? "utf-8" : nil
        task.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: encoding))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// A web view that can hand scroll events to the enclosing native scroll view.
final class MarkdownWKWebView: WKWebView {
    var forwardsScroll = false

    // A mostly horizontal scroll stays in the page, so a wide code block or
    // table scrolls sideways when the view is sized to its content.
    override func scrollWheel(with event: NSEvent) {
        if forwardsScroll, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Owns the web view, pushes payloads into the page, and routes its messages.
@MainActor
final class MarkdownWebController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: MarkdownWKWebView
    private(set) var isReady = false
    private var payload: MarkdownPayload?
    private let schemeHandler = BundleSchemeHandler()

    var onHeight: @MainActor (CGFloat) -> Void = { _ in }
    var onStartComment: @MainActor (ClosedRange<Int>) -> Void = { _ in }
    var onSelectMarker: @MainActor (Int) -> Void = { _ in }
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: BundleSchemeHandler.scheme)
        webView = MarkdownWKWebView(frame: .zero, configuration: configuration)
        super.init()

        // The page is transparent, so nothing flashes before the first render
        // and the host's background shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = self
        configuration.userContentController.add(self, name: "hermes")
        webView.load(URLRequest(url: BundleSchemeHandler.shellURL))
    }

    /// Breaks the retain cycle through the script message handler.
    func tearDown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Renders `payload` in place. Does nothing when it equals the last one.
    func update(_ payload: MarkdownPayload) {
        guard payload != self.payload else { return }
        self.payload = payload
        webView.forwardsScroll = payload.sizing == .fitContent
        schemeHandler.localRoot = payload.baseURL.flatMap { url in
            url.isFileURL ? (url.hasDirectoryPath ? url : url.deletingLastPathComponent()) : nil
        }
        Task { await push() }
    }

    /// Sends the current payload to the page and waits for it to finish drawing, diagrams included.
    func push() async {
        guard isReady, let payload else { return }
        do {
            _ = try await webView.callAsyncJavaScript(
                "return Hermes.render(payload)", arguments: ["payload": payload.json], in: nil, contentWorld: .page)
        } catch {
            log.error("Markdown render failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let message = PageMessage(body: message.body) else { return }
        switch message {
        case .ready:
            // Also fires after a reload, so the page gets its content back.
            isReady = true
            Task { await push() }
        case .height(let height):
            onHeight(height)
        case .link(let url):
            openURL(url)
        case .comment(let lines):
            onStartComment(lines)
        case .marker(let line):
            onSelectMarker(line)
        case .scroll(let top):
            // As tall as the enclosing scroll view shows, so the target lands at the top.
            let height = webView.enclosingScrollView?.contentView.bounds.height ?? 1
            webView.scrollToVisible(NSRect(x: 0, y: top, width: 1, height: height))
        }
    }

    /// Only the bundled page loads. Links reach Swift as messages instead.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url == BundleSchemeHandler.shellURL ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        webView.reload()
    }
}

/// Hosts the web view in SwiftUI.
struct MarkdownWebView: NSViewRepresentable {
    var payload: MarkdownPayload
    var onHeight: @MainActor (CGFloat) -> Void = { _ in }
    var onStartComment: @MainActor (ClosedRange<Int>) -> Void = { _ in }
    var onSelectMarker: @MainActor (Int) -> Void = { _ in }

    func makeCoordinator() -> MarkdownWebController {
        MarkdownWebController()
    }

    func makeNSView(context: Context) -> MarkdownWKWebView {
        context.coordinator.webView
    }

    func updateNSView(_ webView: MarkdownWKWebView, context: Context) {
        let controller = context.coordinator
        controller.onHeight = onHeight
        controller.onStartComment = onStartComment
        controller.onSelectMarker = onSelectMarker
        controller.update(payload)
    }

    static func dismantleNSView(_ webView: MarkdownWKWebView, coordinator: MarkdownWebController) {
        coordinator.tearDown()
    }
}

/// Wraps the web view with the frame its sizing mode needs.
struct SizedMarkdownWebView: View {
    var payload: MarkdownPayload
    var onStartComment: @MainActor (ClosedRange<Int>) -> Void = { _ in }
    var onSelectMarker: @MainActor (Int) -> Void = { _ in }

    // Starts at one point so the page lays out at the real width and can report its height.
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        switch payload.sizing {
        case .fill:
            MarkdownWebView(payload: payload, onStartComment: onStartComment, onSelectMarker: onSelectMarker)
        case .fitContent:
            MarkdownWebView(
                payload: payload,
                onHeight: { height in
                    if abs(height - contentHeight) > 0.5 { contentHeight = max(height, 1) }
                },
                onStartComment: onStartComment,
                onSelectMarker: onSelectMarker
            )
            .frame(height: contentHeight)
        }
    }
}

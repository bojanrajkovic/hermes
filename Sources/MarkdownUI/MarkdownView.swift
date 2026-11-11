import SwiftUI

/// Renders GitHub-flavored Markdown the way github.com does: tables, task
/// lists, footnotes, alerts (`> [!NOTE]`), emoji shortcodes, highlighted code
/// blocks, and Mermaid diagrams.
///
/// The view follows the system light or dark appearance and has a transparent
/// background, so put it on whatever surface the surrounding UI uses.
///
/// Raw HTML in the Markdown is sanitized, and scripts in it never run.
/// Clicking a link opens it in the default browser; only `http`, `https`, and
/// `mailto` links open. Changing `markdown` re-renders in place and keeps the
/// scroll position.
///
/// ```swift
/// ScrollView {
///     ForEach(comments) { comment in
///         MarkdownView(markdown: comment.body, sizing: .fitContent)
///     }
/// }
/// ```
public struct MarkdownView: View {
    /// How the view takes up space.
    public enum Sizing: Sendable, Hashable {
        /// Fills the space it is offered and scrolls its own content.
        case fill
        /// Takes the offered width and is exactly as tall as its content.
        /// It does not scroll; vertical scroll events go to the enclosing
        /// scroll view. The height is one point until the first render.
        case fitContent
    }

    private let payload: MarkdownPayload

    /// - Parameters:
    ///   - markdown: The Markdown source.
    ///   - baseURL: Relative links and image paths resolve against this URL.
    ///     With `nil`, relative links do nothing and relative images do not load.
    ///     With a `file:` directory, relative images load only from inside that directory.
    ///   - sizing: Whether the view scrolls or sizes itself to its content.
    public init(markdown: String, baseURL: URL? = nil, sizing: Sizing = .fill) {
        payload = MarkdownPayload(content: .document(markdown: markdown), baseURL: baseURL, sizing: sizing)
    }

    public var body: some View {
        SizedMarkdownWebView(payload: payload)
    }
}

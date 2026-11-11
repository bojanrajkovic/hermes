import SwiftUI

/// Renders the new version of a Markdown file with the changes from the old
/// version marked on the rendered blocks (a "rich diff").
///
/// A block is a top-level element: a paragraph, heading, table, code block,
/// block quote, or one top-level list item.
///
/// - Added blocks have a green background.
/// - Removed blocks are shown where they used to be, with a red background.
/// - Modified blocks show inserted and deleted words inline. A modified
///   Mermaid block shows the old and the new diagram side by side.
/// - A block whose source changed but renders the same, such as a re-wrapped
///   paragraph, is not marked.
///
/// Hovering a block that exists in the new file shows a "+" button. Removed
/// blocks have none, because they have no lines in the new file.
///
/// Rendering, sanitizing, links, and appearance work as in ``MarkdownView``.
public struct MarkdownDiffView: View {
    private let payload: MarkdownPayload
    private let onStartComment: @MainActor (ClosedRange<Int>) -> Void
    private let onSelectMarker: @MainActor (Int) -> Void

    /// - Parameters:
    ///   - old: The old Markdown source. Pass an empty string for a new file.
    ///   - new: The new Markdown source. Pass an empty string for a deleted file.
    ///   - baseURL: Relative links and image paths resolve against this URL.
    ///   - commentMarkers: Comment counts by 1-based line number in `new`.
    ///     The block containing a line shows a badge with the count. Counts
    ///     for several lines in one block add up. A line outside every block
    ///     (a blank line, a link definition) counts toward the closest block
    ///     above it. Changing the markers redraws only the badges.
    ///   - sizing: Whether the view scrolls or sizes itself to its content.
    ///   - onStartComment: Called when the user clicks a block's "+" button,
    ///     with the block's 1-based, inclusive line range in `new`.
    ///   - onSelectMarker: Called when the user clicks a badge, with the lowest
    ///     line number from `commentMarkers` that the badge stands for.
    public init(
        old: String,
        new: String,
        baseURL: URL? = nil,
        commentMarkers: [Int: Int] = [:],
        sizing: MarkdownView.Sizing = .fill,
        onStartComment: @escaping @MainActor (ClosedRange<Int>) -> Void,
        onSelectMarker: @escaping @MainActor (Int) -> Void
    ) {
        payload = MarkdownPayload(
            content: .diff(old: old, new: new, markers: commentMarkers), baseURL: baseURL, sizing: sizing)
        self.onStartComment = onStartComment
        self.onSelectMarker = onSelectMarker
    }

    public var body: some View {
        SizedMarkdownWebView(payload: payload, onStartComment: onStartComment, onSelectMarker: onSelectMarker)
    }
}

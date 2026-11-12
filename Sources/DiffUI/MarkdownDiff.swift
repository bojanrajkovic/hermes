import DiffKit
import MarkdownUI
import SwiftUI

/// Rebuilds a file's old text from its new text by undoing the diff's hunks.
///
/// - Parameters:
///   - newText: The file's full content at the diff's new side. Empty for a deleted file.
///   - hunks: The file's hunks, in order.
func oldText(newText: String, hunks: [Hunk]) -> String {
    // Lines with their endings, so untouched lines come through unchanged.
    var lines: [Substring] = []
    var start = newText.startIndex
    // Git ends lines at a line feed only.
    for index in newText.indices where newText[index] == "\n" || newText[index] == "\r\n" {
        let next = newText.index(after: index)
        lines.append(newText[start..<next])
        start = next
    }
    if start < newText.endIndex { lines.append(newText[start...]) }

    var old = ""
    var nextNew = 1
    func copy(upTo end: Int) {
        guard nextNew < end else { return }
        old += lines[min(nextNew - 1, lines.count)..<min(end - 1, lines.count)].joined()
    }
    for hunk in hunks {
        // With a count of 0, the start is the line before the change, not the first line of it.
        let first = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
        copy(upTo: first)
        for line in hunk.lines where line.kind != .addition {
            old += line.text
            switch line.ending {
            case .lf: old += "\n"
            case .crlf: old += "\r\n"
            case .none: break
            }
        }
        nextNew = first + hunk.newCount
    }
    copy(upTo: lines.count + 1)
    return old
}

/// Why a block of a rendered Markdown file cannot take a comment.
enum MarkdownAnchorFailure: Error, Hashable {
    case notInDiff

    var text: String {
        "This block is not part of the diff. GitHub only accepts comments on changed lines and the few unchanged lines shown around them."
    }
}

/// The comment anchor for a rendered block that spans `lines` of the new file.
///
/// The anchor covers the block's lines that are in the diff. When they are
/// spread over several hunks, it covers those in the first one, because a
/// comment cannot span hunks.
func markdownAnchor(file: FileDiff, lines: ClosedRange<Int>) -> Result<CommentAnchor, MarkdownAnchorFailure> {
    let inDiff = lines.compactMap { line -> (position: DiffPosition, hunk: Int)? in
        let position = DiffPosition(side: .right, line: line)
        return file.location(of: position).map { (position, $0.hunkIndex) }
    }
    guard let first = inDiff.first, let last = inDiff.last(where: { $0.hunk == first.hunk }) else { return .failure(.notInDiff) }
    return .success(CommentAnchor(path: file.path, start: first.position == last.position ? nil : first.position, end: last.position))
}

/// A Markdown file's diff as rendered blocks.
struct RenderedMarkdown: View {
    let file: FileModel
    let model: DiffModel

    var body: some View {
        switch file.markdown {
        case .loaded(let old, let new):
            MarkdownDiffView(
                old: old, new: new, baseURL: model.baseURL(for: file.diff),
                commentMarkers: model.review?.layout.markers(for: file.id) ?? [:], sizing: .fitContent
            ) { lines in
                if let review = model.review {
                    review.startComment(file: file.id, newLines: lines)
                } else {
                    model.isReadOnlyNoticeShown = true
                }
            } onSelectMarker: { line in
                // The threads open in a popover over the file's line, so the file shows its lines.
                if let row = file.diff.line(at: DiffPosition(side: .right, line: line)) {
                    model.review?.focusedLine = ReviewModel.LineRef(file: file.id, line: row.numbers)
                }
            }
            // The web view is one point tall until it has rendered, and it only renders while it is
            // on screen. The minimum keeps it from being scrolled out of view before that.
            .frame(minHeight: DiffMetrics.renderedMinHeight, alignment: .top)
            .padding(.horizontal, DiffMetrics.headerPaddingHorizontal)
            .padding(.vertical, 8)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .padding(DiffMetrics.headerPaddingHorizontal)
        case .loading, nil:
            ProgressView("Rendering…")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(20)
        }
    }
}

/// The composer for a comment started from a rendered Markdown file, docked
/// at the bottom of the list. The file's lines are hidden while it is
/// rendered, so there is no line to put the composer under, and the block
/// being commented on stays in view.
struct RenderedCommentDock: View {
    let model: DiffModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let review = model.review {
                if let notice = review.notice, notice.line == nil {
                    NoticeBanner(text: notice.text) { review.dismissNotice() }
                }
                if case .thread(let file, _, let anchor) = review.composer?.target,
                   model.files.first(where: { $0.id == file })?.showsRendered == true
                {
                    CommentComposer(review: review, title: "Comment on \(anchor.path), \(lineRangeLabel(anchor))")
                }
            } else if model.isReadOnlyNoticeShown {
                NoticeBanner(text: "Comments can only be added to pull requests.") { model.isReadOnlyNoticeShown = false }
            }
        }
        .frame(maxWidth: ReviewMetrics.attachmentMaxWidth)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

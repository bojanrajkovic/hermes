import AppKit
import DiffKit
import GitHubKit
import HermesUI
import MarkdownUI
import SwiftUI

/// Sizes and names shared by the review views.
enum ReviewMetrics {
    static let cardCornerRadius: CGFloat = 8
    static let cardPadding: CGFloat = 10
    static let avatarSize: CGFloat = 20
    static let plusWidth: CGFloat = 16
    /// Comments stay near a comfortable reading width in wide windows.
    static let attachmentMaxWidth: CGFloat = 780
    static let attachmentLeading: CGFloat = 44
    static let composerMinHeight: CGFloat = 90
    static let composerMaxHeight: CGFloat = 260
}

/// "line 25", "old line 12", or "lines 94 to 96".
func lineRangeLabel(_ anchor: CommentAnchor) -> String {
    func name(_ position: DiffPosition) -> String { position.side == .left ? "old line \(position.line)" : "line \(position.line)" }
    guard let start = anchor.start else { return name(anchor.end) }
    if start.side == anchor.end.side {
        return "\(start.side == .left ? "old lines" : "lines") \(start.line) to \(anchor.end.line)"
    }
    return "\(name(start)) to \(name(anchor.end))"
}

extension View {
    /// Places comments under a line: indented past the gutter, on a quiet band as wide as the list.
    func attachmentInset() -> some View {
        frame(maxWidth: ReviewMetrics.attachmentMaxWidth, alignment: .leading)
            .padding(.leading, ReviewMetrics.attachmentLeading)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }
    }

    /// Styles a form's main button: prominent while it can be pressed.
    ///
    /// A disabled prominent button keeps its filled bezel and still reads as
    /// the thing to press, so a disabled one is drawn as an ordinary button.
    @ViewBuilder func mainAction(isDisabled: Bool) -> some View {
        if isDisabled {
            buttonStyle(.bordered).disabled(true)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    fileprivate func card() -> some View {
        background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: ReviewMetrics.cardCornerRadius))
            .overlay { RoundedRectangle(cornerRadius: ReviewMetrics.cardCornerRadius).strokeBorder(.separator) }
    }
}

// MARK: Under a line

/// The threads, pending comments, and composer under one line of the diff. They are a table row of their own.
struct LineAttachments: View {
    let file: FileModel
    let line: DiffLine
    @Environment(ReviewModel.self) private var review: ReviewModel?

    var body: some View {
        if let review {
            let numbers = line.numbers
            let items = review.layout.lines[file.id]?[numbers]
            let notice = review.notice.flatMap { $0.file == file.id && $0.line == numbers ? $0 : nil }
            let composing: CommentAnchor? = if case .thread(file.id, numbers, let anchor) = review.composer?.target { anchor } else { nil }
            if items != nil || notice != nil || composing != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let notice {
                        NoticeBanner(text: notice.text) { review.dismissNotice() }
                    }
                    ForEach(items?.threads ?? []) { thread in
                        ThreadView(thread: thread, review: review)
                    }
                    ForEach(items?.drafts ?? []) { draft in
                        DraftView(draft: draft, review: review)
                    }
                    if let composing {
                        CommentComposer(review: review, title: "Comment on \(lineRangeLabel(composing))")
                    }
                }
                .attachmentInset()
            }
        }
    }
}

/// A dismissible explanation, such as why a range cannot take a comment.
struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(ReviewMetrics.cardPadding)
        .card()
    }
}

// MARK: Threads

/// One review thread: its comments, the pending replies, and the reply field.
struct ThreadView: View {
    let thread: ReviewThread
    let review: ReviewModel
    /// Shows the file and line, for threads listed away from the diff.
    var showsLocation = false

    private var isCollapsed: Bool { thread.isResolved && !review.expandedThreads.contains(thread.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                ForEach(thread.comments) { comment in
                    Divider()
                    CommentView(author: comment.author, date: comment.createdAt, markdown: comment.body)
                        .padding(ReviewMetrics.cardPadding)
                }
                ForEach(review.layout.replies[thread.id] ?? []) { draft in
                    Divider()
                    DraftView(draft: draft, review: review, isInThread: true)
                }
                Divider()
                reply.padding(ReviewMetrics.cardPadding)
            }
        }
        .card()
    }

    @ViewBuilder private var header: some View {
        let range = thread.anchor.flatMap { $0.start == nil ? nil : lineRangeLabel($0) }
        if thread.isResolved {
            Button {
                review.expandedThreads.formSymmetricDifference([thread.id])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Label("Resolved", systemImage: "checkmark.circle")
                        .fontWeight(.medium)
                    if isCollapsed, let first = thread.comments.first {
                        Text(verbatim: "\(first.author?.login ?? "ghost"): \(first.body.split(whereSeparator: \.isNewline).first ?? "")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if thread.comments.count > 1, isCollapsed {
                        Text("^[\(thread.comments.count) comment](inflect: true)").foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .padding(ReviewMetrics.cardPadding)
            .accessibilityHint(isCollapsed ? "Shows the thread" : "Hides the thread")
        } else if showsLocation || range != nil || thread.isOutdated {
            HStack(spacing: 8) {
                if showsLocation {
                    Text(verbatim: thread.line.map { "\(thread.path):\($0)" } ?? thread.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let range {
                    Label("Comment on \(range)", systemImage: "arrow.up.and.down.text.horizontal")
                }
                if thread.isOutdated {
                    Badge(text: "Outdated", symbol: "clock.arrow.circlepath")
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, ReviewMetrics.cardPadding)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var reply: some View {
        if review.composer?.target == .reply(threadID: thread.id) {
            CommentComposer(review: review, title: "Reply")
        } else {
            Button {
                review.open(.reply(threadID: thread.id))
            } label: {
                Text("Reply…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reply to thread")
        }
    }
}

/// A small label with a symbol, for "Pending" and "Outdated".
struct Badge: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(Theme.Fonts.badge)
            .padding(.horizontal, Theme.badgePaddingHorizontal)
            .padding(.vertical, Theme.badgePaddingVertical)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.badgeCornerRadius))
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }
}

/// An author line and a Markdown body.
private struct CommentView<Accessory: View>: View {
    let author: User?
    /// `nil` for a comment that is not on GitHub yet.
    let date: Date?
    let markdown: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                avatar
                Text(verbatim: date == nil ? "You" : author?.login ?? "ghost")
                    .fontWeight(.semibold)
                if let date {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer(minLength: 8)
                accessory()
            }
            .font(.callout)
            .lineLimit(1)
            MarkdownView(markdown: markdown, sizing: .fitContent)
        }
    }

    @ViewBuilder private var avatar: some View {
        let placeholder = Image(systemName: "person.crop.circle.fill")
            .resizable()
            .foregroundStyle(.secondary)
        Group {
            if let url = author?.avatarURL {
                AsyncImage(url: url) { $0.resizable() } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: ReviewMetrics.avatarSize, height: ReviewMetrics.avatarSize)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

extension CommentView where Accessory == EmptyView {
    init(author: User?, date: Date?, markdown: String) {
        self.init(author: author, date: date, markdown: markdown) { EmptyView() }
    }
}

/// A comment waiting in the pending review, with its Edit and Delete buttons.
struct DraftView: View {
    let draft: DraftComment
    let review: ReviewModel
    /// Inside a thread's card, the draft has no card of its own.
    var isInThread = false
    @State private var isConfirmingDelete = false

    var body: some View {
        if review.composer?.target == .edit(draft: draft.id) {
            CommentComposer(review: review, title: "Edit comment")
                .padding(isInThread ? ReviewMetrics.cardPadding : 0)
        } else if isInThread {
            content.padding(ReviewMetrics.cardPadding)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let anchor = draft.anchor, anchor.start != nil {
                    Label("Comment on \(lineRangeLabel(anchor))", systemImage: "arrow.up.and.down.text.horizontal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, ReviewMetrics.cardPadding)
                        .padding(.vertical, 6)
                    Divider()
                }
                content.padding(ReviewMetrics.cardPadding)
            }
            .card()
        }
    }

    private var content: some View {
        CommentView(author: nil, date: nil, markdown: draft.body) {
            Badge(text: "Pending", symbol: "clock")
            Button("Edit Comment", systemImage: "pencil") { review.open(.edit(draft: draft.id)) }
                .help("Edit Comment")
            Button("Delete Comment", systemImage: "trash") { isConfirmingDelete = true }
                .help("Delete Comment")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .confirmationDialog("Delete this pending comment?", isPresented: $isConfirmingDelete) {
            Button("Delete Comment", role: .destructive) { review.delete(draft.id) }
        } message: {
            Text("The comment has not been sent. Deleting it can't be undone.")
        }
    }
}

// MARK: Composer

/// The Markdown editor for the comment being written. Its text lives in the
/// review model, so it survives the row scrolling out of view.
struct CommentComposer: View {
    let review: ReviewModel
    let title: String

    private enum Tab { case write, preview }
    @State private var tab = Tab.write
    @FocusState private var isFocused: Bool

    private var text: String { review.composer?.text ?? "" }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isEdit: Bool { if case .edit = review.composer?.target { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Picker("Editor", selection: $tab) {
                    Text("Write").tag(Tab.write)
                    Text("Preview").tag(Tab.preview)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch tab {
            case .write:
                TextEditor(text: Binding { text } set: { review.composer?.text = $0 })
                    .font(.body)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: ReviewMetrics.composerMinHeight, maxHeight: ReviewMetrics.composerMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
                    .accessibilityLabel("Comment")
            case .preview:
                Group {
                    if isEmpty {
                        Text("Nothing to preview.").foregroundStyle(.secondary).padding(8)
                    } else {
                        MarkdownView(markdown: text, sizing: .fitContent)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: ReviewMetrics.composerMinHeight, alignment: .topLeading)
            }
            HStack {
                Text("Markdown · ⌘↩ adds the comment · esc cancels")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel) { review.cancelComposer() }
                    .keyboardShortcut(.cancelAction)
                Button(isEdit ? "Update Comment" : "Add Review Comment") { review.addComposerToReview() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .mainAction(isDisabled: isEmpty)
            }
        }
        .padding(ReviewMetrics.cardPadding)
        .card()
        .onAppear { isFocused = true }
    }
}

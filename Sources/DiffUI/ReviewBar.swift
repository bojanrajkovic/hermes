import GitHubKit
import HermesUI
import SwiftUI

/// The pending review in the summary bar: how many comments wait, and the button that finishes the review.
struct ReviewBar: View {
    let review: ReviewModel
    @State private var isFinishing = false

    var body: some View {
        if review.reanchoring != nil {
            Label("Click a line's + to move the draft there", systemImage: "arrow.turn.down.right")
            Button("Cancel") { review.reanchoring = nil }
                .controlSize(.small)
        } else {
            let count = review.pending.comments.count
            if let error = review.threadsError {
                Label("Couldn't load comments", systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.secondary)
                    .help(error)
            }
            if count > 0 {
                Label("\(count) pending", systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .help("Comments that are sent when you finish the review")
            }
            Button("Finish Review") { isFinishing = true }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .popover(isPresented: $isFinishing, arrowEdge: .bottom) {
                    FinishReview(review: review) { isFinishing = false }
                }
        }
    }
}

/// The popover that submits the review: a summary, a verdict, and one Submit button.
struct FinishReview: View {
    let review: ReviewModel
    let close: () -> Void
    @State private var event = ReviewSubmission.Event.comment

    var body: some View {
        @Bindable var review = review
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish Your Review").font(.headline)
            TextEditor(text: $review.summary)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
                .overlay(alignment: .topLeading) {
                    if review.summary.isEmpty {
                        Text("Leave a summary (Markdown)")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Review summary")

            VStack(alignment: .leading, spacing: 8) {
                option(.comment, "Comment", "bubble.left", "Send feedback without a verdict.")
                option(.approve, "Approve", "checkmark.circle", "Send feedback and approve merging.")
                option(.requestChanges, "Request Changes", "exclamationmark.octagon", "Send feedback that must be addressed before merging.")
                if review.isOwnPullRequest {
                    Text("You can't approve or request changes on your own pull request.")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            footnotes
            HStack {
                if review.submission == .sending {
                    ProgressView().controlSize(.small)
                    Text("Submitting…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Submit Review") {
                    Task { if await review.submit(event) { close() } }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .mainAction(isDisabled: !review.canSubmit(event))
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    @ViewBuilder private var footnotes: some View {
        let sending = review.layout.submittable.count
        let outdated = review.layout.outdatedDrafts.count
        VStack(alignment: .leading, spacing: 4) {
            Label(
                sending == 0 ? "No pending comments." : "^[\(sending) pending comment](inflect: true) will be posted.",
                systemImage: "clock"
            )
            if outdated > 0 {
                Label(
                    "^[\(outdated) outdated draft](inflect: true) will stay on this Mac, unsent.",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            if case .failed(let message) = review.submission {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing was sent. Your comments are still pending.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func option(_ value: ReviewSubmission.Event, _ title: String, _ symbol: String, _ detail: String) -> some View {
        let isDisabled = value != .comment && review.isOwnPullRequest
        return Button {
            event = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: event == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(event == value ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Label {
                        Text(title)
                    } icon: {
                        // One width for every symbol, so the three titles line up.
                        Image(systemName: symbol).frame(width: 18)
                    }
                    Text(detail)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .accessibilityAddTraits(event == value ? .isSelected : [])
    }
}

/// The toolbar button for comments that have no line in the diff: outdated
/// drafts, and threads GitHub marks outdated or that sit outside every hunk.
struct OffDiffButton: View {
    let review: ReviewModel
    @State private var isShown = false

    var body: some View {
        let count = review.layout.offDiffThreads.count + review.layout.outdatedDrafts.count
        Button {
            isShown = true
        } label: {
            Label(count == 0 ? "Outdated Comments" : "Outdated Comments (\(count))", systemImage: "clock.arrow.circlepath")
                .labelStyle(.titleAndIcon)
        }
        .help("Show comments and drafts whose lines are no longer in the diff")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            OffDiffList(review: review) { isShown = false }
        }
    }
}

struct OffDiffList: View {
    let review: ReviewModel
    let close: () -> Void

    var body: some View {
        let drafts = review.layout.outdatedDrafts
        let threads = review.layout.offDiffThreads
        if drafts.isEmpty, threads.isEmpty {
            ContentUnavailableView(
                "No Outdated Comments", systemImage: "checkmark.bubble",
                description: Text("Every comment and draft has a line in the diff.")
            )
            .frame(width: 360, height: 220)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !drafts.isEmpty {
                        Text("Outdated Drafts").font(.headline)
                        Text("Their lines are no longer in the diff. They are not sent until you move them to a line.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(drafts) { draft in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(verbatim: location(of: draft))
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    if draft.anchor != nil {
                                        Button("Move to a Line…") {
                                            review.reanchoring = draft.id
                                            close()
                                        }
                                        .controlSize(.small)
                                    }
                                }
                                DraftView(draft: draft, review: review)
                            }
                        }
                    }
                    if !threads.isEmpty {
                        Text("Outdated Threads").font(.headline)
                        ForEach(threads) { thread in
                            ThreadView(thread: thread, review: review, showsLocation: true)
                        }
                    }
                }
                .padding(16)
            }
            .frame(width: 480)
            .frame(maxHeight: 560)
        }
    }

    private func location(of draft: DraftComment) -> String {
        draft.anchor.map { "\($0.path), \(lineRangeLabel($0))" } ?? "Reply to a thread that no longer exists"
    }
}

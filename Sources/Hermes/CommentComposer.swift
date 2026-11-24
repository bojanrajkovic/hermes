import GitHubKit
import HermesUI
import StateKit
import SwiftUI

/// A box at the end of a pull request's or an issue's conversation for a comment that is not
/// part of a review.
///
/// Unsent text is saved in the item's drafts folder (`Drafts`) as it changes, so it survives
/// switching items and quitting. The file is removed once the text is sent or emptied. The text
/// loads when the view appears, so callers give each item its own view with `.id(key)`.
struct CommentComposer: View {
    let key: ItemKey
    /// The node ID of the pull request or issue.
    let subjectID: String
    @Environment(WindowModel.self) private var model
    @State private var text = ""
    @State private var isSending = false
    @State private var failure: String?

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .commentEditor(placeholder: "Leave a comment", isEmpty: text.isEmpty)
                .frame(minHeight: Theme.composerMinHeight, maxHeight: Theme.composerMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(isSending)
                .accessibilityLabel("New comment")
            HStack {
                Text("Markdown · ⌘↩ comments")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSending { ProgressView().controlSize(.small) }
                Button("Comment", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .mainAction(isDisabled: isEmpty || isSending)
            }
        }
        .onAppear { text = Drafts.comment(key: key) }
        // shortcut: writes on the main thread at each keystroke; fine for a comment's few KB.
        .onChange(of: text) { try? Drafts.saveComment(text, key: key) }
        .alert("Could Not Comment", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func send() {
        let sent = text
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await model.github.addComment(sent, subjectID: subjectID, to: key)
                text = ""
                // This view may be gone if the user moved on while it sent. Remove the saved text
                // unless a new view for this item has saved something else since.
                if Drafts.comment(key: key) == sent { try? Drafts.saveComment("", key: key) }
            } catch {
                failure = describe(error)
            }
        }
    }
}

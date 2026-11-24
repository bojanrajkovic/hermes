import GitHubKit
import HermesUI
import SwiftUI

/// A box at the end of a pull request's or an issue's conversation for a comment that is not
/// part of a review.
///
/// Unsent text is kept in UserDefaults, one key per item, so it survives switching items and
/// quitting. The key is removed once the text is sent or emptied. `@AppStorage` keeps the key it
/// was made with, so callers give each item its own view with `.id(key)`.
struct CommentComposer: View {
    let key: ItemKey
    /// The node ID of the pull request or issue.
    let subjectID: String
    @Environment(WindowModel.self) private var model
    @AppStorage private var text: String
    @State private var isSending = false
    @State private var failure: String?

    init(key: ItemKey, subjectID: String) {
        self.key = key
        self.subjectID = subjectID
        _text = AppStorage(wrappedValue: "", Self.defaultsKey(key))
    }

    static func defaultsKey(_ key: ItemKey) -> String { "comment.\(key.repository)#\(key.number)" }

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
        .onChange(of: text) {
            if text.isEmpty { UserDefaults.standard.removeObject(forKey: Self.defaultsKey(key)) }
        }
        .alert("Could Not Comment", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func send() {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await model.github.addComment(text, subjectID: subjectID, to: key)
                text = ""
                // This view may be gone if the user moved on while it sent, so remove the key here too.
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey(key))
            } catch {
                failure = describe(error)
            }
        }
    }
}

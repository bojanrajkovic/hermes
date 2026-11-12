import GitHubKit
import SwiftUI

/// Asks for a GitHub or `hermes://` link and opens it in a new window.
struct OpenLinkSheet: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var url: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed).flatMap { DeepLink(url: $0) == nil ? nil : $0 }
    }

    var body: some View {
        Form {
            TextField("Link", text: $text, prompt: Text(verbatim: "https://github.com/owner/repo/pull/12"))
            Text("A github.com or hermes:// link to a repository, pull request, issue, or stack.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Open") {
                    guard let url else { return }
                    dismiss()
                    model.openWindow(showing: url)
                }
                .disabled(url == nil)
            }
        }
        // A link on the clipboard is most likely the one to open.
        .onAppear {
            if let copied = NSPasteboard.general.string(forType: .string), let url = URL(string: copied.trimmingCharacters(in: .whitespacesAndNewlines)),
               DeepLink(url: url) != nil
            {
                text = url.absoluteString
            }
        }
    }
}

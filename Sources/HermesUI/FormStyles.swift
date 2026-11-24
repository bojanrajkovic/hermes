import SwiftUI

extension View {
    /// Styles a form's main button: prominent while it can be pressed.
    ///
    /// A disabled prominent button keeps its filled bezel and still reads as
    /// the thing to press, so a disabled one is drawn as an ordinary button.
    @ViewBuilder public func mainAction(isDisabled: Bool) -> some View {
        if isDisabled {
            buttonStyle(.bordered).disabled(true)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Styles a `TextEditor` for writing a comment: body text inset in a bordered box, with
    /// `placeholder` shown while `isEmpty`. Give the result its frame: the editor fills it.
    public func commentEditor(placeholder: String? = nil, isEmpty: Bool = false) -> some View {
        font(.body)
            .scrollContentBackground(.hidden)
            .padding(Theme.editorInset)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.editorCornerRadius))
            .overlay { RoundedRectangle(cornerRadius: Theme.editorCornerRadius).strokeBorder(.separator) }
            .overlay(alignment: .topLeading) {
                if let placeholder, isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        // The text view insets its first character 5 points past its own edge.
                        .padding(.horizontal, Theme.editorInset + 5)
                        .padding(.vertical, Theme.editorInset)
                        .allowsHitTesting(false)
                }
            }
    }
}

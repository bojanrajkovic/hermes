import SwiftUI

/// A find bar's search field, match count, and previous and next buttons. ⌘G and ⇧⌘G step through the matches, and Return moves to the next one.
public struct FindField: View {
    private let prompt: String
    @Binding private var query: String
    private let matchCount: Int
    /// The zero-based index of the match on screen, if any.
    private let current: Int?
    private let isFocused: FocusState<Bool>.Binding
    private let step: (Int) -> Void
    private let exit: () -> Void

    /// - Parameters:
    ///   - step: Moves to the next match for `1` and the previous one for `-1`.
    ///   - exit: Runs when Escape is pressed in the field.
    public init(
        _ prompt: String, query: Binding<String>, matchCount: Int, current: Int?, isFocused: FocusState<Bool>.Binding,
        step: @escaping (Int) -> Void, exit: @escaping () -> Void
    ) {
        self.prompt = prompt
        _query = query
        self.matchCount = matchCount
        self.current = current
        self.isFocused = isFocused
        self.step = step
        self.exit = exit
    }

    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
                    .focused(isFocused)
                    .onSubmit { step(1) }
                    .onExitCommand(perform: exit)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .frame(width: Theme.findFieldWidth)

            if !query.isEmpty {
                Text(countText)
                    .font(Theme.Fonts.meta.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            ControlGroup {
                Button { step(-1) } label: { Label("Previous Match", systemImage: "chevron.up") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Previous match (⇧⌘G)")
                Button { step(1) } label: { Label("Next Match", systemImage: "chevron.down") }
                    .keyboardShortcut("g", modifiers: .command)
                    .help("Next match (⌘G)")
            }
            .labelStyle(.iconOnly)
            .disabled(matchCount == 0)
            .fixedSize()
        }
    }

    private var countText: String {
        guard matchCount > 0 else { return "No matches" }
        return "\((current ?? 0) + 1) of \(matchCount)"
    }
}

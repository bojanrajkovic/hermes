import GitHubKit
import HermesUI
import SwiftUI

/// The ⌘K panel: a search field over keyboard-driven results, floating above
/// the window's content.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var query: String
    @State private var selected: PaletteAction?
    @FocusState private var isFocused: Bool

    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        let items = paletteItems(for: query, in: model.paletteContext)
        let current = items.first { $0.action == selected } ?? items.first

        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { model.isPaletteShown = false }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Repository, pull request, issue, repo#123, or command", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .onSubmit { if let current { run(current) } }
                        .onKeyPress(.downArrow) { move(1, in: items, from: current) }
                        .onKeyPress(.upArrow) { move(-1, in: items, from: current) }
                        .onKeyPress(.escape) {
                            model.isPaletteShown = false
                            return .handled
                        }
                        .accessibilityLabel("Command palette")
                }
                .font(.title3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                if items.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(items) { item in
                                    PaletteRow(item: item, isSelected: item.id == current?.id)
                                        .id(item.id)
                                        .onTapGesture { run(item) }
                                }
                            }
                            .padding(6)
                        }
                        .frame(height: min(CGFloat(items.count) * PaletteRow.height + 12, 380))
                        .onChange(of: current?.id) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }

                Divider()
                HStack(spacing: 14) {
                    Keycap("↑↓", "to move")
                    Keycap("↩", "to open")
                    Keycap("esc", "to close")
                    Spacer()
                    Text(verbatim: "repo#123 opens any pull request or issue")
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(width: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 90)
        }
        // After the first render: focus set while the overlay is being inserted is dropped.
        .task {
            // An AppKit view that holds the keyboard (a terminal, a web view) does not give it up to SwiftUI focus.
            NSApp.keyWindow?.makeFirstResponder(nil)
            isFocused = true
        }
        .onChange(of: query) { selected = nil }
    }

    private var emptyText: String {
        if case .reference(nil, let number) = PaletteQuery(query) {
            "No repository is open. Type a repository first, such as airway#\(number)."
        } else {
            "No matches"
        }
    }

    private func move(_ offset: Int, in items: [PaletteItem], from current: PaletteItem?) -> KeyPress.Result {
        guard let current, let index = items.firstIndex(of: current) else { return .handled }
        selected = items[min(max(index + offset, 0), items.count - 1)].action
        return .handled
    }

    private func run(_ item: PaletteItem) {
        model.isPaletteShown = false
        switch item.action {
        case .show(let destination):
            model.navigate(to: destination, tab: .files)
        case .repository(let repository):
            model.reveal(repository)
        case .open(let key):
            Task { await model.open(key) }
        case .account(let login):
            if let account = model.viewer?.accounts.first(where: { $0.login == login }) { model.select(account) }
        case .refresh:
            Task { await model.refresh() }
        case .toggleBots:
            model.showingAllBots.toggle()
        case .settings:
            openSettings()
        }
    }
}

private struct PaletteRow: View {
    static let height: CGFloat = 30
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(item.subtitle)
                .font(Theme.Fonts.meta)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct Keycap: View {
    let key: String
    let label: String

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }
}

extension AppModel {
    var paletteContext: PaletteContext {
        PaletteContext(
            repositories: sections.map(\.ref),
            pullRequests: pullRequests,
            issues: issueLists.flatMap { repository, list in list.items.map { (repository, $0) } },
            sessions: sessions.sessions.map {
                PaletteContext.Session(id: $0.id, title: $0.title, subtitle: "\($0.origin.repository.name)#\($0.origin.number)")
            },
            accounts: viewer?.accounts ?? [],
            currentAccount: account?.login,
            currentRepository: currentRepository,
            showingAllBots: showingAllBots
        )
    }

    /// Lists a repository in the middle column.
    func reveal(_ repository: RepositoryRef) {
        show(.repository(repository))
        scroll(to: repository)
    }
}

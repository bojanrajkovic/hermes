import HermesUI
import SwiftUI
import SyntaxKit

/// The pane under the diff that shows where an identifier is defined.
struct DefinitionPane: View {
    let model: DiffModel
    @Environment(\.openURL) private var openURL

    private var definitions: DefinitionModel { model.definitions }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button("Back", systemImage: "chevron.left") { definitions.goBack() }
                    .disabled(!definitions.canGoBack)
                    .help("Show the previous definition")
                Button("Forward", systemImage: "chevron.right") { definitions.goForward() }
                    .disabled(!definitions.canGoForward)
                    .help("Show the next definition")
            }
            .fixedSize()

            if let page = definitions.current {
                Text(verbatim: page.name)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(1)
                if case .file(let location, _) = page.phase {
                    Text(verbatim: "\(location.path):\(location.line + 1)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if case .file(let location, _) = definitions.current?.phase {
                if let row = model.diffRow(for: location) {
                    Button("Show in Diff", systemImage: "arrow.up.to.line") { model.reveal(row, symbol: definitions.current?.name) }
                        .help("Scroll the diff to this line")
                }
                if let url = model.gitHubURL(for: location) {
                    Button("Open on GitHub", systemImage: "arrow.up.forward.square") { openURL(url) }
                        .labelStyle(.iconOnly)
                        .help("Open this line on GitHub at the pull request's head commit")
                }
            }
            Button("Close", systemImage: "xmark") { definitions.isOpen = false }
                .labelStyle(.iconOnly)
                .help("Close the Definition Pane")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, DiffMetrics.headerPaddingHorizontal)
        .padding(.vertical, DiffMetrics.headerPaddingVertical)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        switch definitions.current?.phase {
        case .searching(let status):
            ProgressView(status)
        case .message(let title, let detail):
            ContentUnavailableView(title, systemImage: "questionmark.circle", description: Text(detail))
        case .choices(let locations):
            if let page = definitions.current {
                DefinitionChooser(name: page.name, locations: locations) { definitions.open($0, name: page.name) }
            }
        case .file(let location, let file):
            CodeFileView(file: file, location: location)
                // A new page starts at its own line, not where the last one was scrolled to.
                .id(definitions.current?.id)
        case nil:
            ContentUnavailableView(
                "No Definition", systemImage: "arrow.turn.down.right",
                description: Text("Click an identifier in the diff to see where it is defined.")
            )
        }
    }
}

extension DefinitionKind {
    var label: String {
        switch self {
        case .function: "Function"
        case .method: "Method"
        case .type: "Type"
        case .constant: "Constant"
        case .variable: "Variable"
        case .property: "Property"
        case .module: "Module"
        }
    }

    var symbol: String {
        switch self {
        case .function, .method: "function"
        case .type: "t.square"
        case .constant: "c.square"
        case .variable: "v.square"
        case .property: "p.square"
        case .module: "shippingbox"
        }
    }
}

/// The list to pick from when a name has several definitions.
private struct DefinitionChooser: View {
    let name: String
    let locations: [DefinitionLocation]
    let open: (DefinitionLocation) -> Void
    @Environment(\.diffMetrics) private var metrics

    var body: some View {
        List {
            Section("\(locations.count) definitions of “\(name)”") {
                ForEach(locations) { location in
                    Button {
                        open(location)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Label(location.kind.label, systemImage: location.kind.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 96, alignment: .leading)
                                Text(verbatim: "\(location.path):\(location.line + 1)")
                                    .truncationMode(.middle)
                            }
                            .font(.callout)
                            Text(verbatim: location.lineText.trimmingCharacters(in: .whitespaces))
                                .font(metrics.font)
                                .foregroundStyle(.secondary)
                                .truncationMode(.tail)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

/// A whole file, scrolled to the definition's line, which is marked.
private struct CodeFileView: View {
    let file: CodeFile
    let location: DefinitionLocation

    var body: some View {
        let digits = max(3, String(file.lines.count).count)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.lines) { line in
                        CodeFileLine(line: line, path: location.path, digits: digits, isMarked: line.id == location.line)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { proxy.scrollTo(location.line, anchor: .center) }
        }
    }
}

private struct CodeFileLine: View {
    let line: CodeFile.Line
    let path: String
    let digits: Int
    let isMarked: Bool
    @State private var isHovered = false
    @Environment(\.diffMetrics) private var metrics

    var body: some View {
        let number = String(line.id + 1)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // The arrow marks the line for readers who can't tell the tint apart.
            Text(verbatim: (isMarked ? "▸" : " ") + String(repeating: " ", count: max(digits - number.count, 0)) + number + "  ")
                .foregroundStyle(isMarked ? .primary : .secondary)
                .accessibilityLabel(isMarked ? "Line \(number), the definition" : "Line \(number)")
            CodeText(text: line.text, source: line.source, path: path, identifiers: line.identifiers, isHovered: isHovered)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(metrics.font)
        .padding(.horizontal, DiffMetrics.gutterPadding)
        .padding(.vertical, DiffMetrics.rowPadding)
        .background(isMarked ? Color.accentColor.opacity(0.18) : .clear)
        .onHover { isHovered = $0 }
    }
}

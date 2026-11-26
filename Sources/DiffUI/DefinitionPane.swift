import HermesUI
import SwiftUI
import SyntaxKit

/// Where an identifier is defined, or a whole file: in the pane under the
/// diff, or in the popover over the identifier that was clicked.
struct DefinitionPane: View {
    enum Style {
        case pane
        /// In a popover. `openInPane` moves the page on screen into the pane and closes the popover.
        case popover(openInPane: () -> Void)
    }

    let model: DiffModel
    let definitions: DefinitionModel
    let style: Style
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        // Identifiers clicked in this view are looked up in this view.
        .environment(definitions)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button("Back", systemImage: "chevron.left") { definitions.goBack() }
                    .disabled(!definitions.canGoBack)
                    .help("Show the previous page")
                Button("Forward", systemImage: "chevron.right") { definitions.goForward() }
                    .disabled(!definitions.canGoForward)
                    .help("Show the next page")
            }
            .fixedSize()

            if let page = definitions.current {
                Text(verbatim: page.name)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(1)
                if case .file(let path, let line, _) = page.phase {
                    Text(verbatim: "\(path):\(line + 1)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if case .file(let path, let line, _) = definitions.current?.phase {
                if let row = model.diffRow(path: path, line: line) {
                    Button("Show in Diff", systemImage: "arrow.up.to.line") { model.reveal(row, symbol: definitions.current?.name) }
                        .help("Scroll the diff to this line")
                }
                if let url = model.gitHubURL(path: path, line: line) {
                    Button("Open on GitHub", systemImage: "arrow.up.forward.square") { openURL(url) }
                        .labelStyle(.iconOnly)
                        .help("Open this line on GitHub at the pull request's head commit")
                }
            }
            switch style {
            case .pane:
                Button("Close", systemImage: "xmark") { definitions.isOpen = false }
                    .labelStyle(.iconOnly)
                    .help("Close the Definition Pane")
            case .popover(let openInPane):
                Button("Open in Pane", systemImage: "rectangle.bottomhalf.inset.filled", action: openInPane)
                    .labelStyle(.iconOnly)
                    .disabled(definitions.current.map { if case .searching = $0.phase { true } else { false } } ?? true)
                    .help("Open in the Definition Pane")
            }
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
                DefinitionChooser(name: page.name, locations: locations) {
                    definitions.open(path: $0.path, line: $0.line, name: page.name)
                }
            }
        case .references(let locations, let isTruncated):
            if let page = definitions.current {
                ReferenceList(name: page.name, locations: locations, isTruncated: isTruncated) {
                    definitions.open(path: $0.path, line: $0.line, name: page.name)
                }
            }
        case .file(let path, let line, let file):
            CodeFileView(file: file, path: path, line: line)
                // A new page starts at its own line, not where the last one was scrolled to.
                .id(definitions.current?.id)
        case nil:
            ContentUnavailableView(
                "No Definition", systemImage: "arrow.turn.down.right",
                description: Text("Click an identifier to see where it is defined, or ⌘-click it to see where it is used.")
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

/// The lines that use a name, grouped under a header for each file.
private struct ReferenceList: View {
    let name: String
    let locations: [ReferenceLocation]
    let isTruncated: Bool
    let open: (ReferenceLocation) -> Void
    @Environment(\.diffMetrics) private var metrics

    var body: some View {
        // Each file's lines are adjacent in `locations`, so a location only joins the last group or starts one.
        let files = locations.reduce(into: [(path: String, lines: [ReferenceLocation])]()) { files, location in
            if files.last?.path == location.path { files[files.count - 1].lines.append(location) }
            else { files.append((location.path, [location])) }
        }
        List {
            Text(summary(files: files.count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
            ForEach(files, id: \.path) { file in
                Section {
                    ForEach(file.lines) { location in
                        Button {
                            open(location)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: String(location.line + 1))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(minWidth: 32, alignment: .trailing)
                                Text(verbatim: location.lineText.trimmingCharacters(in: .whitespaces))
                                    .truncationMode(.tail)
                            }
                            .font(metrics.font)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel("Line \(location.line + 1): \(location.lineText)")
                    }
                } header: {
                    Text(verbatim: file.path)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func summary(files: Int) -> String {
        let uses = locations.count == 1 ? "1 line uses" : "\(locations.count) lines use"
        let place = files == 1 ? "1 file" : "\(files) files"
        let found = "\(uses) “\(name)” in \(place)."
        return isTruncated ? found + " The search stopped early, so there may be more uses." : found
    }
}

/// A whole file, scrolled to a line, which is marked.
private struct CodeFileView: View {
    let file: CodeFile
    let path: String
    /// Zero-based.
    let line: Int

    var body: some View {
        let digits = max(3, String(file.lines.count).count)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.lines) { line in
                        CodeFileLine(line: line, path: path, digits: digits, isMarked: line.id == self.line)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { proxy.scrollTo(line, anchor: .center) }
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
                .accessibilityLabel(isMarked ? "Line \(number), marked" : "Line \(number)")
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

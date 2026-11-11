import AppKit
import DiffKit
import HermesUI
import SwiftUI

/// The screen for a loaded model: its loading, error, and empty states, or the navigator beside the list.
struct DiffContent: View {
    let model: DiffModel

    private var diffColumn: some View {
        VStack(spacing: 0) {
            SummaryBar(model: model)
            Divider()
            VSplitView {
                DiffList(model: model)
                    .frame(minHeight: DiffMetrics.listMinHeight)
                if model.definitions.isOpen {
                    DefinitionPane(model: model)
                        .frame(minHeight: DiffMetrics.paneMinHeight, idealHeight: DiffMetrics.paneIdealHeight)
                }
            }
        }
    }

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load the Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        case .loaded where model.files.isEmpty:
            ContentUnavailableView(
                "No Changes", systemImage: "checkmark.circle",
                description: Text("There is nothing to compare yet.")
            )
        case .loaded:
            // A narrow pane, such as the one beside a session's terminal, has no room for the file list.
            GeometryReader { proxy in
                if proxy.size.width >= Theme.sidebarMinWidth + DiffMetrics.listMinWidth {
                    HSplitView {
                        FileNavigator(model: model)
                            .frame(
                                minWidth: Theme.sidebarMinWidth, idealWidth: Theme.sidebarIdealWidth,
                                maxWidth: Theme.sidebarMaxWidth
                            )
                        diffColumn
                            .frame(minWidth: DiffMetrics.listMinWidth, maxWidth: .infinity)
                    }
                } else {
                    diffColumn
                }
            }
            .environment(model.review)
            .environment(model.definitions)
            .modifier(DiscardConfirmation(review: model.review))
        }
    }
}

/// `+12 −3`. The signs carry the meaning; the colors repeat it.
struct ChangeCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "+\(additions)").foregroundStyle(DiffColors.addedText)
            Text(verbatim: "−\(deletions)").foregroundStyle(DiffColors.removedText)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }
}

/// The icon for what happened to a file. Each kind has its own shape.
struct ChangeIcon: View {
    let change: FileChange

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .help(label)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch change {
        case .added: "plus.square.fill"
        case .deleted: "minus.square.fill"
        case .modified: "dot.square.fill"
        case .renamed: "arrow.right.square.fill"
        case .copied: "plus.square.on.square.fill"
        }
    }

    private var label: String {
        switch change {
        case .added: "Added"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .copied: "Copied"
        }
    }

    private var tint: Color {
        switch change {
        case .added: DiffColors.addedText
        case .deleted: DiffColors.removedText
        case .modified: .orange
        case .renamed: .blue
        case .copied: .teal
        }
    }
}

/// Files changed, total additions and deletions, and whether the diff was just refreshed.
struct SummaryBar: View {
    let model: DiffModel

    var body: some View {
        HStack(spacing: 10) {
            Text("^[\(model.files.count) file](inflect: true) changed")
            ChangeCounts(additions: model.additions, deletions: model.deletions)
            if model.viewedCount > 0 {
                Text("\(model.viewedCount) of \(model.files.count) viewed")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let error = model.refreshError {
                Label("Couldn't refresh", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(error)
            }
            UpdatedIndicator(updatedAt: model.updatedAt)
            if let review = model.review { ReviewBar(review: review) }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: DiffMetrics.barHeight)
        .background(.bar)
    }
}

/// Says "Updated" for a few seconds after a reload changed the diff.
private struct UpdatedIndicator: View {
    let updatedAt: Date?
    @State private var isVisible = false

    var body: some View {
        // Always in the tree; only its opacity changes (SWIFTUI-RULES 1.1).
        Label("Updated", systemImage: "arrow.triangle.2.circlepath")
            .foregroundStyle(.secondary)
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(!isVisible)
            .animation(.easeOut(duration: 0.3), value: isVisible)
            .task(id: updatedAt) {
                guard updatedAt != nil else { return }
                isVisible = true
                try? await Task.sleep(for: .seconds(4))
                isVisible = false
            }
    }
}

/// Every file in one scroll, with the file headers pinned to the top.
struct DiffList: View {
    let model: DiffModel
    @Environment(\.diffMetrics) private var metrics

    var body: some View {
        // The table does not observe the models. Reading the rows and the
        // scroll request here makes SwiftUI update it when they change.
        DiffTableView(
            model: model, rows: tableRows(files: model.files, attached: model.review?.attachedLines ?? [:]), metrics: metrics,
            request: model.scroll.request
        )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.hasRenderedDock { RenderedCommentDock(model: model) }
            }
    }
}

/// The sticky bar above a file: path, counts, and the file's actions.
struct FileHeader: View {
    let file: FileModel
    let model: DiffModel
    let gitHubURL: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            Button(file.isCollapsed ? "Expand File" : "Collapse File", systemImage: "chevron.right") {
                file.isCollapsed.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .rotationEffect(.degrees(file.isCollapsed ? 0 : 90))
            .help(file.isCollapsed ? "Expand File" : "Collapse File")

            ChangeIcon(change: file.diff.change)
            path
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            ChangeCounts(additions: file.diff.additions, deletions: file.diff.deletions)
                .font(Theme.Fonts.meta)

            Spacer(minLength: 8)

            if file.isMarkdown {
                Picker("Markdown", selection: Binding { file.showsRendered } set: { model.setRendered($0, for: file) }) {
                    Text("Source").tag(false)
                    Text("Rendered").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Show the Markdown source or the rendered document")
            }
            Button("Copy Path", systemImage: "doc.on.doc", action: copyPath)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy Path")
            if let gitHubURL {
                Button("Open on GitHub", systemImage: "arrow.up.forward.square") { openURL(gitHubURL) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open on GitHub")
            }
            Toggle("Viewed", isOn: Binding { file.isViewed } set: { file.setViewed($0) })
                .toggleStyle(.checkbox)
                .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, DiffMetrics.headerPaddingHorizontal)
        .padding(.vertical, DiffMetrics.headerPaddingVertical)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .top) { Divider() }
        .contextMenu {
            Button("Copy Path", action: copyPath)
            if let gitHubURL {
                Button("Open on GitHub") { openURL(gitHubURL) }
            }
            Divider()
            Button(file.isViewed ? "Mark as Unviewed" : "Mark as Viewed") { file.setViewed(!file.isViewed) }
            Button(file.isCollapsed ? "Expand File" : "Collapse File") { file.isCollapsed.toggle() }
        }
    }

    private var path: Text {
        switch file.diff.change {
        case .renamed(let from, let to), .copied(let from, let to):
            Text("\(Text(verbatim: from).foregroundStyle(.secondary)) → \(Self.styled(to))")
        case .added(let path), .deleted(let path), .modified(let path):
            Self.styled(path)
        }
    }

    /// The directory in the secondary color and the file name in semibold.
    private static func styled(_ path: String) -> Text {
        guard let slash = path.lastIndex(of: "/") else { return Text(verbatim: path).fontWeight(.semibold) }
        let directory = Text(verbatim: String(path[...slash])).foregroundStyle(.secondary)
        let name = Text(verbatim: String(path[path.index(after: slash)...])).fontWeight(.semibold)
        return Text("\(directory)\(name)")
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.diff.path, forType: .string)
    }
}

/// Asks before the comment being written is thrown away.
private struct DiscardConfirmation: ViewModifier {
    let review: ReviewModel?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Discard this comment?",
            isPresented: Binding { review?.discardRequest != nil } set: { if !$0 { review?.discardRequest = nil } }
        ) {
            Button("Discard Comment", role: .destructive) { review?.confirmDiscard() }
            Button("Keep Editing", role: .cancel) { review?.discardRequest = nil }
        } message: {
            Text("The text you wrote has not been added to your review.")
        }
    }
}

import DiffKit
import HermesUI
import SwiftUI

/// The changed files as a directory tree. Selecting a file scrolls the list to it.
struct FileNavigator: View {
    let model: DiffModel
    @State private var filter = ""
    @State private var collapsed: Set<FileTreeNode.ID> = []

    var body: some View {
        let files = model.files.filter { pathMatches($0.diff.path, filter: filter) }
        VStack(spacing: 0) {
            filterField
            Divider()
            if files.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                FileTreeList(
                    nodes: fileTree(files.map { ($0.id, $0.diff.path) }),
                    files: Dictionary(files.map { ($0.id, $0) }) { first, _ in first },
                    model: model,
                    scroll: model.scroll,
                    collapsed: $collapsed
                )

            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter files", text: $filter)
                .textFieldStyle(.plain)
            if !filter.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle.fill") { filter = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: DiffMetrics.barHeight)
    }
}

/// The tree itself. It is the only navigator view that reads the current
/// file, so scrolling the diff from file to file does not rebuild the tree.
private struct FileTreeList: View {
    let nodes: [FileTreeNode]
    let files: [FileDiff.ID: FileModel]
    let model: DiffModel
    let scroll: DiffScrollState
    @Binding var collapsed: Set<FileTreeNode.ID>

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                FileTreeRows(nodes: nodes, files: files, model: model, collapsed: $collapsed)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            // Keep the current file's row in view as the diff scrolls.
            .onChange(of: scroll.currentFile) { _, file in
                if let file { proxy.scrollTo(file) }
            }
        }
    }

    /// The selection follows the diff's scroll position, and setting it scrolls the diff.
    private var selection: Binding<FileDiff.ID?> {
        Binding {
            scroll.currentFile
        } set: { id in
            if let id { scroll.scroll(to: id) }
        }
    }
}

/// One row per visible node, indented by depth. Not nested `DisclosureGroup`s:
/// in an inset list those drew rows in the wrong places.
private struct FileTreeRows: View {
    let nodes: [FileTreeNode]
    let files: [FileDiff.ID: FileModel]
    let model: DiffModel
    @Binding var collapsed: Set<FileTreeNode.ID>

    var body: some View {
        ForEach(visibleRows(nodes, collapsed: collapsed)) { row in
            let node = row.node
            HStack(spacing: 2) {
                Button(isCollapsed(node) ? "Expand" : "Collapse", systemImage: "chevron.right") { toggle(node) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.small)
                    .rotationEffect(.degrees(isCollapsed(node) ? 0 : 90))
                    .frame(width: 14)
                    .opacity(node.children.isEmpty ? 0 : 1)
                    .accessibilityHidden(node.children.isEmpty)
                if let fileID = node.fileID, let file = files[fileID] {
                    FileNavigatorRow(name: node.name, file: file, model: model)
                } else {
                    Label(node.name, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .tag(node.fileID)
            .selectionDisabled(node.isDirectory)
            .listRowSeparator(.hidden)
        }
    }

    private func isCollapsed(_ node: FileTreeNode) -> Bool { collapsed.contains(node.id) }

    private func toggle(_ node: FileTreeNode) {
        if collapsed.remove(node.id) == nil { collapsed.insert(node.id) }
    }
}

private struct FileNavigatorRow: View {
    let name: String
    let file: FileModel
    let model: DiffModel

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                ChangeIcon(change: file.diff.change)
            }
            Spacer(minLength: 4)
            ChangeCounts(additions: file.diff.additions, deletions: file.diff.deletions)
                .font(Theme.Fonts.meta)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .opacity(file.isViewed ? 1 : 0)
                .accessibilityLabel("Viewed")
                .accessibilityHidden(!file.isViewed)
        }
        .help(file.diff.path)
        .contextMenu {
            Button(file.isViewed ? "Mark as Unviewed" : "Mark as Viewed") { model.setViewed(!file.isViewed, for: file) }
        }
    }
}

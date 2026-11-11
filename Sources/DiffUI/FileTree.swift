import DiffKit
import Foundation

/// A node of the file navigator's directory tree.
struct FileTreeNode: Identifiable, Hashable, Sendable {
    /// The full path, which is unique among a node's siblings and across the tree.
    let id: String
    /// What the row shows: a file name, or one or more directory names
    /// (`Sources/DiffUI`) when a directory's only child is another directory.
    let name: String
    /// The file's ID in the diff. `nil` for a directory.
    let fileID: FileDiff.ID?
    var children: [FileTreeNode]

    var isDirectory: Bool { fileID == nil }
}

/// The manifest a lock file is generated from, by file name.
let lockFileManifests: [String: String] = [
    "pnpm-lock.yaml": "package.json", "package-lock.json": "package.json", "npm-shrinkwrap.json": "package.json",
    "yarn.lock": "package.json", "bun.lock": "package.json", "bun.lockb": "package.json",
    "Cargo.lock": "Cargo.toml", "Gemfile.lock": "Gemfile", "go.sum": "go.mod",
    "uv.lock": "pyproject.toml", "poetry.lock": "pyproject.toml", "pdm.lock": "pyproject.toml",
    "Pipfile.lock": "Pipfile", "Package.resolved": "Package.swift", "composer.lock": "composer.json",
    "flake.lock": "flake.nix", "mix.lock": "mix.exs", "pubspec.lock": "pubspec.yaml",
    "Podfile.lock": "Podfile", "deno.lock": "deno.json",
]

/// Arranges changed files as a directory tree.
///
/// Nodes keep the order of `files`, except that a lock file moves under its
/// manifest when both changed in the same directory (`pnpm-lock.yaml` under
/// `package.json`). A chain of directories with a single child each is joined
/// into one node.
///
/// - Parameter files: Each file's ID and path, in diff order.
func fileTree(_ files: [(id: FileDiff.ID, path: String)]) -> [FileTreeNode] {
    var root = FileTreeNode(id: "", name: "", fileID: nil, children: [])
    for file in files {
        insert(file.id, components: file.path.split(separator: "/")[...], into: &root)
    }
    return nestingLockFiles(root.children).map(joiningChains)
}

private func nestingLockFiles(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
    var kept: [FileTreeNode] = []
    var locks: [String: [FileTreeNode]] = [:]
    let fileNames = Set(nodes.filter { !$0.isDirectory }.map(\.name))
    for var node in nodes {
        if !node.isDirectory, let manifest = lockFileManifests[node.name], fileNames.contains(manifest) {
            locks[manifest, default: []].append(node)
        } else {
            node.children = nestingLockFiles(node.children)
            kept.append(node)
        }
    }
    return kept.map { node in
        guard !node.isDirectory, let nested = locks[node.name] else { return node }
        var node = node
        node.children = nested
        return node
    }
}

private func insert(_ fileID: FileDiff.ID, components: ArraySlice<Substring>, into node: inout FileTreeNode) {
    guard let name = components.first.map(String.init) else { return }
    let path = node.id.isEmpty ? name : "\(node.id)/\(name)"
    if components.count == 1 {
        // A type change lists the same path twice; the file ID keeps the nodes apart.
        node.children.append(FileTreeNode(id: fileID, name: name, fileID: fileID, children: []))
        return
    }
    let index: Int
    if let existing = node.children.firstIndex(where: { $0.id == path && $0.isDirectory }) {
        index = existing
    } else {
        node.children.append(FileTreeNode(id: path, name: name, fileID: nil, children: []))
        index = node.children.count - 1
    }
    insert(fileID, components: components.dropFirst(), into: &node.children[index])
}

private func joiningChains(_ node: FileTreeNode) -> FileTreeNode {
    var node = node
    while node.isDirectory, node.children.count == 1, let child = node.children.first, child.isDirectory {
        node = FileTreeNode(id: child.id, name: "\(node.name)/\(child.name)", fileID: nil, children: child.children)
    }
    node.children = node.children.map(joiningChains)
    return node
}

/// Whether a file's path matches the navigator's filter. An empty filter matches everything.
func pathMatches(_ path: String, filter: String) -> Bool {
    let filter = filter.trimmingCharacters(in: .whitespaces)
    return filter.isEmpty || path.localizedCaseInsensitiveContains(filter)
}

/// A node as the navigator lists it.
struct FileTreeRow: Identifiable {
    let node: FileTreeNode
    let depth: Int
    var id: FileTreeNode.ID { node.id }
}

/// The tree top to bottom, without the children of collapsed nodes.
func visibleRows(_ nodes: [FileTreeNode], collapsed: Set<FileTreeNode.ID>, depth: Int = 0) -> [FileTreeRow] {
    nodes.flatMap { node in
        [FileTreeRow(node: node, depth: depth)]
            + (collapsed.contains(node.id) ? [] : visibleRows(node.children, collapsed: collapsed, depth: depth + 1))
    }
}

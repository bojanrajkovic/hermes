import DiffUI
import GitHubKit
import HermesUI
import RepoKit
import SessionsUI
import SwiftUI

/// One local branch that has no pull request: its changes against its parent
/// branch, read from the user's checkout. Read only.
struct LocalBranchScreen: View {
    let key: LocalBranchKey
    @Environment(WindowModel.self) private var model

    var body: some View {
        let entry = model.localStacks.entry(key.repository)
        Group {
            if let entry, let branch = entry.stacks.flatMap(\.branches).first(where: { $0.name == key.branch }) {
                VStack(spacing: 0) {
                    header(branch, checkout: entry.checkout)
                    Divider()
                    DiffScreen(source: .localBranch(checkout: entry.checkout, branch: branch), client: model.client, repoCache: model.repoCache)
                        .id(branch)
                }
            } else if model.localStacks.isLoaded(key.repository) {
                ContentUnavailableView(
                    "Branch Not Found", systemImage: "arrow.triangle.branch",
                    description: Text(verbatim: "\(key.branch) is no longer a stacked branch in your checkout of \(key.repository).")
                )
            } else {
                ProgressView()
            }
        }
        .task(id: key.repository) { await model.localStacks.load(key.repository) }
    }

    private func header(_ branch: LocalStack.Branch, checkout: Checkout) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(branch.name)
                .font(Theme.Fonts.paneHeading)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(verbatim: "← \(branch.parent)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Badge("Local")
                .help("No pull request has this branch as its head. The diff comes from \(checkout.directory.abbreviatedPath).")
            Spacer(minLength: 8)
            StackSwitcher()
        }
        .padding(.horizontal, Theme.detailInset)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// A repository's local branches, for the repository column: grouped under
/// the trunk they target, a stacked branch indented under its parent, each
/// with its pull request when it has one.
struct LocalStackRows: View {
    let repository: RepositoryRef
    @Environment(WindowModel.self) private var model

    var body: some View {
        let stacks = model.localStacks.entry(repository)?.stacks ?? []
        let trunks = stacks.map(\.trunk).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(trunks, id: \.self) { trunk in
            Label("Onto \(trunk)", systemImage: "arrow.triangle.branch")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .selectionDisabled()
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(.isHeader)
            ForEach(stacks.filter { $0.trunk == trunk }, id: \.self) { stack in
                ForEach(stack.branches, id: \.self) { branch in
                    row(branch, depth: depth(of: branch, in: stack))
                        .tag(model.destination(ofBranch: branch.name, in: repository))
                        .id(LocalBranchKey(repository: repository, branch: branch.name))
                }
            }
        }
    }

    private func row(_ branch: LocalStack.Branch, depth: Int) -> some View {
        let pullRequest = model.pullRequest(headedBy: branch.name, in: repository)
        return HStack(spacing: Theme.rowGlyphSpacing) {
            Text(branch.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let pullRequest {
                HStack(spacing: 4) {
                    StatusGlyph(StatusKind(pullRequest.checkState))
                    Text(verbatim: "#\(pullRequest.number)")
                }
                .font(Theme.Fonts.rowMeta)
                .foregroundStyle(.secondary)
            } else {
                Text("No pull request")
                    .font(Theme.Fonts.rowMeta)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * Theme.rowGlyphSpacing * 2)
        .padding(.vertical, Theme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    /// How many branches of the stack lie between this one and the trunk.
    private func depth(of branch: LocalStack.Branch, in stack: LocalStack) -> Int {
        var depth = 0
        var parent = branch.parent
        while let next = stack.branches.first(where: { $0.name == parent }) {
            depth += 1
            parent = next.parent
        }
        return depth
    }
}

import DiffUI
import GitHubKit
import HermesUI
import RepoKit
import SessionsUI
import SwiftUI

/// A Claude Code session: its terminal beside a live diff of what it changed.
struct SessionScreen: View {
    /// What the diff pane compares.
    enum DiffScope: Hashable {
        /// Everything in the session's worktree against its base.
        case workingTree
        /// One branch of the local stack against its parent.
        case branch(LocalStack.Branch)
    }

    let session: ClaudeSession
    @Environment(WindowModel.self) private var model
    @State private var checkout: Checkout?
    @State private var branches: [LocalStack.Branch] = []
    @State private var scope: DiffScope = .workingTree

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                SessionTerminalView(session: session)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                diff
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // The stack the session's branch is part of, read from the user's checkout.
            let origin = session.origin.repository
            guard let checkout = await model.sessions.checkout(for: RepoID(owner: origin.owner, name: origin.name)),
                  let stacks = try? await checkout.stacks() else { return }
            self.checkout = checkout
            branches = stacks.first { stack in stack.branches.contains { $0.name == session.branch } }?.branches ?? []
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SessionStateGlyph(state: session.state)
            Text(session.title)
                .font(Theme.Fonts.paneHeading)
                .lineLimit(1)
                .truncationMode(.tail)
            Badge(session.state == .running ? "Running" : "Exited")
            Button {
                Task { await model.open(session.origin.key) }
            } label: {
                Label {
                    Text(verbatim: "\(session.origin.repository.name)#\(session.origin.number)")
                } icon: {
                    Image(systemName: session.origin.isPullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                }
            }
            .help(session.origin.isPullRequest ? "Open the pull request this session started from" : "Open the issue this session started from")
            Spacer(minLength: 8)
            if !session.origin.isPullRequest, let pullRequest = model.linkedPullRequest(of: session) {
                Button {
                    model.navigate(to: .pullRequest(pullRequest.key), tab: .files)
                } label: {
                    HStack(spacing: 4) {
                        StatusGlyph(StatusKind(pullRequest.checkState))
                        Text(verbatim: "PR #\(pullRequest.number)")
                    }
                }
                .help("Open the pull request this session works on: \(pullRequest.title)")
            }
            if session.workingDirectory != nil {
                Picker("Diff", selection: $scope) {
                    Text("Working Tree").tag(DiffScope.workingTree)
                    if !branches.isEmpty {
                        Divider()
                        ForEach(branches, id: \.self) { branch in
                            Text(verbatim: "\(branch.name) ← \(branch.parent)").tag(DiffScope.branch(branch))
                        }
                    }
                }
                .fixedSize()
                .help("Choose what the diff shows: the working tree, or one branch of the local stack")
            }
        }
        .padding(.horizontal, Theme.detailInset)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var diff: some View {
        switch scope {
        case .branch(let branch):
            if let checkout {
                DiffScreen(source: .localBranch(checkout: checkout, branch: branch), client: model.client, repoCache: model.repoCache)
                    .id(branch)
            }
        case .workingTree:
            if let directory = session.workingDirectory, let baseRef = session.baseRef {
                DiffScreen(
                    source: .workingTree(directory: directory, baseRef: baseRef), client: model.client, repoCache: model.repoCache
                )
            } else {
                ContentUnavailableView(
                    "No Local Diff", systemImage: "cloud",
                    description: Text("This session does not run in a worktree on this Mac, so there are no local changes to show.")
                )
            }
        }
    }
}

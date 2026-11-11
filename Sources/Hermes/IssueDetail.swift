import AppKit
import GitHubKit
import HermesUI
import SessionsUI
import SwiftUI

struct IssueDetailView: View {
    let issue: Issue
    let repository: RepositoryRef
    @Environment(AppModel.self) private var model
    @State private var detail = Loader<IssueDetail>()

    private var key: ItemKey { ItemKey(repository: repository, number: issue.number) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.readingSectionSpacing) {
                    if let value = detail.value {
                        CommentCard(
                            author: issue.author, verb: "opened this issue", date: issue.createdAt,
                            markdown: value.body, baseURL: issue.url
                        )
                    } else if let error = detail.error {
                        ContentUnavailableView {
                            Label("Could Not Load the Issue", systemImage: "exclamationmark.bubble")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try Again") { detail.retry() }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading the issue…").foregroundStyle(.secondary)
                        }
                    }

                    let sessions = model.sessions(startedFrom: key, isPullRequest: false)
                    if !sessions.isEmpty {
                        PaneSection("Claude Sessions") {
                            ForEach(sessions) { SessionSummaryRow(session: $0) }
                        }
                    }

                    if !issue.linkedPullRequests.isEmpty {
                        PaneSection("Linked Pull Requests") {
                            ForEach(issue.linkedPullRequests, id: \.number) { LinkedPullRequestRow(linked: $0, repository: repository) }
                        }
                    }

                    if let comments = detail.value?.comments {
                        PaneSection(comments.count == 1 ? "1 Comment" : "\(comments.count) Comments") {
                            if comments.isEmpty {
                                Text("No comments yet.").foregroundStyle(.secondary)
                            }
                            ForEach(comments) { comment in
                                CommentCard(
                                    author: comment.author, verb: "commented", date: comment.createdAt,
                                    markdown: comment.body, baseURL: issue.url
                                )
                            }
                        }
                    }
                }
                .padding(Theme.detailInset)
                .frame(maxWidth: Theme.conversationMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: LoadID(updatedAt: issue.updatedAt, attempt: detail.attempt)) {
            await detail.load { try await model.client.issueDetail(repository: repository, number: issue.number) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(Text(issue.title)) \(Text(verbatim: "#\(issue.number)").foregroundStyle(.secondary))")
                    .font(Theme.Fonts.detailTitle)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button("Start Claude Session", systemImage: "sparkles") {
                        model.launching = SessionOrigin(issue, in: repository)
                    }
                    .help("Start a Claude Code session on this issue (⌘N)")
                    Button("Open on GitHub", systemImage: "safari") { NSWorkspace.shared.open(issue.url) }
                        .labelStyle(.iconOnly)
                        .help("Open on GitHub (⇧⌘O)")
                }
                .fixedSize()
            }

            HStack(spacing: Theme.rowMetaSpacing) {
                Label(repository.description, systemImage: "book.closed")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "·")
                AvatarView(url: issue.author?.avatarURL)
                Text(issue.author?.login ?? "ghost").lineLimit(1)
                Text(verbatim: "· updated")
                RelativeTime(issue.updatedAt)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if issue.state == .open {
                    Badge("Open", systemImage: "smallcircle.filled.circle", tint: .green)
                } else {
                    Badge("Closed", systemImage: "checkmark.circle", tint: .purple)
                }
                ForEach(issue.labels, id: \.self) { LabelChip(name: $0.name, hexColor: $0.color) }
                Spacer(minLength: 8)
                if !issue.assignees.isEmpty {
                    HStack(spacing: -4) {
                        ForEach(issue.assignees, id: \.login) { AvatarView(url: $0.avatarURL).help($0.login) }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Assigned to " + issue.assignees.map(\.login).joined(separator: ", "))
                }
                if issue.commentCount > 0 {
                    Label("\(issue.commentCount)", systemImage: "bubble")
                        .labelStyle(.compact)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(issue.commentCount) comments")
                }
            }
        }
        .padding(.horizontal, Theme.detailInset)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// A pull request that closes the issue. Navigates to it when it is loaded;
/// a merged or closed one opens in the browser.
struct LinkedPullRequestRow: View {
    let linked: LinkedPullRequest
    let repository: RepositoryRef
    @Environment(AppModel.self) private var model

    var body: some View {
        let key = ItemKey(repository: repository, number: linked.number)
        Button {
            if model.pullRequest(key) != nil {
                model.navigate(to: .pullRequest(key), tab: .files)
            } else if let url = URL(string: "https://github.com/\(repository)/pull/\(linked.number)") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: Theme.rowGlyphSpacing) {
                Image(systemName: linked.state.symbol).foregroundStyle(linked.state.tint)
                Text(verbatim: "#\(linked.number)").monospacedDigit().foregroundStyle(.secondary)
                Text(linked.title).lineLimit(1).truncationMode(.tail)
                Text(linked.state.label).font(Theme.Fonts.rowMeta).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if model.pullRequest(key) == nil {
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Opens in the browser")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.pullRequest(key) != nil ? "Open this pull request's diff" : "Open on GitHub")
    }
}

extension LinkedPullRequest.State {
    var label: String {
        switch self {
        case .open: "Open"
        case .closed: "Closed"
        case .merged: "Merged"
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.triangle.pull"
        case .closed: "xmark.circle"
        case .merged: "arrow.triangle.merge"
        }
    }

    var tint: Color {
        switch self {
        case .open: .green
        case .closed: .red
        case .merged: .purple
        }
    }
}

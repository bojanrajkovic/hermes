import AppKit
import GitHubKit
import HermesUI
import SessionsUI
import SwiftUI

// MARK: Pull requests

/// A pull request in a list: CI state, title and age on the first line;
/// author, number, state and size on the second.
struct PullRequestRow: View {
    let pullRequest: PullRequest

    var body: some View {
        HStack(alignment: .top, spacing: Theme.rowGlyphSpacing) {
            StatusGlyph(StatusKind(pullRequest.checkState))
                .frame(width: Theme.avatarSize)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.rowMetaSpacing) {
                    Text(pullRequest.title)
                        .font(Theme.Fonts.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    RelativeTime(pullRequest.updatedAt)
                        .font(Theme.Fonts.rowMeta)
                        .foregroundStyle(.secondary)
                }
                // A narrow sidebar drops the author's name before it cuts anything else.
                ViewThatFits(in: .horizontal) {
                    meta(showingLogin: true)
                    meta(showingLogin: false)
                }
                .font(Theme.Fonts.rowMeta)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func meta(showingLogin: Bool) -> some View {
        HStack(spacing: Theme.rowMetaSpacing) {
            AvatarView(url: pullRequest.author?.avatarURL, size: 14)
                .help(pullRequest.author?.login ?? "Deleted account")
            Text(verbatim: "#\(pullRequest.number)")
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            if showingLogin {
                Text(pullRequest.author?.login ?? "ghost")
                    .lineLimit(1)
                    .fixedSize()
            }
            if pullRequest.isDraft { Badge("Draft", systemImage: "pencil.line") }
            if let decision = pullRequest.reviewDecision { ReviewDecisionGlyph(decision: decision) }
            if pullRequest.mergeable == .conflicting { ConflictGlyph() }
            Spacer(minLength: 4)
            DiffCounts(additions: pullRequest.additions, deletions: pullRequest.deletions)
        }
    }

    private var accessibilityLabel: String {
        var parts = ["Pull request \(pullRequest.number)", pullRequest.title]
        if let author = pullRequest.author { parts.append("by \(author.login)") }
        if pullRequest.isDraft { parts.append("draft") }
        if let decision = pullRequest.reviewDecision { parts.append(decision.label) }
        if pullRequest.mergeable == .conflicting { parts.append("merge conflicts") }
        parts.append(StatusKind(pullRequest.checkState).label)
        return parts.joined(separator: ", ")
    }
}

extension ReviewDecision {
    var label: String {
        switch self {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        }
    }

    var symbol: String {
        switch self {
        case .approved: "person.fill.checkmark"
        case .changesRequested: "person.fill.xmark"
        case .reviewRequired: "person.fill.questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .approved: .green
        case .changesRequested: .red
        case .reviewRequired: .secondary
        }
    }
}

struct ReviewDecisionGlyph: View {
    let decision: ReviewDecision
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: decision.symbol)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(decision.tint))
            .help(decision.label)
            .accessibilityLabel(decision.label)
    }
}

struct ConflictGlyph: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.yellow)
            .help("Merge conflicts")
            .accessibilityLabel("Merge conflicts")
    }
}

/// Added and deleted line counts. The sign carries the meaning; the color repeats it.
///
/// On a selected row's highlight the counts take the row's text color,
/// because green and red do not read on the accent color.
struct DiffCounts: View {
    let additions: Int
    let deletions: Int
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onHighlight = prominence == .increased
        HStack(spacing: 4) {
            Text(verbatim: "+\(additions)").foregroundStyle(onHighlight ? AnyShapeStyle(.primary) : AnyShapeStyle(.green))
            Text(verbatim: "−\(deletions)").foregroundStyle(onHighlight ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }
}

/// The label of a stack node: how many pull requests, where it lands, and
/// each one's CI state in order.
struct StackRow: View {
    let stack: PullRequestStack

    var body: some View {
        HStack(spacing: Theme.rowGlyphSpacing) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: Theme.avatarSize)
            Text("Stack of \(stack.pullRequests.count)")
                .font(Theme.Fonts.rowTitle)
                .lineLimit(1)
            Text(verbatim: "→ \(stack.baseRefName)")
                .font(Theme.Fonts.rowMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(stack.pullRequests) { StatusGlyph(StatusKind($0.checkState)) }
            }
            .font(Theme.Fonts.rowMeta)
        }
        .padding(.vertical, Theme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stack of \(stack.pullRequests.count) pull requests into \(stack.baseRefName)")
    }
}

// MARK: Issues

struct IssueRow: View {
    let issue: Issue
    /// Labels shown before the rest collapse into "+N".
    private static let labelLimit = 3

    var body: some View {
        HStack(alignment: .top, spacing: Theme.rowGlyphSpacing) {
            IssueStateGlyph(state: issue.state)
                .frame(width: Theme.avatarSize)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.rowMetaSpacing) {
                    Text(issue.title)
                        .font(Theme.Fonts.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    RelativeTime(issue.updatedAt)
                        .font(Theme.Fonts.rowMeta)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: Theme.rowMetaSpacing) {
                    Text(verbatim: "#\(issue.number)")
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    ForEach(issue.labels.prefix(Self.labelLimit), id: \.self) {
                        LabelChip(name: $0.name, hexColor: $0.color)
                    }
                    if issue.labels.count > Self.labelLimit {
                        Text(verbatim: "+\(issue.labels.count - Self.labelLimit)").lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: 4)
                    if !issue.linkedPullRequests.isEmpty {
                        Label("\(issue.linkedPullRequests.count)", systemImage: "arrow.triangle.pull")
                            .labelStyle(.compact)
                            .help(linkedHelp)
                            .accessibilityLabel(linkedHelp)
                    }
                    if issue.commentCount > 0 {
                        Label("\(issue.commentCount)", systemImage: "bubble")
                            .labelStyle(.compact)
                            .accessibilityLabel("\(issue.commentCount) comments")
                    }
                }
                .font(Theme.Fonts.rowMeta)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private var linkedHelp: String {
        "Linked pull requests: " + issue.linkedPullRequests.map { "#\($0.number)" }.joined(separator: ", ")
    }
}

struct IssueStateGlyph: View {
    let state: Issue.State

    var body: some View {
        Image(systemName: state == .open ? "smallcircle.filled.circle" : "checkmark.circle")
            .foregroundStyle(state == .open ? Color.green : Color.purple)
            .help(state == .open ? "Open" : "Closed")
            .accessibilityLabel(state == .open ? "Open issue" : "Closed issue")
    }
}

/// An icon and a number set tight, for counts on a row's metadata line.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title.monospacedDigit().lineLimit(1)
        }
        .fixedSize()
    }
}

extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}

// MARK: Repositories and sessions

struct RepositoryRow: View {
    let section: RepositorySection
    /// Counts sit on the row in the styles where the row has no children.
    var showsCounts = true

    var body: some View {
        HStack(spacing: Theme.rowMetaSpacing) {
            Label(section.ref.name, systemImage: section.isPrivate ? "lock" : "book.closed")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if showsCounts {
                HStack(spacing: Theme.rowGlyphSpacing) {
                    if section.shownPullRequestCount > 0 {
                        Label("\(section.shownPullRequestCount)", systemImage: "arrow.triangle.pull").labelStyle(.compact)
                    }
                    if section.shownPullRequestCount == 0, section.hiddenBotCount > 0 {
                        Label("\(section.hiddenBotCount)", systemImage: "eye.slash")
                            .labelStyle(.compact)
                            .help("Bot pull requests hidden")
                    }
                    if section.openIssueCount > 0 {
                        Label("\(section.openIssueCount)", systemImage: "smallcircle.filled.circle").labelStyle(.compact)
                    }
                }
                .font(Theme.Fonts.rowMeta)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(section.ref.name), \(section.shownPullRequestCount) pull requests, \(section.openIssueCount) issues"
        )
    }
}

struct SessionRow: View {
    let session: ClaudeSession

    var body: some View {
        HStack(spacing: Theme.rowGlyphSpacing) {
            SessionStateGlyph(state: session.state)
                .frame(width: Theme.avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(Theme.Fonts.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: "\(session.origin.repository.name)#\(session.origin.number)" + (session.branch.map { " · \($0)" } ?? ""))
                    .font(Theme.Fonts.rowMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, Theme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }
}

struct SessionStateGlyph: View {
    let state: ClaudeSession.State

    var body: some View {
        Image(systemName: state == .running ? "play.circle.fill" : "stop.circle")
            .foregroundStyle(state == .running ? Color.green : Color.secondary)
            .help(state == .running ? "Running" : "Exited")
            .accessibilityLabel(state == .running ? "Running" : "Exited")
    }
}

// MARK: Row groups shared by every navigation style

/// A repository's pull request rows: single ones, and stacks as nodes that
/// open to their pull requests in order.
struct PullRequestRows: View {
    let section: RepositorySection
    @Environment(WindowModel.self) private var model

    var body: some View {
        ForEach(section.groups) { group in
            switch group {
            case .single(let pullRequest):
                row(pullRequest)
            case .stack(let stack):
                // Plain rows with their own chevron, not a `DisclosureGroup`: inside one, the list
                // kept the row that was selected first highlighted after the selection moved.
                let isExpanded = model.expansionBinding("stack:\(stack.id)", default: true)
                HStack(spacing: 4) {
                    Button(isExpanded.wrappedValue ? "Collapse Stack" : "Expand Stack", systemImage: "chevron.right") {
                        isExpanded.wrappedValue.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.small)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    .frame(width: 14)
                    StackRow(stack: stack)
                }
                .selectionDisabled()
                if isExpanded.wrappedValue {
                    ForEach(stack.pullRequests) { row($0).padding(.leading, 18) }
                }
            }
        }
        if section.hiddenBotCount > 0 {
            Button {
                model.showingAllBots = true
            } label: {
                Label(
                    section.hiddenBotCount == 1 ? "1 bot PR hidden" : "\(section.hiddenBotCount) bot PRs hidden",
                    systemImage: "eye.slash"
                )
                .font(Theme.Fonts.rowMeta)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show every bot pull request (⇧⌘B)")
        }
    }

    private func row(_ pullRequest: PullRequest) -> some View {
        PullRequestRow(pullRequest: pullRequest)
            .tag(Destination.pullRequest(pullRequest.key))
            .contextMenu { ItemMenu(url: pullRequest.url, origin: SessionOrigin(pullRequest), model: model) }
    }
}

/// A repository's issue rows, with a last row that reports progress and
/// loads the next page when it scrolls into view or is clicked.
struct IssueRows: View {
    let repository: RepositoryRef
    @Environment(WindowModel.self) private var model

    var body: some View {
        let list = model.issueList(of: repository)
        ForEach(list.items) { issue in
            IssueRow(issue: issue)
                .tag(Destination.issue(ItemKey(repository: repository, number: issue.number)))
                .contextMenu { ItemMenu(url: issue.url, origin: SessionOrigin(issue, in: repository), model: model) }
        }
        if let error = list.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(Theme.Fonts.rowMeta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if list.hasNextPage || list.isLoading {
            HStack(spacing: Theme.rowGlyphSpacing) {
                if list.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading issues…")
                } else {
                    Button("Load More") { Task { await model.loadMoreIssues(of: repository) } }
                        .buttonStyle(.link)
                }
                Spacer(minLength: 4)
                if let total = list.totalCount {
                    Text("\(list.items.count) of \(total)").monospacedDigit()
                }
            }
            .font(Theme.Fonts.rowMeta)
            .foregroundStyle(.secondary)
            // A failed page waits for a click, so an error does not retry in a loop.
            // The load runs in its own task: this row scrolling away must not cancel the request.
            .task(id: list.items.count) {
                if list.error == nil { Task { await model.loadMoreIssues(of: repository) } }
            }
        } else if let total = list.totalCount, total > 0 {
            Text("All \(total) issues loaded")
                .font(Theme.Fonts.rowMeta)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The context menu of a pull request or issue row. It takes the model as a
/// parameter because a menu is built outside the window's view tree.
struct ItemMenu: View {
    let url: URL
    let origin: SessionOrigin
    let model: WindowModel

    var body: some View {
        Button("Open on GitHub", systemImage: "safari") { NSWorkspace.shared.open(url) }
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        Divider()
        Button("Start Claude Session…", systemImage: "sparkles") { model.launching = origin }
    }
}

/// Scrolls a list to the row the model asks for, when the list has that row.
struct ScrollsToRequestedRow: ViewModifier {
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: model.scrollRequest?.serial) {
                guard let target = model.scrollRequest?.target else { return }
                Task {
                    // The row may sit in a node that opens in this same update.
                    try? await Task.sleep(for: .milliseconds(150))
                    // A repository goes to the top so its rows follow; a row moves only if it is out of view.
                    if let repository = target.base as? RepositoryRef {
                        proxy.scrollTo(repository, anchor: .top)
                    } else if let id = target.base as? String {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }
}

extension WindowModel {
    /// A binding to one tree node's open state.
    func expansionBinding(_ node: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { self.isExpanded(node, default: defaultValue) },
            set: { self.expansion[node] = $0 }
        )
    }

    /// The list selection. Picking a pull request from a list lands in its diff.
    var selection: Binding<Destination?> {
        Binding(
            get: { self.destination },
            set: { destination in
                // A list that does not hold the open item reports no selection.
                // That must not close what the detail pane shows.
                guard let destination, destination != self.destination else { return }
                self.destination = destination
                if case .pullRequest = destination { self.pullRequestTab = .files }
            }
        )
    }
}

import AppKit
import ChecksUI
import DiffUI
import GitHubKit
import HermesUI
import MarkdownUI
import SessionsUI
import SwiftUI

/// Loads one value for a detail pane and keeps the last good one while it reloads.
@Observable
@MainActor
final class Loader<Value: Sendable> {
    private(set) var value: Value?
    private(set) var error: String?
    /// How many times the user asked to try again. Part of `LoadID`, so a retry restarts the load.
    private(set) var attempt = 0

    func retry() {
        error = nil
        attempt += 1
    }

    func load(_ operation: () async throws -> Value) async {
        do {
            value = try await operation()
            error = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            self.error = describe(error)
        }
    }
}

/// Identifies one load of a detail pane: it runs again when the item changes
/// on GitHub or the user retries.
struct LoadID: Hashable {
    let updatedAt: Date
    let attempt: Int
}

/// One entry in a pull request's activity: a comment or a submitted review.
struct TimelineEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case comment
        case review(Review.State)
    }

    let id: String
    let author: User?
    let date: Date?
    let kind: Kind
    let body: String
}

/// A pull request's comments and reviews in the order they happened.
///
/// Pending reviews are left out, and so are reviews that only carry line
/// comments: they have no summary to show, and their comments are in the diff.
func timeline(of detail: PullRequestDetail) -> [TimelineEntry] {
    let comments = detail.comments.map {
        TimelineEntry(id: $0.id, author: $0.author, date: $0.createdAt, kind: .comment, body: $0.body)
    }
    let reviews = detail.reviews.compactMap { review -> TimelineEntry? in
        if review.state == .pending { return nil }
        if review.state == .commented, review.body.isEmpty { return nil }
        return TimelineEntry(
            id: review.id, author: review.author, date: review.submittedAt, kind: .review(review.state), body: review.body
        )
    }
    return (comments + reviews).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
}

// MARK: Detail

struct PullRequestDetailView: View {
    let pullRequest: PullRequest
    @Environment(AppModel.self) private var model
    @State private var detail = Loader<PullRequestDetail>()
    /// Tabs stay mounted once opened, so the diff keeps its scroll position
    /// while the user looks at the checks.
    @State private var opened: Set<PullRequestTab> = []

    var body: some View {
        let sessions = model.sessions(startedFrom: pullRequest.key, isPullRequest: true)
        let tabs = PullRequestTab.allCases.filter { $0 != .sessions || !sessions.isEmpty }
        let current = tabs.contains(model.pullRequestTab) ? model.pullRequestTab : .files

        VStack(spacing: 0) {
            PullRequestHeader(pullRequest: pullRequest, tabs: tabs, current: current)
            Divider()
            ZStack {
                ForEach(tabs.filter { opened.contains($0) || $0 == current }) { tab in
                    content(tab, sessions: sessions)
                        .opacity(tab == current ? 1 : 0)
                        .allowsHitTesting(tab == current)
                        .accessibilityHidden(tab != current)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: current, initial: true) { opened.insert(current) }
        .task {
            // The lists reload each minute. An open pull request asks for its head
            // every 10 seconds and loads itself again on a change, so a push shows
            // up in the header and checks sooner.
            let key = pullRequest.key
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let shown = model.pullRequest(key),
                      let revision = try? await model.client.pullRequestRevision(repository: key.repository, number: key.number)
                else { continue }
                if revision.headOID != shown.headOID || revision.updatedAt > shown.updatedAt { await model.refetch(key) }
            }
        }
        .task(id: LoadID(updatedAt: pullRequest.updatedAt, attempt: detail.attempt)) {
            await detail.load {
                try await model.client.pullRequestDetail(repository: pullRequest.repository, number: pullRequest.number)
            }
        }
    }

    @ViewBuilder
    private func content(_ tab: PullRequestTab, sessions: [ClaudeSession]) -> some View {
        switch tab {
        case .conversation:
            ConversationView(pullRequest: pullRequest, detail: detail)
        case .files:
            DiffScreen(
                source: .pullRequest(pullRequest), client: model.client, repoCache: model.repoCache,
                target: Binding { model.diffTarget } set: { model.diffTarget = $0 }
            )
        case .checks:
            ChecksScreen(
                repository: pullRequest.repository, commitOID: pullRequest.headOID, client: model.client,
                initiallySelected: model.checkToOpen
            )
        case .sessions:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sessions) { SessionSummaryRow(session: $0, showsPullRequest: false) }
                }
                .padding(Theme.detailInset)
                .frame(maxWidth: Theme.conversationMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: Header

struct PullRequestHeader: View {
    let pullRequest: PullRequest
    let tabs: [PullRequestTab]
    let current: PullRequestTab
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(Text(pullRequest.title)) \(Text(verbatim: "#\(pullRequest.number)").foregroundStyle(.secondary))")
                    .font(Theme.Fonts.detailTitle)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    StackSwitcher(pullRequest: pullRequest)
                    MergeButton(pullRequest: pullRequest)
                    Button("Start Claude Session", systemImage: "sparkles") {
                        model.launching = SessionOrigin(pullRequest)
                    }
                    .help("Start a Claude Code session on this pull request (⌘N)")
                    Button("Open on GitHub", systemImage: "safari") { NSWorkspace.shared.open(pullRequest.url) }
                        .labelStyle(.iconOnly)
                        .help("Open on GitHub (⇧⌘O)")
                }
                .fixedSize()
            }

            HStack(spacing: Theme.rowMetaSpacing) {
                Label(pullRequest.repository.description, systemImage: "book.closed")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "·")
                AvatarView(url: pullRequest.author?.avatarURL)
                Text(pullRequest.author?.login ?? "ghost").lineLimit(1)
                Text(verbatim: "· updated")
                RelativeTime(pullRequest.updatedAt)
                Spacer(minLength: 8)
                DiffCounts(additions: pullRequest.additions, deletions: pullRequest.deletions)
                Text(pullRequest.changedFileCount == 1 ? "1 file" : "\(pullRequest.changedFileCount) files")
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                state
                BranchChips(head: pullRequest.headRefName, base: pullRequest.baseRefName)
                if let decision = pullRequest.reviewDecision {
                    Badge(decision.label, systemImage: decision.symbol, tint: decision.tint)
                }
                switch pullRequest.mergeable {
                case .conflicting: Badge("Conflicts", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                case .mergeable: Badge("No conflicts", systemImage: "arrow.triangle.merge")
                case .unknown: EmptyView()
                }
                Button {
                    model.pullRequestTab = .checks
                } label: {
                    let kind = StatusKind(pullRequest.checkState)
                    Badge(kind.label, systemImage: kind.symbol, tint: kind.tint)
                }
                .buttonStyle(.plain)
                .help("Show checks (⌘3)")
                Spacer(minLength: 0)
            }

        }
        .padding(.horizontal, Theme.detailInset)
        .padding(.vertical, 12)
        .background(.bar)
        // The tabs sit in the toolbar's center, where macOS apps put a view switcher.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: Binding(get: { current }, set: { model.pullRequestTab = $0 })) {
                    ForEach(tabs) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var state: some View {
        switch model.closedState(of: pullRequest.key) {
        case .merged: Badge("Merged", systemImage: "arrow.triangle.merge", tint: .purple)
        case .closed: Badge("Closed", systemImage: "xmark.circle", tint: .red)
        case .open, nil:
            if pullRequest.isDraft {
                Badge("Draft", systemImage: "pencil.line")
            } else {
                Badge("Open", systemImage: "arrow.triangle.pull", tint: .green)
            }
        }
    }
}

/// `head → base`, with long branch names truncated in the middle.
struct BranchChips: View {
    let head: String
    let base: String

    var body: some View {
        HStack(spacing: 4) {
            chip(head)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("into")
            chip(base)
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ name: String) -> some View {
        Text(name)
            .font(Theme.Fonts.code)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.badgeCornerRadius))
            .help(name)
            .textSelection(.enabled)
    }
}

/// A menu of every pull request in the open one's stack, bottom first.
/// Merges the pull request when GitHub says it can merge. The button uses the
/// repository's default method; its menu offers the other allowed ones.
struct MergeButton: View {
    let pullRequest: PullRequest
    @Environment(AppModel.self) private var model
    @State private var readiness: MergeReadiness?
    /// The method waiting for the user's confirmation.
    @State private var pending: MergeMethod?
    @State private var isMerging = false
    @State private var failure: String?

    var body: some View {
        // A pull request that is merged or closed has nothing to merge.
        if model.closedState(of: pullRequest.key) == nil || model.closedState(of: pullRequest.key) == .open {
            Menu {
                ForEach(readiness?.allowedMethods ?? [], id: \.self) { method in
                    Button(method.title) { pending = method }
                }
            } label: {
                Label(isMerging ? "Merging…" : "Merge", systemImage: "arrow.triangle.merge")
            } primaryAction: {
                pending = readiness?.defaultMethod
            }
            .fixedSize()
            .disabled(readiness?.canMerge != true || isMerging)
            .help(help)
            .task(id: MergeInput(head: pullRequest.headOID, updatedAt: pullRequest.updatedAt, checks: pullRequest.checkState)) {
                readiness = try? await model.client.mergeReadiness(repository: pullRequest.repository, number: pullRequest.number)
            }
            .confirmationDialog(
                title, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending
            ) { method in
                Button(method.title) { merge(method) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(message)
            }
            .alert("Could Not Merge", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    /// What the readiness depends on: a push, a review, or a finished check changes it.
    private struct MergeInput: Hashable {
        let head: String
        let updatedAt: Date
        let checks: StatusState?
    }

    private var help: String {
        guard let readiness else { return "Checking whether this can merge…" }
        return readiness.blocker ?? "\(readiness.defaultMethod.title) (the repository's default)"
    }

    private var title: String {
        let set = model.mergeSet(of: pullRequest)
        return set.count > 1
            ? "Merge \(set.count) pull requests into \(set[0].baseRefName)?"
            : "Merge #\(pullRequest.number) into \(pullRequest.baseRefName)?"
    }

    private var message: String {
        let set = model.mergeSet(of: pullRequest)
        // GitHub allows a merge while a check that is not required fails or still runs.
        let warning = readiness?.state == .unstable ? " A check is failing or still running." : ""
        guard set.count > 1 else { return "“\(pullRequest.title)” will be merged. This can't be undone.\(warning)" }
        let numbers = set.map { "#\($0.number)" }.formatted(.list(type: .and))
        return "This pull request is part of a stack. \(numbers) will be merged together, all or nothing. This can't be undone.\(warning)"
    }

    private func merge(_ method: MergeMethod) {
        isMerging = true
        Task {
            defer { isMerging = false }
            do {
                try await model.merge(pullRequest, method: method)
            } catch {
                failure = describe(error)
                readiness = try? await model.client.mergeReadiness(repository: pullRequest.repository, number: pullRequest.number)
            }
        }
    }
}

struct StackSwitcher: View {
    let pullRequest: PullRequest
    @Environment(AppModel.self) private var model

    var body: some View {
        let stack = model.stack(of: pullRequest)
        if let entry = pullRequest.stack, !stack.isEmpty {
            Menu {
                ForEach(stack) { member in
                    Toggle(isOn: Binding(
                        get: { member.id == pullRequest.id },
                        set: { _ in model.navigate(to: .pullRequest(member.key)) }
                    )) {
                        Label {
                            Text(verbatim: "#\(member.number)  \(member.title)")
                        } icon: {
                            Image(systemName: StatusKind(member.checkState).symbol)
                        }
                    }
                    .accessibilityLabel("\(member.number), \(member.title), \(StatusKind(member.checkState).label)")
                }
                Divider()
                Button("Down the Stack") { model.moveInStack(by: -1) }
                    .disabled(!model.canMoveDownStack)
                Button("Up the Stack") { model.moveInStack(by: 1) }
                    .disabled(!model.canMoveUpStack)
            } label: {
                Label("Stack \(entry.position) of \(entry.size)", systemImage: "square.stack.3d.up")
            }
            .fixedSize()
            .help("Switch to another pull request in this stack (⌘[ and ⌘])")
        }
    }
}

// MARK: Conversation

struct ConversationView: View {
    let pullRequest: PullRequest
    let detail: Loader<PullRequestDetail>
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.readingSectionSpacing) {
                if let value = detail.value {
                    CommentCard(
                        author: pullRequest.author, verb: "opened this pull request", date: pullRequest.createdAt,
                        markdown: value.body, baseURL: pullRequest.url
                    )
                    if !value.requestedReviewers.isEmpty { reviewers(value.requestedReviewers) }
                } else if let error = detail.error {
                    ContentUnavailableView {
                        Label("Could Not Load the Conversation", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { detail.retry() }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading the conversation…").foregroundStyle(.secondary)
                    }
                }

                PaneSection("Checks") {
                    ChecksSummary(
                        repository: pullRequest.repository, commitOID: pullRequest.headOID, client: model.client
                    ) { check in
                        model.checkToOpen = check
                        model.pullRequestTab = .checks
                    }
                }

                if !pullRequest.closingIssueNumbers.isEmpty {
                    PaneSection("Linked Issues") {
                        ForEach(pullRequest.closingIssueNumbers, id: \.self) { number in
                            let key = ItemKey(repository: pullRequest.repository, number: number)
                            Button {
                                Task { await model.open(key) }
                            } label: {
                                HStack(spacing: Theme.rowGlyphSpacing) {
                                    Image(systemName: "smallcircle.filled.circle").foregroundStyle(.green)
                                    Text(verbatim: "#\(number)").monospacedDigit().foregroundStyle(.secondary)
                                    Text(model.issue(key)?.title ?? "Issue \(number)").lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open issue #\(number)")
                        }
                    }
                }

                if let value = detail.value {
                    let entries = timeline(of: value)
                    PaneSection("Activity") {
                        if entries.isEmpty {
                            Text("No comments or reviews yet.").foregroundStyle(.secondary)
                        }
                        ForEach(entries) { entry in
                            CommentCard(
                                author: entry.author, verb: entry.kind.verb, date: entry.date, markdown: entry.body,
                                baseURL: pullRequest.url, badge: entry.kind.badge
                            )
                            .id(entry.id)
                        }
                    }
                    PaneSection(value.commits.count == 1 ? "1 Commit" : "\(value.commits.count) Commits") {
                        ForEach(value.commits) { commit in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.rowGlyphSpacing) {
                                Text(commit.oid.prefix(7))
                                    .font(Theme.Fonts.code)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text(commit.headline).lineLimit(1).truncationMode(.tail)
                            }
                        }
                    }
                }
            }
            .padding(Theme.detailInset)
            .frame(maxWidth: Theme.conversationMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .modifier(ScrollsToLinkedComment(comments: detail.value?.comments))
    }

    private func reviewers(_ reviewers: [RequestedReviewer]) -> some View {
        HStack(spacing: Theme.rowMetaSpacing) {
            Image(systemName: "eye")
            Text("Review requested from")
            ForEach(reviewers, id: \.self) { reviewer in
                switch reviewer {
                case .user(let user):
                    AvatarView(url: user.avatarURL)
                    Text(user.login).foregroundStyle(.primary)
                case .team(let name, _):
                    Image(systemName: "person.3")
                    Text(name).foregroundStyle(.primary)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

extension TimelineEntry.Kind {
    var verb: String {
        switch self {
        case .comment, .review(.commented), .review(.pending): "commented"
        case .review(.approved): "approved these changes"
        case .review(.changesRequested): "requested changes"
        case .review(.dismissed): "left a review that was dismissed"
        }
    }

    var badge: (symbol: String, tint: Color)? {
        switch self {
        case .review(.approved): ("person.fill.checkmark", .green)
        case .review(.changesRequested): ("person.fill.xmark", .red)
        default: nil
        }
    }
}

/// Scrolls to the comment a link named (`AppModel.commentToShow`) once the
/// comments are loaded. Each comment's view must have its node ID as its `id`.
struct ScrollsToLinkedComment: ViewModifier {
    let comments: [Comment]?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: [model.commentToShow, comments?.count], initial: true) {
                guard let id = model.commentToShow, let comments else { return }
                // A comment that is not here, such as a deleted one, leaves the view where it is.
                if let node = comments.first(where: { $0.databaseID == id })?.id {
                    withAnimation { proxy.scrollTo(node, anchor: .top) }
                }
                model.commentToShow = nil
            }
        }
    }
}

/// A heading with content under it.
struct PaneSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.readingHeadingSpacing) {
            Text(title).font(Theme.Fonts.paneHeading)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A description, comment, or review: who and when above the rendered Markdown.
struct CommentCard: View {
    let author: User?
    let verb: String
    let date: Date?
    let markdown: String
    let baseURL: URL
    var badge: (symbol: String, tint: Color)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.rowMetaSpacing) {
                AvatarView(url: author?.avatarURL, size: 20)
                Text(author?.login ?? "ghost").fontWeight(.semibold).lineLimit(1)
                if let badge { Image(systemName: badge.symbol).foregroundStyle(badge.tint).accessibilityHidden(true) }
                Text(verb).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if let date { RelativeTime(date).foregroundStyle(.secondary) }
            }
            .font(.callout)
            .padding(.horizontal, Theme.cardPadding)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if badge == nil {
                    Text("No description provided.")
                        .foregroundStyle(.secondary)
                        .padding(Theme.cardPadding)
                }
            } else {
                Divider()
                MarkdownView(markdown: markdown, baseURL: baseURL, sizing: .fitContent)
                    .padding(Theme.cardPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).strokeBorder(.separator))
    }
}

/// A session with buttons to open it and the pull request it works on.
struct SessionSummaryRow: View {
    let session: ClaudeSession
    var showsPullRequest = true
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            SessionRow(session: session)
            Spacer(minLength: 8)
            if showsPullRequest, let pullRequest = model.linkedPullRequest(of: session) {
                Button {
                    model.navigate(to: .pullRequest(pullRequest.key), tab: .files)
                } label: {
                    Label {
                        Text(verbatim: "#\(pullRequest.number)")
                    } icon: {
                        Image(systemName: "arrow.triangle.pull")
                    }
                }
                .help("Open pull request #\(pullRequest.number) and its diff: \(pullRequest.title)")
            }
            Button("Open Session") { model.navigate(to: .session(session.id)) }
        }
        .padding(Theme.cardPadding)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).strokeBorder(.separator))
    }
}

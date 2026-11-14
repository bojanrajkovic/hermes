import AppKit
import GitHubKit
import HermesUI
import SessionsUI
import SwiftUI

/// The window's content once the viewer has loaded: the lists in the chosen
/// navigation style, the detail pane, the command palette, and the session
/// launch sheet.
struct MainView: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        Group {
            NavigationSplitView {
                ScopeSidebar()
                    .navigationSplitViewColumnWidth(
                        min: Theme.sidebarMinWidth, ideal: Theme.sidebarIdealWidth, max: Theme.sidebarMaxWidth
                    )
            } content: {
                ListColumn()
                    .navigationSplitViewColumnWidth(
                        min: Theme.listColumnMinWidth, ideal: Theme.listColumnIdealWidth, max: Theme.listColumnMaxWidth
                    )
            } detail: {
                DetailPane()
            }
        }
        .overlay {
            if model.isPaletteShown { CommandPalette() }
        }
        .sheet(isPresented: Binding(get: { model.isOpenLinkShown }, set: { model.isOpenLinkShown = $0 })) {
            OpenLinkSheet()
        }
        .sheet(isPresented: Binding(get: { model.launching != nil }, set: { if !$0 { model.launching = nil } })) {
            if let origin = model.launching {
                SessionLaunchSheet(origin: origin, store: model.sessions) { session in
                    model.launching = nil
                    model.navigate(to: .session(session.id))
                }
            }
        }
        .alert(
            "Could Not Open", isPresented: Binding(get: { model.resolveError != nil }, set: { if !$0 { model.resolveError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.resolveError ?? "")
        }
        .task(id: model.refreshInterval) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.refreshInterval))
                if !Task.isCancelled { await model.data.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshIfStale() }
        }
        .task { model.normalizeScope() }
        .onChange(of: model.sections) { model.normalizeScope() }
    }
}

// MARK: Middle column

/// The middle column of the Columns and Inbox styles.
struct ListColumn: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        switch model.scope {
        case .filter(let filter):
            FilterList(filter: filter)
        case .repository(let repository):
            // A new list per repository: reusing one drew the old repository's stack rows over the new ones.
            RepositoryColumn(repository: repository).id(repository)
        case .sessions:
            List(selection: model.selection) {
                ForEach(model.sessions.sessions) { SessionRow(session: $0).tag(Destination.session($0.id)) }
            }
            .listStyle(.inset)
            .navigationTitle("Sessions")
        }
    }
}

/// Pull requests that match an Inbox filter, grouped by repository.
struct FilterList: View {
    let filter: InboxFilter
    @Environment(WindowModel.self) private var model

    var body: some View {
        let sections = model.sections(for: filter)
        let attention = filter == .needsAttention ? model.attentionItems : []
        List(selection: model.selection) {
            if filter == .needsAttention {
                // One ranked list: why each pull request is here matters more than its repository.
                // A stack sits at the rank of its most urgent member.
                PullRequestRows(
                    groups: PullRequest.grouped(attention.map(\.pullRequest)),
                    reasons: Dictionary(attention.map { ($0.pullRequest.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
                )
            } else {
                // Header rows, not `Section`s: a disclosure group under a section
                // header in an inset list draws rows on top of each other.
                ForEach(sections) { section in
                    HStack(spacing: 4) {
                        Image(systemName: section.isPrivate ? "lock" : "book.closed")
                        Text(section.ref.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Button("Issues", systemImage: "smallcircle.filled.circle") {
                            model.show(.repository(section.ref), list: .issues)
                        }
                        .labelStyle(.compactCount(section.openIssueCount))
                        .buttonStyle(.plain)
                        .help("Show this repository's \(section.openIssueCount) open issues")
                        .opacity(section.openIssueCount > 0 ? 1 : 0)
                        .accessibilityHidden(section.openIssueCount == 0)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .accessibilityAddTraits(.isHeader)

                    PullRequestRows(section: section)
                }
            }
        }
        .listStyle(.inset)
        .modifier(ScrollsToRequestedRow())
        .navigationTitle(filter.title)
        .navigationSubtitle(model.account?.login ?? "")
        .overlay {
            // Nothing is known yet while the account's first load runs; the sidebar shows the spinner.
            if (filter == .needsAttention ? attention.isEmpty : sections.isEmpty), model.hasLoaded {
                ContentUnavailableView(
                    "No Pull Requests", systemImage: filter.symbol, description: Text(emptyDescription)
                )
            }
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .needsAttention: "Nothing in this account needs you right now."
        case .yours: "You have no open pull requests in this account."
        case .failing: "No open pull request has failing checks."
        case .drafts: "There are no draft pull requests."
        case .bots: "No bot has an open pull request."
        case .all: "This account has no open pull requests."
        }
    }
}

/// A label that shows a count in place of its title.
struct CompactCountLabelStyle: LabelStyle {
    let count: Int

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            Text("\(count)").monospacedDigit()
        }
        .font(Theme.Fonts.rowMeta)
    }
}

extension LabelStyle where Self == CompactCountLabelStyle {
    static func compactCount(_ count: Int) -> CompactCountLabelStyle { CompactCountLabelStyle(count: count) }
}

/// One repository's pull requests or issues, with a control to switch.
struct RepositoryColumn: View {
    let repository: RepositoryRef
    @Environment(WindowModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let section = model.sections.first { $0.ref == repository }
        let issueList = model.issueList(of: repository)

        List(selection: model.selection) {
            switch model.repositoryList {
            case .pullRequests:
                if let section { PullRequestRows(section: section) }
            case .issues:
                IssueRows(repository: repository)
            case .localStacks:
                LocalStackRows(repository: repository)
            }
        }
        .listStyle(.inset)
        .modifier(ScrollsToRequestedRow())
        .task(id: repository) { await model.localStacks.load(repository) }
        // A toolbar item at the leading edge, which lands above this column. Only there does the
        // system draw the control the way it draws the pull request's tabs.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("List", selection: $model.repositoryList) {
                    Text("Pull Requests (\(section?.shownPullRequestCount ?? 0))").tag(RepositoryList.pullRequests)
                    Text("Issues (\(issueList.totalCount ?? section?.openIssueCount ?? 0))").tag(RepositoryList.issues)
                    if let local = model.localStacks.entry(repository) {
                        Text("Local (\(local.stacks.flatMap(\.branches).count))").tag(RepositoryList.localStacks)
                    }
                }
                // A segment added to a live segmented picker draws without its label, so the picker is rebuilt.
                .id(model.localStacks.entry(repository) != nil)
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .overlay {
            if model.repositoryList == .pullRequests, (section?.shownPullRequestCount ?? 0) + (section?.hiddenBotCount ?? 0) == 0 {
                ContentUnavailableView(
                    "No Open Pull Requests", systemImage: "arrow.triangle.pull",
                    description: Text("\(repository.name) has no open pull requests.")
                )
            } else if model.repositoryList == .issues, issueList.totalCount == 0 {
                ContentUnavailableView(
                    "No Open Issues", systemImage: "smallcircle.filled.circle",
                    description: Text("\(repository.name) has no open issues.")
                )
            } else if model.repositoryList == .localStacks, model.localStacks.entry(repository)?.stacks.isEmpty ?? true {
                ContentUnavailableView(
                    "No Local Branches", systemImage: "arrow.triangle.branch",
                    description: Text("Your checkout of \(repository.name) has no branches with commits beyond the default branch.")
                )
            }
        }
        .navigationTitle(repository.name)
        .navigationSubtitle(repository.owner)
        // The name stays the window's title but leaves the toolbar: beside the list control it ran
        // past the column's edge, and the sidebar already marks the repository.
        .toolbar(removing: .title)
    }
}

// MARK: Detail

struct DetailPane: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        content
            // Leading items, which land above the list column in every state. As the window's
            // primary actions they moved between the list column and the far right.
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .help("Reload pull requests and issues (⌘R)")
                        .disabled(model.isRefreshing)
                    Button("Command Palette", systemImage: "magnifyingglass") { model.isPaletteShown = true }
                        .help("Jump to a repository, pull request, or issue (⌘K)")
                }
            }
    }

    private var content: some View {
        Group {
            if let key = model.resolving {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(verbatim: "Loading \(key)…").foregroundStyle(.secondary)
                }
            } else {
                switch model.destination {
                case .pullRequest(let key):
                    if let pullRequest = model.pullRequest(key) {
                        PullRequestDetailView(pullRequest: pullRequest).id(key)
                    } else {
                        gone("Pull Request Not Loaded", key: key, path: "pull")
                    }
                case .issue(let key):
                    if let issue = model.issue(key) {
                        IssueDetailView(issue: issue, repository: key.repository).id(key)
                    } else {
                        gone("Issue Not Loaded", key: key, path: "issues")
                    }
                case .session(let id):
                    if let session = model.session(id) {
                        SessionScreen(session: session).id(id)
                    } else {
                        ContentUnavailableView("Session Ended", systemImage: "terminal")
                    }
                case .localBranch(let key):
                    LocalBranchScreen(key: key).id(key)
                case nil:
                    ContentUnavailableView(
                        "No Selection", systemImage: "arrow.triangle.pull",
                        description: Text("Select a pull request or an issue, or press ⌘K to jump to one.")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }

    private var title: String {
        switch model.destination {
        case .pullRequest(let key), .issue(let key): key.description
        case .session(let id): model.session(id)?.title ?? "Session"
        case .localBranch(let key): key.branch
        case nil: "Hermes"
        }
    }

    private func gone(_ title: LocalizedStringKey, key: ItemKey, path: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "questionmark.circle")
        } description: {
            Text(verbatim: "\(key) is not in the loaded lists. It may have been closed.")
        } actions: {
            Button("Load It") { Task { await model.open(key) } }
            if let url = URL(string: "https://github.com/\(key.repository)/\(path)/\(key.number)") {
                Link("Open on GitHub", destination: url)
            }
        }
    }
}

extension WindowModel {
    /// Shows a scope in the middle column. A repository with no pull requests
    /// opens on its issues.
    func show(_ scope: Scope, list: RepositoryList? = nil) {
        self.scope = scope
        guard case .repository(let repository) = scope else { return }
        if let list {
            repositoryList = list
        } else if let section = sections.first(where: { $0.ref == repository }) {
            repositoryList = section.shownPullRequestCount + section.hiddenBotCount == 0 ? .issues : .pullRequests
        }
    }

    /// Replaces a scope the current style or data cannot show.
    func normalizeScope() {
        let sections = sections
        let isValid = switch scope {
        case .filter: true
        case .repository(let repository): sections.contains { $0.ref == repository } || !hasLoaded
        case .sessions: !self.sessions.sessions.isEmpty
        }
        if !isValid { show(.filter(.needsAttention)) }
    }
}

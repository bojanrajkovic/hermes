import GitHubKit
import HermesUI
import MarkdownUI
import SwiftUI

/// The trailing pane: the selected check's header and its log, steps, or summary.
struct CheckDetailView: View {
    let check: Check
    let repository: RepositoryRef
    let client: GitHubClient
    let isRerunning: Bool
    /// Runs the job again. `nil` when it cannot run again.
    let rerun: (() -> Void)?

    @State private var model = CheckDetailModel()
    @State private var retryCount = 0

    var body: some View {
        VStack(spacing: 0) {
            CheckDetailHeader(check: check, isRerunning: isRerunning, rerun: rerun)
            Divider()
            CheckDetailContent(check: check, content: model.content) { retryCount += 1 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A running job is followed to its end by the model. Any other check
        // is loaded again when the list's refresh shows a new state.
        .task(id: [check.id, String(retryCount), check.jobID == nil ? check.state.label : ""]) {
            await model.run(check: check, repository: repository, client: client)
        }
    }
}

struct CheckDetailHeader: View {
    let check: Check
    var isRerunning = false
    var rerun: (() -> Void)?
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            StatusGlyph(state: check.state)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(subtitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if check.state == .running || check.duration != nil {
                        Text("·")
                        TimingText(check: check)
                    }
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Metrics.rowSpacing)
            if let rerun {
                Button(action: rerun) { Label("Re-run Job", systemImage: "arrow.clockwise") }
                    .disabled(isRerunning)
                    .help("Run this job again, with the jobs that depend on it")
            }
            if let url = check.url {
                Button {
                    openURL(url)
                } label: {
                    Label(check.jobID == nil ? "Open Details" : "Open on GitHub", systemImage: "arrow.up.forward.square")
                }
                .help(url.absoluteString)
            }
        }
        .padding(.horizontal, Metrics.barHorizontalPadding)
        .padding(.vertical, Metrics.barVerticalPadding + 2)
    }

    /// "Failed · ci · GitHub Actions"
    private var subtitle: String {
        [check.state.label, check.run?.workflow?.name, check.appName].compactMap { $0 }.joined(separator: " · ")
    }
}

struct CheckDetailContent: View {
    let check: Check
    let content: CheckDetailModel.Content
    let retry: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch content {
        case .loading:
            ProgressView("Loading…")
        case .steps(let steps):
            JobStepsView(steps: steps)
        case .log(let log):
            // A new log gets a new text view, whose text is never patched from another log's.
            LogView(model: log).id(ObjectIdentifier(log))
        case .summary(let output):
            CheckSummaryView(check: check, title: output?.title, markdown: output?.markdown)
        case .status(let description):
            CheckSummaryView(check: check, title: description, markdown: nil)
        case .noLog:
            ContentUnavailableView {
                Label("No Log Available", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(check.state == .skipped
                    ? "This job was skipped, so it has no log."
                    : ChecksError.message(for: GitHubError.logsUnavailable))
            } actions: {
                // The log of a job that just finished can take a few seconds to appear.
                if check.state != .skipped { Button("Retry", action: retry) }
                if let url = check.url { Button("Open on GitHub") { openURL(url) } }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load the Log", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry", action: retry)
            }
        }
    }
}

/// A check that has no log: what it reported, and a link to its page.
struct CheckSummaryView: View {
    let check: Check
    let title: String?
    let markdown: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let markdown {
            VStack(alignment: .leading, spacing: 0) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(Theme.Fonts.sectionHeading)
                        .padding(.horizontal, Metrics.summaryInset)
                        .padding(.top, Theme.readingHeadingSpacing * 2)
                }
                MarkdownView(markdown: markdown, baseURL: check.url)
            }
        } else {
            ContentUnavailableView {
                Label(title.flatMap { $0.isEmpty ? nil : $0 } ?? check.state.label, systemImage: check.state.symbol)
            } description: {
                Text("\(check.appName ?? "This check") reports its details on its own page. It has no log here.")
            } actions: {
                if let url = check.url { Button("Open Details") { openURL(url) } }
            }
        }
    }
}

/// The steps of a job that is queued or running.
struct JobStepsView: View {
    let steps: [JobStep]

    var body: some View {
        if steps.isEmpty {
            ContentUnavailableView(
                "Waiting for a Runner", systemImage: "clock",
                description: Text("The job's steps appear here when it starts.")
            )
        } else {
            List {
                Section {
                    ForEach(steps) { step in
                        HStack(spacing: Metrics.rowSpacing) {
                            StatusGlyph(state: step.state)
                            Text(step.name)
                                .font(Theme.Fonts.tableCell)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: Metrics.rowSpacing)
                            TimingText(state: step.state, startedAt: step.startedAt, completedAt: step.completedAt)
                        }
                        .padding(.vertical, Metrics.rowVerticalPadding)
                        .listRowSeparator(.hidden)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Steps")
                } footer: {
                    Text("The log appears when the job finishes.")
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

/// The log viewer: a bar with search and view options over the log text.
struct LogView: View {
    @Bindable var model: LogViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            LogTextView(
                rendered: model.rendered, wrapsLines: model.wrapsLines, matches: model.matches,
                focus: model.focus,
                onToggle: { model.toggleGroup(titledAt: $0) }
            )
        }
        .task(id: model.query) { await model.search() }
    }

    private var bar: some View {
        HStack(spacing: Metrics.rowSpacing) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Log", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { model.step(by: 1) }
                    .onExitCommand { model.query = "" }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .frame(width: Metrics.searchFieldWidth)

            if !model.query.isEmpty {
                Text(matchCount)
                    .font(Theme.Fonts.meta.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            ControlGroup {
                Button { model.step(by: -1) } label: { Label("Previous Match", systemImage: "chevron.up") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Previous match (⇧⌘G)")
                Button { model.step(by: 1) } label: { Label("Next Match", systemImage: "chevron.down") }
                    .keyboardShortcut("g", modifiers: .command)
                    .help("Next match (⌘G)")
            }
            .disabled(model.matches.isEmpty)
            .fixedSize()

            Spacer(minLength: 0)

            Toggle(isOn: $model.showTimestamps) { Label("Show Timestamps", systemImage: "clock") }
                .help("Show timestamps")
            Toggle(isOn: $model.wrapsLines) { Label("Wrap Lines", systemImage: "arrow.turn.down.left") }
                .help("Wrap long lines")
            Button { model.setAllExpanded(!model.allExpanded) } label: {
                Label(
                    model.allExpanded ? "Collapse All Groups" : "Expand All Groups",
                    systemImage: model.allExpanded
                        ? "arrow.down.and.line.horizontal.and.arrow.up" : "arrow.up.and.line.horizontal.and.arrow.down"
                )
            }
            .help(model.allExpanded ? "Collapse all groups" : "Expand all groups")
            .disabled(model.document.sections.isEmpty)
            Button { model.copyAll() } label: { Label("Copy Log", systemImage: "doc.on.doc") }
                .help("Copy the whole log")
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .controlSize(.small)
        .padding(.horizontal, Metrics.barHorizontalPadding)
        .padding(.vertical, Metrics.barVerticalPadding)
        .background(.bar)
        .background {
            // ⌘F has no visible control of its own.
            Button("Find in Log") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var matchCount: String {
        guard !model.matches.isEmpty else { return "No matches" }
        return "\((model.currentMatch ?? 0) + 1) of \(model.matches.count)"
    }
}

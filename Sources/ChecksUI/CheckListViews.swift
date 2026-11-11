import GitHubKit
import HermesUI
import SwiftUI

enum Metrics {
    static let listMinWidth: CGFloat = 220
    static let listIdealWidth: CGFloat = 280
    static let listMaxWidth: CGFloat = 420
    static let detailMinWidth: CGFloat = 360
    static let rowSpacing: CGFloat = 8
    static let rowVerticalPadding: CGFloat = 3
    static let glyphWidth: CGFloat = 18
    static let barHorizontalPadding: CGFloat = 12
    static let barVerticalPadding: CGFloat = 6
    static let searchFieldWidth: CGFloat = 200
    /// Lines the summary's title up with the Markdown under it.
    static let summaryInset: CGFloat = 24
}

/// The status glyph of a check or step. The shape differs per state; the
/// color only reinforces it.
struct StatusGlyph: View {
    let state: CheckState

    var body: some View {
        Image(systemName: state.symbol)
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: state == .running)
            .foregroundStyle(color)
            .frame(width: Metrics.glyphWidth)
            .accessibilityLabel(state.label)
            .help(state.label)
    }

    private var color: AnyShapeStyle {
        switch state {
        case .passed: AnyShapeStyle(.green)
        case .failed: AnyShapeStyle(.red)
        case .running, .actionRequired: AnyShapeStyle(.orange)
        case .queued, .skipped, .cancelled, .neutral: AnyShapeStyle(.secondary)
        }
    }
}

/// How long something took, or a ticking "running for 1m 4s" while it has not finished.
struct TimingText: View {
    let state: CheckState
    let startedAt: Date?
    let completedAt: Date?

    var body: some View {
        Group {
            if let startedAt, let completedAt {
                Text(CheckList.duration(from: startedAt, to: completedAt))
            } else if state == .running, let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("running for \(CheckList.duration(from: startedAt, to: context.date))")
                }
            } else if state == .queued {
                Text("queued")
            }
        }
        .font(Theme.Fonts.meta.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

extension TimingText {
    init(check: Check) {
        self.init(state: check.state, startedAt: check.run?.startedAt, completedAt: check.run?.completedAt)
    }
}

/// The checks grouped by workflow, with a selection.
struct CheckListView: View {
    let groups: [CheckGroup]
    @Binding var selection: Check.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.checks) { check in
                        CheckRow(check: check)
                            .tag(check.id)
                            .listRowSeparator(.hidden)
                            .contextMenu { CheckMenu(check: check) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Checks")
    }
}

/// The right-click menu of a check.
struct CheckMenu: View {
    let check: Check
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = check.url {
            Button("Open on GitHub") { openURL(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }
}

/// A check in the full list: glyph, name over the reporting app, and timing.
struct CheckRow: View {
    let check: Check

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            StatusGlyph(state: check.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.name)
                    .font(Theme.Fonts.tableCell)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = check.appName ?? check.statusDescription {
                    Text(detail)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Metrics.rowSpacing)
            TimingText(check: check)
        }
        .padding(.vertical, Metrics.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }
}

/// The bar under the list: the rollup and a refresh button. While the latest
/// refresh has failed, the reason replaces the rollup, which may be out of date.
struct CheckListFooter: View {
    let rollup: String
    var refreshError: String?
    let refresh: () -> Void

    var body: some View {
        HStack {
            Group {
                if let refreshError {
                    RefreshErrorLabel(message: refreshError)
                } else {
                    Text(rollup)
                }
            }
            .font(Theme.Fonts.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel("Refresh checks")
            .help("Refresh checks (⌘R)")
        }
        .padding(.horizontal, Metrics.barHorizontalPadding)
        .padding(.vertical, Metrics.barVerticalPadding)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Why the latest refresh failed, next to checks that may be out of date.
struct RefreshErrorLabel: View {
    let message: String

    var body: some View {
        Label("Couldn't refresh. \(message)", systemImage: "exclamationmark.triangle")
            .help(message)
    }
}

/// The compact list for an overview page: a rollup line, then one line per
/// check with failed checks first.
struct CheckSummaryList: View {
    let checks: [Check]
    let onSelect: (Check) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CheckList.rollup(checks))
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.bottom, 2)
            ForEach(CheckList.attentionFirst(checks)) { check in
                CheckSummaryRow(check: check) { onSelect(check) }
            }
        }
    }
}

private struct CheckSummaryRow: View {
    let check: Check
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.rowSpacing) {
                StatusGlyph(state: check.state)
                Text(check.name)
                    .font(Theme.Fonts.tableCell)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Metrics.rowSpacing)
                TimingText(check: check)
            }
            .padding(.vertical, Metrics.rowVerticalPadding)
            .padding(.horizontal, 4)
            .contentShape(.rect)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu { CheckMenu(check: check) }
        .accessibilityHint("Shows the check's details")
    }
}

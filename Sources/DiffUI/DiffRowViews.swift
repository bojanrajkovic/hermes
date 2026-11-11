import AppKit
import DiffKit
import HermesUI
import SwiftUI

// MARK: Hunk headers and notices

struct HunkHeaderRow: View {
    let header: HunkHeader
    let file: FileModel
    @Environment(\.diffMetrics) private var metrics

    /// How many lines one click on "expand up" or "expand down" reveals.
    private static let step = 20

    var body: some View {
        HStack(spacing: 6) {
            if header.hidden > 0 {
                if header.hidden > Self.step {
                    if header.canExpandDown {
                        button("Show \(Self.step) More Lines Below the Previous Change", "chevron.down", .down(Self.step))
                    }
                    if header.canExpandUp {
                        button("Show \(Self.step) More Lines Above the Next Change", "chevron.up", .up(Self.step))
                    }
                }
                button(header.hidden == 1 ? "Show the Hidden Line" : "Show All \(header.hidden) Hidden Lines", "arrow.up.and.down", .all)
            }
            Text(verbatim: label)
                .font(metrics.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DiffMetrics.gutterPadding)
        .padding(.vertical, DiffMetrics.hunkPadding)
        .background(Color.accentColor.opacity(0.08))
    }

    private var label: String {
        let hidden = header.hidden == 0 ? "" : header.hidden == 1 ? "1 hidden line" : "\(header.hidden) hidden lines"
        return [header.range, header.heading, hidden].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    private func button(_ title: String, _ symbol: String, _ amount: Expansion) -> some View {
        Button(title, systemImage: symbol) { file.expand(region: header.region, amount) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(title)
    }
}

struct NoticeRow: View {
    let notice: FileNotice
    let loadLargeDiff: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(text, systemImage: symbol)
                .foregroundStyle(.secondary)
            if case .large = notice {
                Button("Load Diff", action: loadLargeDiff)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, DiffMetrics.headerPaddingHorizontal)
        .padding(.vertical, 10)
    }

    private var text: String {
        switch notice {
        case .binary: "Binary file not shown."
        case .renamed(let from, let to): "Renamed from \(from) to \(to) without changes."
        case .copied(let from, let to): "Copied from \(from) to \(to) without changes."
        case .modeChanged(let old, let new): "File mode changed from \(old) to \(new)."
        case .empty: "Empty file."
        case .large(let lines): "Large diffs are not shown by default (\(lines.formatted()) lines)."
        }
    }

    private var symbol: String {
        switch notice {
        case .binary: "doc.zipper"
        case .renamed: "arrow.right"
        case .copied: "doc.on.doc"
        case .modeChanged: "lock.open"
        case .empty: "doc"
        case .large: "doc.text.magnifyingglass"
        }
    }
}

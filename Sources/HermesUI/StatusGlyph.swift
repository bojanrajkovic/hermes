import SwiftUI

/// The outcome a ``StatusGlyph`` shows.
public enum StatusKind: Sendable, Hashable {
    case passed
    case failed
    case pending
    /// Nothing reported.
    case none

    public var label: String {
        switch self {
        case .passed: "Checks passed"
        case .failed: "Checks failed"
        case .pending: "Checks running"
        case .none: "No checks"
        }
    }

    public var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .pending: "clock.fill"
        case .none: "circle.dashed"
        }
    }

    public var tint: Color {
        switch self {
        case .passed: .green
        case .failed: .red
        case .pending: .orange
        case .none: .secondary
        }
    }
}

/// A CI state as a symbol. Each state has its own shape, so the color is
/// never the only signal.
public struct StatusGlyph: View {
    private let kind: StatusKind

    public init(_ kind: StatusKind) {
        self.kind = kind
    }

    public var body: some View {
        Image(systemName: kind.symbol)
            .foregroundStyle(kind.tint)
            .help(kind.label)
            .accessibilityLabel(kind.label)
    }
}

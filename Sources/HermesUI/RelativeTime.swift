import SwiftUI

/// How long ago `date` was, in the shortest form a list row can show:
/// "now", "5m", "3h", "2d", "6w", "4mo", "2y".
public func compactAge(of date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    let minute = 60, hour = 3600, day = 86400
    switch seconds {
    case ..<minute: return "now"
    case ..<hour: return "\(seconds / minute)m"
    case ..<day: return "\(seconds / hour)h"
    case ..<(14 * day): return "\(seconds / day)d"
    case ..<(60 * day): return "\(seconds / (7 * day))w"
    case ..<(365 * day): return "\(seconds / (30 * day))mo"
    default: return "\(seconds / (365 * day))y"
    }
}

/// A compact age that updates each minute. The tooltip has the full date.
public struct RelativeTime: View {
    private let date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(compactAge(of: date, now: context.date))
                .monospacedDigit()
                .lineLimit(1)
        }
        .help(date.formatted(date: .abbreviated, time: .shortened))
        .accessibilityLabel(date.formatted(.relative(presentation: .named)))
    }
}

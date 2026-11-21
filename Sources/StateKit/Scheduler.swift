import Foundation

/// Something a screen shows, which the store keeps fresh while any screen shows it.
public enum Interest: Hashable, Sendable {
    /// An account's lists: its open pull requests, repositories, and opened issue lists.
    case account(String)
}

/// Runs one poll loop per interest while at least one screen shows it.
@MainActor
final class Scheduler {
    private var counts: [Interest: Int] = [:]
    private var loops: [Interest: Task<Void, Never>] = [:]
    private let tick: Duration
    private let poll: @MainActor (Interest) async -> Void

    /// - Parameters:
    ///   - tick: How long a loop waits between polls. `poll` decides whether a tick loads anything.
    ///   - poll: Loads the interest, or does nothing when it is fresh enough.
    init(tick: Duration, poll: @escaping @MainActor (Interest) async -> Void) {
        self.tick = tick
        self.poll = poll
    }

    /// The interests with a running loop.
    var polling: Set<Interest> { Set(loops.keys) }

    /// Keeps `interest` polled until the calling task is cancelled.
    func showing(_ interest: Interest) async {
        counts[interest, default: 0] += 1
        if loops[interest] == nil {
            loops[interest] = Task { [tick, poll] in
                while (try? await Task.sleep(for: tick)) != nil {
                    // A poll runs in its own task, so the last screen going away stops the loop
                    // without cancelling a refresh half done.
                    await Task { await poll(interest) }.value
                }
            }
        }

        // A stream that never finishes ends its loop only when the task is cancelled.
        for await _ in AsyncStream<Never>(Never.self, { _ in }) {}

        counts[interest, default: 1] -= 1
        if counts[interest] == 0 {
            counts[interest] = nil
            loops.removeValue(forKey: interest)?.cancel()
        }
    }
}

/// Whether a poll tick should refresh: always while Hermes is the active app, otherwise once
/// `backgroundInterval` has passed since the last refresh started.
func shouldRefresh(isActive: Bool, lastAttempt: Date?, backgroundInterval: TimeInterval, now: Date) -> Bool {
    guard !isActive, let lastAttempt else { return true }
    return now.timeIntervalSince(lastAttempt) >= backgroundInterval
}

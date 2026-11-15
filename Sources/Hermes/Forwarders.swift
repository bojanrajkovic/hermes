import Foundation
import GitHubKit
import os

/// The webhook forwarders Hermes runs, one per repository, so a change shows in seconds
/// instead of at the next refresh. A forwarder only says that something changed: Hermes then
/// loads it the usual way, and the refresh still runs, so a forwarder that ends costs nothing
/// but the delay. See `plans/webhooks.md`.
@Observable
@MainActor
final class Forwarders {
    typealias Target = WebhookForwarder.Target

    /// Each forwarder is a process and a webhook on its repository.
    static let limit = 20
    /// A forwarder that ran this long was working, so its end is not counted with earlier ones.
    static let settledAfter: TimeInterval = 300

    /// How long to wait before starting a repository's forwarder again, after it has ended
    /// `failures` times in a row: 30 seconds, doubling to 30 minutes at most.
    ///
    /// GitHub refuses a forwarder within seconds when the viewer is not an admin of the
    /// repository or it already has one, so most repositories that fail settle at the longest
    /// wait. One whose forwarder another Mac holds gets its turn when that Mac lets go.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(failures, 1) - 1)), 1800)
    }

    /// What to forward, most important first: the organizations of watched repositories, then
    /// the watched repositories the viewer owns, up to `limit` of those. No repeats, and none
    /// that is waiting to retry.
    ///
    /// A repository of an organization gets no forwarder of its own: the webhook is named `cli`
    /// and says nothing of who made it, which the other admins of a shared repository would
    /// have to puzzle over. An organization's own forwarder is one webhook its owner chose.
    ///
    /// - Parameter organizations: The organizations to forward whole: the ones the viewer
    ///   owns, when the token has the scope for it.
    static func targets(
        watched: [RepositoryRef], viewer: String, organizations: Set<String>, waiting: Set<Target>, limit: Int = limit
    ) -> [Target] {
        var seen: Set<Target> = []
        let wanted = watched.filter { organizations.contains($0.owner) }.map { Target.organization($0.owner) }
            + watched.filter { $0.owner == viewer }.map(Target.repository).uniqued().prefix(limit)
        return wanted.filter { !waiting.contains($0) && seen.insert($0).inserted }
    }

    private(set) var running: [Target: WebhookForwarder] = [:]
    /// When each running forwarder started, which also tells it from an earlier one of its target.
    private var startedAt: [Target: Date] = [:]
    /// How often each target's forwarder has ended in a row, and when it may start again.
    private var failures: [Target: (count: Int, retryAt: Date)] = [:]
    static let log = Logger(subsystem: "com.coderinserepeat.hermes", category: "webhooks")

    /// The targets whose forwarder ended and may not start again yet. They refresh on the timer.
    var waiting: Set<Target> {
        Set(failures.filter { $0.value.retryAt > .now }.keys)
    }

    /// Starts a forwarder for each wanted target that has none, and stops the others.
    /// Does nothing when the extension is not installed or `gh` has no token.
    func sync(to wanted: [Target], onEvent: @escaping @MainActor (WebhookEvent) -> Void) async {
        for (target, forwarder) in running where !wanted.contains(target) {
            running[target] = nil
            startedAt[target] = nil
            forwarder.stop()
        }
        let missing = wanted.filter { running[$0] == nil }
        guard !missing.isEmpty, let binary = WebhookForwarder.binary, let token = try? await GitHubAuth.token() else { return }

        for target in missing where running[target] == nil {
            let started = Date.now
            startedAt[target] = started
            do {
                running[target] = try WebhookForwarder(
                    target: target, binary: binary, token: token,
                    onEvent: { event in Task { @MainActor in onEvent(event) } },
                    onExit: { [weak self] error in Task { @MainActor in self?.ended(target, started: started, error: error) } }
                )
                Self.log.info("forwarding \(target.description, privacy: .public)")
            } catch {
                ended(target, started: started, error: error.localizedDescription)
            }
        }
    }

    func stopAll() {
        for forwarder in running.values { forwarder.stop() }
        running = [:]
        startedAt = [:]
    }

    /// Forgets a forwarder that ended on its own, and sets when its target may have another.
    /// One that was stopped has no start time, or by now the start time of its target's next one.
    private func ended(_ target: Target, started: Date, error: String) {
        guard startedAt[target] == started else { return }
        running[target] = nil
        startedAt[target] = nil

        let ran = Date.now.timeIntervalSince(started)
        let count = ran >= Self.settledAfter ? 1 : (failures[target]?.count ?? 0) + 1
        let delay = Self.retryDelay(afterFailures: count)
        failures[target] = (count, Date.now.addingTimeInterval(delay))
        Self.log.error("""
            forwarder for \(target.description, privacy: .public) ended after \(Int(ran)) s, \
            retry in \(Int(delay)) s: \(error.isEmpty ? "no error reported" : error, privacy: .public)
            """)
    }
}

private extension Sequence where Element: Hashable {
    /// The elements in order, each once.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

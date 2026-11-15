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

    /// The repositories to forward, most important first: the watched ones the viewer owns,
    /// without repeats and without those waiting to retry, up to `limit`.
    ///
    /// Only the viewer's own repositories: the webhook is named `cli` and says nothing of who
    /// made it, which an organization's other admins would have to puzzle over.
    static func repositories(
        watched: [RepositoryRef], viewer: String, waiting: Set<RepositoryRef>, limit: Int = limit
    ) -> [RepositoryRef] {
        var seen: Set<RepositoryRef> = []
        return Array(watched.filter { $0.owner == viewer && !waiting.contains($0) && seen.insert($0).inserted }.prefix(limit))
    }

    private(set) var running: [RepositoryRef: WebhookForwarder] = [:]
    /// When each running forwarder started, which also tells it from an earlier one of its repository.
    private var startedAt: [RepositoryRef: Date] = [:]
    /// How often each repository's forwarder has ended in a row, and when it may start again.
    private var failures: [RepositoryRef: (count: Int, retryAt: Date)] = [:]
    private static let log = Logger(subsystem: "com.coderinserepeat.hermes", category: "webhooks")

    /// The repositories whose forwarder ended and may not start again yet. They refresh on the timer.
    var waiting: Set<RepositoryRef> {
        Set(failures.filter { $0.value.retryAt > .now }.keys)
    }

    /// Starts a forwarder for each wanted repository that has none, and stops the others.
    /// Does nothing when the extension is not installed or `gh` has no token.
    func sync(to wanted: [RepositoryRef], onEvent: @escaping @MainActor (WebhookEvent) -> Void) async {
        for (repository, forwarder) in running where !wanted.contains(repository) {
            running[repository] = nil
            startedAt[repository] = nil
            forwarder.stop()
        }
        let missing = wanted.filter { running[$0] == nil }
        guard !missing.isEmpty, let binary = WebhookForwarder.binary, let token = try? await GitHubAuth.token() else { return }

        for repository in missing where running[repository] == nil {
            let started = Date.now
            startedAt[repository] = started
            do {
                running[repository] = try WebhookForwarder(
                    repository: repository, binary: binary, token: token,
                    onEvent: { event in Task { @MainActor in onEvent(event) } },
                    onExit: { [weak self] error in Task { @MainActor in self?.ended(repository, started: started, error: error) } }
                )
                Self.log.info("forwarding \(repository.description, privacy: .public)")
            } catch {
                ended(repository, started: started, error: error.localizedDescription)
            }
        }
    }

    func stopAll() {
        for forwarder in running.values { forwarder.stop() }
        running = [:]
        startedAt = [:]
    }

    /// Forgets a forwarder that ended on its own, and sets when its repository may have another.
    /// One that was stopped has no start time, or by now the start time of its repository's next one.
    private func ended(_ repository: RepositoryRef, started: Date, error: String) {
        guard startedAt[repository] == started else { return }
        running[repository] = nil
        startedAt[repository] = nil

        let ran = Date.now.timeIntervalSince(started)
        let count = ran >= Self.settledAfter ? 1 : (failures[repository]?.count ?? 0) + 1
        let delay = Self.retryDelay(afterFailures: count)
        failures[repository] = (count, Date.now.addingTimeInterval(delay))
        Self.log.error("""
            forwarder for \(repository.description, privacy: .public) ended after \(Int(ran)) s, \
            retry in \(Int(delay)) s: \(error.isEmpty ? "no error reported" : error, privacy: .public)
            """)
    }
}

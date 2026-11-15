import Foundation
import GitHubKit

/// The webhook forwarders Hermes runs, one per repository, so a change shows in seconds
/// instead of at the next refresh. A forwarder only says that something changed: Hermes then
/// loads it the usual way, and the refresh still runs, so a forwarder that ends costs nothing
/// but the delay. See `plans/webhooks.md`.
@Observable
@MainActor
final class Forwarders {
    /// Each forwarder is a process and a webhook on its repository.
    static let limit = 20
    /// A forwarder that ends this soon after it starts was refused by GitHub: the viewer is not
    /// an admin of the repository, or it already has a forwarder.
    static let refusalWindow: TimeInterval = 30

    /// The repositories to forward, most important first: the watched ones the viewer owns,
    /// without repeats and without those GitHub refused, up to `limit`.
    ///
    /// Only the viewer's own repositories: the webhook is named `cli` and says nothing of who
    /// made it, which an organization's other admins would have to puzzle over.
    static func repositories(
        watched: [RepositoryRef], viewer: String, refused: Set<RepositoryRef>, limit: Int = limit
    ) -> [RepositoryRef] {
        var seen: Set<RepositoryRef> = []
        return Array(watched.filter { $0.owner == viewer && !refused.contains($0) && seen.insert($0).inserted }.prefix(limit))
    }

    private(set) var running: [RepositoryRef: WebhookForwarder] = [:]
    /// When each running forwarder started, which also tells it from an earlier one of its repository.
    private var startedAt: [RepositoryRef: Date] = [:]
    /// Repositories GitHub refused a forwarder for. They refresh on the timer until Hermes quits.
    private(set) var refused: Set<RepositoryRef> = []

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
            running[repository] = try? WebhookForwarder(
                repository: repository, binary: binary, token: token,
                onEvent: { event in Task { @MainActor in onEvent(event) } },
                onExit: { [weak self] in Task { @MainActor in self?.ended(repository, started: started) } }
            )
        }
    }

    func stopAll() {
        for forwarder in running.values { forwarder.stop() }
        running = [:]
        startedAt = [:]
    }

    /// Forgets a forwarder that ended on its own. One that was stopped has no start time, or by
    /// now the start time of its repository's next one.
    private func ended(_ repository: RepositoryRef, started: Date) {
        guard startedAt[repository] == started else { return }
        running[repository] = nil
        if Date.now.timeIntervalSince(started) < Self.refusalWindow { refused.insert(repository) }
    }
}

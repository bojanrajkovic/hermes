import Foundation
import os

/// What a webhook delivery says changed.
public struct WebhookEvent: Sendable, Hashable {
    public let repository: RepositoryRef
    /// The pull request the event is about. Nil when it names none, such as a commit status.
    public let pullRequest: Int?

    public init(repository: RepositoryRef, pullRequest: Int?) {
        self.repository = repository
        self.pullRequest = pullRequest
    }

    /// Reads one delivery's JSON body. Nil for a body that names no repository, and for the
    /// `ping` GitHub sends when a webhook is created.
    public init?(payload: Data) {
        struct Payload: Decodable {
            struct Repository: Decodable {
                struct Owner: Decodable { let login: String }
                let name: String
                let owner: Owner
            }
            struct Numbered: Decodable { let number: Int }
            struct Issue: Decodable {
                let number: Int
                /// Present when the issue is a pull request.
                let pull_request: Empty?
            }
            struct Checks: Decodable { let pull_requests: [Numbered]? }
            struct Empty: Decodable {}

            let zen: String?
            let repository: Repository?
            let pull_request: Numbered?
            let issue: Issue?
            let check_suite: Checks?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: payload),
              payload.zen == nil, let repository = payload.repository else { return nil }
        self.repository = RepositoryRef(owner: repository.owner.login, name: repository.name)
        pullRequest = payload.pull_request?.number
            ?? payload.issue.flatMap { $0.pull_request == nil ? nil : $0.number }
            ?? payload.check_suite?.pull_requests?.first?.number
    }
}

/// One running `gh webhook forward`: GitHub sends a repository's or an organization's webhook
/// deliveries down a WebSocket, and the `cli/gh-webhook` extension prints each as a line of JSON.
///
/// Starting one creates a webhook named `cli` on its target, which needs admin rights there.
/// GitHub allows one per target and deletes it when the process ends.
public final class WebhookForwarder: Sendable {
    /// What a forwarder listens to.
    public enum Target: Sendable, Hashable, CustomStringConvertible {
        case repository(RepositoryRef)
        /// Every repository of an organization. Needs the token scope `admin:org_hook`.
        case organization(String)

        public var description: String {
            switch self {
            case .repository(let repository): repository.description
            case .organization(let login): login
            }
        }

        var arguments: [String] {
            switch self {
            case .repository(let repository): ["--repo", repository.description]
            case .organization(let login): ["--org", login]
            }
        }
    }

    /// The token scope an organization's forwarder needs. `gh` does not ask for it at login.
    public static let organizationScope = "admin:org_hook"
    /// The events that change what a pull request's row or pane shows.
    static let events = "pull_request,pull_request_review,pull_request_review_comment,issue_comment,check_suite,status"
    /// Passed as the webhook's secret. It marks the processes Hermes started, so a launch can
    /// find the ones a crash left behind.
    static let marker = "hermes-forwarder"

    public let target: Target
    private let process = Process()

    /// The extension's program, when it is installed. Hermes runs it directly: `gh webhook`
    /// starts it as a child that outlives a signal sent to `gh`.
    public static var binary: URL? {
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share")
        let binary = data.appending(path: "gh/extensions/gh-webhook/gh-webhook")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    /// Installs the extension with `gh extension install cli/gh-webhook`.
    ///
    /// - Throws: `GitHubError.ghNotInstalled`, or `GitHubError.commandFailed` with what `gh` printed.
    public static func install() async throws {
        guard let gh = await GitHubAuth.locateGH() else { throw GitHubError.ghNotInstalled }
        let result = try await GitHubAuth.run(gh, ["extension", "install", "cli/gh-webhook"], timeout: 120)
        guard result.status == 0 else {
            throw GitHubError.commandFailed(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Ends the forwarders an earlier run of Hermes left behind. Each holds its target's
    /// one webhook, so a new forwarder there fails until it is gone.
    public static func endLeftovers() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "--", "--secret \(marker)"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    /// Starts forwarding a target's events.
    ///
    /// - Parameters:
    ///   - token: A GitHub token. The extension cannot read the one `gh` keeps in the keychain.
    ///   - onEvent: Called for each delivery, on a background queue.
    ///   - onExit: Called once when the process ends for any reason, `stop()` included, with
    ///     what the extension reported, or an empty string. GitHub refusing the webhook ends it
    ///     within a few seconds: the viewer is not an admin, or the repository already has a
    ///     forwarder.
    public init(
        target: Target, binary: URL, token: String,
        onEvent: @escaping @Sendable (WebhookEvent) -> Void, onExit: @escaping @Sendable (_ error: String) -> Void
    ) throws {
        self.target = target
        let output = Pipe()
        process.executableURL = binary
        process.arguments = ["forward"] + target.arguments + ["--events", Self.events, "--secret", Self.marker]
        process.environment = ProcessInfo.processInfo.environment.merging(["GH_TOKEN": token]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors

        // The extension logs each delivery to stderr too. Only what it says when it gives up is kept.
        let reported = OSAllocatedUnfairLock(initialState: "")
        errors.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            reported.withLock { $0 = Self.failure(in: $0 + text) }
        }

        // One delivery is one line, and a read can end in the middle of one.
        nonisolated(unsafe) var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                if let event = WebhookEvent(payload: buffer[..<newline]) { onEvent(event) }
                buffer.removeSubrange(...newline)
            }
        }
        process.terminationHandler = { _ in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            onExit(reported.withLock { $0 })
        }
        try process.run()
    }

    /// The lines of the extension's stderr that say why it gave up: from `Error:` up to the
    /// usage text it prints after. Empty when it has reported no error.
    static func failure(in stderr: String) -> String {
        guard let start = stderr.range(of: "Error:") else { return "" }
        let message = stderr[start.lowerBound...]
        return message[..<(message.range(of: "\nUsage:")?.lowerBound ?? message.endIndex)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func stop() {
        process.terminate()
    }
}

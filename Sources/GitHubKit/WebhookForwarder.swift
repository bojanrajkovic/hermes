import Foundation

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

/// One running `gh webhook forward`: GitHub sends a repository's webhook deliveries down a
/// WebSocket, and the `cli/gh-webhook` extension prints each as a line of JSON.
///
/// Starting one creates a webhook named `cli` on the repository, which needs admin rights
/// there. GitHub allows one per repository and deletes it when the process ends.
public final class WebhookForwarder: Sendable {
    /// The events that change what a pull request's row or pane shows.
    static let events = "pull_request,pull_request_review,pull_request_review_comment,issue_comment,check_suite,status"
    /// Passed as the webhook's secret. It marks the processes Hermes started, so a launch can
    /// find the ones a crash left behind.
    static let marker = "hermes-forwarder"

    public let repository: RepositoryRef
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

    /// Ends the forwarders an earlier run of Hermes left behind. Each holds its repository's
    /// one webhook, so a new forwarder there fails until it is gone.
    public static func endLeftovers() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "--", "--secret \(marker)"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    /// Starts forwarding a repository's events.
    ///
    /// - Parameters:
    ///   - token: A GitHub token. The extension cannot read the one `gh` keeps in the keychain.
    ///   - onEvent: Called for each delivery, on a background queue.
    ///   - onExit: Called once when the process ends for any reason, `stop()` included. GitHub
    ///     refusing the webhook ends it within a few seconds: the viewer is not an admin, or
    ///     the repository already has a forwarder.
    public init(
        repository: RepositoryRef, binary: URL, token: String,
        onEvent: @escaping @Sendable (WebhookEvent) -> Void, onExit: @escaping @Sendable () -> Void
    ) throws {
        self.repository = repository
        let output = Pipe()
        process.executableURL = binary
        process.arguments = ["forward", "--repo", repository.description, "--events", Self.events, "--secret", Self.marker]
        process.environment = ProcessInfo.processInfo.environment.merging(["GH_TOKEN": token]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

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
            onExit()
        }
        try process.run()
    }

    public func stop() {
        process.terminate()
    }
}

import Foundation

/// A check run: one job reported through the Checks API, by GitHub Actions or
/// another app.
public struct CheckRun: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable, Decodable {
        case requested = "REQUESTED"
        case queued = "QUEUED"
        case inProgress = "IN_PROGRESS"
        case completed = "COMPLETED"
        case waiting = "WAITING"
        case pending = "PENDING"
    }

    public enum Conclusion: String, Sendable, Hashable, Decodable {
        case success = "SUCCESS"
        case failure = "FAILURE"
        case neutral = "NEUTRAL"
        case cancelled = "CANCELLED"
        case timedOut = "TIMED_OUT"
        case actionRequired = "ACTION_REQUIRED"
        case skipped = "SKIPPED"
        case startupFailure = "STARTUP_FAILURE"
        case stale = "STALE"
    }

    /// The GitHub Actions workflow a job belongs to.
    public struct Workflow: Sendable, Hashable {
        public let name: String
        public let runID: Int

        public init(name: String, runID: Int) {
            self.name = name
            self.runID = runID
        }
    }

    /// The REST ID. For a GitHub Actions job this is also the job ID that
    /// `GitHubClient.jobLogs(repository:jobID:)` takes.
    public let databaseID: Int
    public let name: String
    public let status: Status
    /// Nil until `status` is `completed`.
    public let conclusion: Conclusion?
    /// Nil until the run starts.
    public let startedAt: Date?
    /// Nil until the run completes.
    public let completedAt: Date?
    public let detailsURL: URL?
    /// The app that reported the run, such as "GitHub Actions".
    public let appName: String?
    /// Nil when the run is not a GitHub Actions job. Such a run has no logs.
    public let workflow: Workflow?

    public init(
        databaseID: Int, name: String, status: Status, conclusion: Conclusion?, startedAt: Date?,
        completedAt: Date?, detailsURL: URL?, appName: String?, workflow: Workflow?
    ) {
        self.databaseID = databaseID
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.detailsURL = detailsURL
        self.appName = appName
        self.workflow = workflow
    }
}

extension CheckRun: Decodable {
    private enum CodingKeys: String, CodingKey {
        case databaseId, name, status, conclusion, startedAt, completedAt, detailsUrl, checkSuite
    }

    private struct Suite: Decodable {
        struct App: Decodable { let name: String }
        struct WorkflowRun: Decodable {
            struct Workflow: Decodable { let name: String }
            let databaseId: Int
            let workflow: Workflow
        }
        let app: App?
        let workflowRun: WorkflowRun?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        databaseID = try container.decode(Int.self, forKey: .databaseId)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(Status.self, forKey: .status)
        conclusion = try container.decodeIfPresent(Conclusion.self, forKey: .conclusion)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        detailsURL = try container.decodeIfPresent(URL.self, forKey: .detailsUrl)

        let suite = try container.decode(Suite.self, forKey: .checkSuite)
        appName = suite.app?.name
        workflow = suite.workflowRun.map { Workflow(name: $0.workflow.name, runID: $0.databaseId) }
    }
}

/// A legacy commit status, reported through the Statuses API.
public struct StatusContext: Sendable, Hashable, Decodable {
    /// The status's name, such as "ci/circleci: build".
    public let context: String
    public let state: StatusState
    public let targetURL: URL?
    public let description: String?

    public init(context: String, state: StatusState, targetURL: URL?, description: String?) {
        self.context = context
        self.state = state
        self.targetURL = targetURL
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case context, state, description
        case targetURL = "targetUrl"
    }
}

/// One entry in a commit's list of checks.
public enum Check: Sendable, Hashable, Identifiable {
    case run(CheckRun)
    case status(StatusContext)

    /// The outcome of a check, reduced to what a list shows.
    public enum Outcome: Sendable, Hashable {
        /// Queued or running.
        case pending
        case passed
        /// Failed, errored, timed out, was cancelled, or needs action.
        case failed
        /// Skipped, or finished with a neutral conclusion.
        case skipped
    }

    /// Unique among the checks of one commit.
    public var id: String {
        switch self {
        case .run(let run): "run-\(run.databaseID)"
        case .status(let status): "status-\(status.context)"
        }
    }

    public var name: String {
        switch self {
        case .run(let run): run.name
        case .status(let status): status.context
        }
    }

    /// The page with the check's details.
    public var url: URL? {
        switch self {
        case .run(let run): run.detailsURL
        case .status(let status): status.targetURL
        }
    }

    public var outcome: Outcome {
        switch self {
        case .run(let run):
            guard run.status == .completed, let conclusion = run.conclusion else { return .pending }
            switch conclusion {
            case .success: return .passed
            case .neutral, .skipped: return .skipped
            case .failure, .cancelled, .timedOut, .actionRequired, .startupFailure, .stale: return .failed
            }
        case .status(let status):
            switch status.state {
            case .success: return .passed
            case .failure, .error: return .failed
            case .pending, .expected: return .pending
            }
        }
    }
}

extension Check: Decodable {
    private enum CodingKeys: String, CodingKey { case typename = "__typename" }

    public init(from decoder: any Decoder) throws {
        let typename = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .typename)
        switch typename {
        case "CheckRun": self = .run(try CheckRun(from: decoder))
        case "StatusContext": self = .status(try StatusContext(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unknown check type \(typename)"
            ))
        }
    }
}

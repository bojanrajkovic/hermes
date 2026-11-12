import Foundation
import GitHubKit

/// What a check's glyph and status label show. Finer than `Check.Outcome`,
/// which folds cancelled and action-required checks into "failed".
enum CheckState: Sendable, Hashable, CaseIterable {
    case passed, failed, running, queued, skipped, cancelled, neutral, actionRequired

    init(_ check: Check) {
        switch check {
        case .run(let run): self.init(status: run.status, conclusion: run.conclusion)
        case .status(let status):
            switch status.state {
            case .success: self = .passed
            case .failure, .error: self = .failed
            case .pending, .expected: self = .queued
            }
        }
    }

    init(status: CheckRun.Status, conclusion: CheckRun.Conclusion?) {
        guard status == .completed, let conclusion else {
            self = status == .inProgress ? .running : .queued
            return
        }
        switch conclusion {
        case .success: self = .passed
        case .failure, .timedOut, .startupFailure: self = .failed
        case .cancelled: self = .cancelled
        case .skipped: self = .skipped
        case .neutral, .stale: self = .neutral
        case .actionRequired: self = .actionRequired
        }
    }

    var isPending: Bool { self == .running || self == .queued }

    var label: String {
        switch self {
        case .passed: "Passed"
        case .failed: "Failed"
        case .running: "Running"
        case .queued: "Queued"
        case .skipped: "Skipped"
        case .cancelled: "Cancelled"
        case .neutral: "Neutral"
        case .actionRequired: "Action required"
        }
    }

    /// Each state has its own shape, so the glyph reads without its color.
    var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .queued: "clock"
        case .skipped: "slash.circle"
        case .cancelled: "stop.circle"
        case .neutral: "minus.circle"
        case .actionRequired: "exclamationmark.triangle.fill"
        }
    }

    /// Position in a list that puts what needs attention first.
    var attentionRank: Int {
        switch self {
        case .failed: 0
        case .actionRequired: 1
        case .cancelled: 2
        case .running: 3
        case .queued: 4
        case .passed: 5
        case .neutral: 6
        case .skipped: 7
        }
    }
}

/// The checks of one workflow, or the checks that belong to none.
struct CheckGroup: Identifiable, Equatable {
    /// The workflow's name. Nil for checks from other apps and legacy statuses.
    let workflow: String?
    var checks: [Check]

    var id: String { workflow ?? "" }
    var title: String { workflow ?? "Other checks" }
}

enum CheckList {
    /// Groups checks by workflow name, in order of first appearance, with the
    /// checks that have no workflow last.
    static func grouped(_ checks: [Check]) -> [CheckGroup] {
        var groups: [CheckGroup] = []
        var other: [Check] = []
        for check in checks {
            guard case .run(let run) = check, let workflow = run.workflow else {
                other.append(check)
                continue
            }
            if let index = groups.firstIndex(where: { $0.workflow == workflow.name }) {
                groups[index].checks.append(check)
            } else {
                groups.append(CheckGroup(workflow: workflow.name, checks: [check]))
            }
        }
        if !other.isEmpty { groups.append(CheckGroup(workflow: nil, checks: other)) }
        return groups
    }

    /// Failed checks first, then the ones still running, then the rest.
    /// Checks in the same state keep GitHub's order.
    static func attentionFirst(_ checks: [Check]) -> [Check] {
        checks.enumerated()
            .sorted { ($0.element.state.attentionRank, $0.offset) < ($1.element.state.attentionRank, $1.offset) }
            .map(\.element)
    }

    /// A one-line count by state, such as "7 passed, 1 failed".
    static func rollup(_ checks: [Check]) -> String {
        let counts = Dictionary(grouping: checks, by: \.state).mapValues(\.count)
        let order: [CheckState] = [.passed, .failed, .cancelled, .actionRequired, .running, .queued, .skipped, .neutral]
        let parts = order.compactMap { state in counts[state].map { "\($0) \(state.label.lowercased())" } }
        return parts.isEmpty ? "No checks" : parts.joined(separator: ", ")
    }

    /// The check to select when the list first loads: the first failed one, or the first.
    static func defaultSelection(_ checks: [Check]) -> Check.ID? {
        (checks.first { $0.state == .failed } ?? checks.first)?.id
    }

    /// A duration as "2m 10s". Under a second shows as "0s".
    static func duration(from start: Date, to end: Date) -> String {
        Duration.seconds(max(0, end.timeIntervalSince(start).rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}

extension Check {
    var state: CheckState { CheckState(self) }

    var run: CheckRun? {
        if case .run(let run) = self { run } else { nil }
    }

    /// The app that reported the check. A legacy status does not say.
    var appName: String? { run?.appName }

    /// What a legacy status says about itself.
    var statusDescription: String? {
        if case .status(let status) = self, status.description?.isEmpty == false { status.description } else { nil }
    }

    /// The time a finished check took. Nil for legacy statuses and checks that have not finished.
    var duration: String? {
        guard let run, let start = run.startedAt, let end = run.completedAt else { return nil }
        return CheckList.duration(from: start, to: end)
    }

    /// The Actions job behind the check, when there is one.
    var jobID: Int? { run?.workflow == nil ? nil : run?.databaseID }

    /// Whether GitHub can run the check again: an Actions job that failed or was cancelled.
    /// Other apps' checks and legacy statuses are run again by their own service.
    var canRerun: Bool { jobID != nil && [.failed, .cancelled].contains(state) }
}

extension CheckList {
    /// The workflow runs that have a job to run again, each once, in list order.
    static func rerunnableRuns(_ checks: [Check]) -> [Int] {
        var seen = Set<Int>()
        return checks.compactMap { check in
            guard check.canRerun, let id = check.run?.workflow?.runID, seen.insert(id).inserted else { return nil }
            return id
        }
    }
}

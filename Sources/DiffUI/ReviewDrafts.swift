import DiffKit
import Foundation
import GitHubKit

/// A comment the user has added to their pending review. It stays on this
/// Mac until the review is submitted.
struct DraftComment: Codable, Hashable, Identifiable, Sendable {
    /// A line on one side of the diff, in a form that can be saved.
    struct Position: Codable, Hashable, Sendable {
        /// `LEFT` or `RIGHT`, as GitHub spells it.
        let side: String
        let line: Int
    }

    enum Target: Codable, Hashable, Sendable {
        /// A new thread on a line, or on the lines from `start` to `end`.
        case line(path: String, start: Position?, end: Position)
        /// A reply to the thread with this `ReviewThread.id`.
        case reply(threadID: String)
    }

    let id: UUID
    var target: Target
    /// Markdown.
    var body: String

    init(id: UUID = UUID(), target: Target, body: String) {
        self.id = id
        self.target = target
        self.body = body
    }

    init(anchor: CommentAnchor, body: String) {
        self.init(target: .line(path: anchor.path, start: anchor.start.map(Position.init), end: Position(anchor.end)), body: body)
    }

    /// Where a new thread goes. `nil` for a reply.
    var anchor: CommentAnchor? {
        guard case .line(let path, let start, let end) = target else { return nil }
        return CommentAnchor(path: path, start: start?.diffPosition, end: end.diffPosition)
    }
}

extension DraftComment.Position {
    init(_ position: DiffPosition) {
        self.init(side: position.side.rawValue, line: position.line)
    }

    var diffPosition: DiffPosition {
        DiffPosition(side: DiffKit.DiffSide(rawValue: side) ?? .right, line: line)
    }
}

/// Everything about a pull request's unsubmitted review that is kept on disk.
struct PendingReview: Codable, Hashable, Sendable {
    var comments: [DraftComment] = []
    /// The review summary typed so far.
    var summary = ""

    /// A comment that was being written, with the text typed so far.
    struct Composer: Codable, Hashable, Sendable {
        enum Target: Codable, Hashable, Sendable {
            /// A new thread or a reply.
            case new(DraftComment.Target)
            /// A change to the text of one of `comments`.
            case edit(draft: DraftComment.ID)
        }

        var target: Target
        var text: String
    }

    /// The comment being written. `nil` when there is none or it has no text.
    var composer: Composer?

    /// Where the pending review of a pull request is saved:
    /// `<root>/drafts/<owner>/<repo>/<number>.json`.
    static func url(root: URL, repository: RepositoryRef, number: Int) -> URL {
        root.appending(path: "drafts/\(repository.owner)/\(repository.name)/\(number).json")
    }

    /// `~/Library/Application Support/Hermes`.
    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Hermes")
    }

    /// Reads a saved review. A missing or unreadable file gives an empty one.
    static func load(from url: URL) -> PendingReview {
        guard let data = try? Data(contentsOf: url) else { return PendingReview() }
        return (try? JSONDecoder().decode(PendingReview.self, from: data)) ?? PendingReview()
    }

    /// Writes the review, or removes the file when there is nothing to keep.
    func save(to url: URL) throws {
        if comments.isEmpty, summary.isEmpty, composer == nil {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

extension ReviewThread {
    /// The thread's place in the current diff, or `nil` when GitHub reports it as outdated.
    var anchor: CommentAnchor? {
        guard let line, !isOutdated else { return nil }
        let end = DiffPosition(side: DiffKit.DiffSide(diffSide), line: line)
        let start = startLine.map { DiffPosition(side: DiffKit.DiffSide(startDiffSide ?? diffSide), line: $0) }
        return CommentAnchor(path: path, start: start == end ? nil : start, end: end)
    }
}

extension DiffKit.DiffSide {
    init(_ side: GitHubKit.DiffSide) {
        self = side == .left ? .left : .right
    }
}

/// What sits under one line of the diff.
/// The mark in the diff for a line that has comments.
struct LineBadge: Hashable, Sendable {
    enum Style: Hashable, Sendable {
        /// An unresolved thread, and nothing of the user's.
        case open
        /// Only resolved threads.
        case resolved
        /// A pending comment of the user's, or the comment being written.
        case draft
    }

    /// Threads and new-thread drafts. 0 for a line with only the comment being written.
    let count: Int
    let style: Style
}

struct LineItems: Hashable, Sendable {
    var threads: [ReviewThread] = []
    var drafts: [DraftComment] = []
}

/// Threads and drafts matched against a diff.
struct ReviewLayout: Hashable, Sendable {
    /// Threads and new-thread drafts by the line they are shown under.
    var lines: [FileDiff.ID: [DiffLine.Numbers: LineItems]] = [:]
    /// The other lines of multi-line threads and drafts, which get a range mark in the gutter.
    var rangeLines: [FileDiff.ID: Set<DiffLine.Numbers>] = [:]
    /// Reply drafts by the thread they answer.
    var replies: [String: [DraftComment]] = [:]
    /// Threads GitHub marks outdated, or whose line is not in the diff.
    var offDiffThreads: [ReviewThread] = []
    /// Drafts whose line is no longer in the diff, and replies to threads
    /// that no longer exist. They are left out of a submission.
    var outdatedDrafts: [DraftComment] = []

    /// The drafts a submission sends, in the order they were written.
    var submittable: [DraftComment] = []

    init() {}

    init(diff: Diff, threads: [ReviewThread], drafts: [DraftComment]) {
        let files = Dictionary(diff.files.map { ($0.id, $0) }) { first, _ in first }
        func numbers(_ file: FileDiff.ID, _ location: LineLocation) -> DiffLine.Numbers? {
            files[file]?.hunks[location.hunkIndex].lines[location.lineIndex].numbers
        }
        func markRange(_ file: FileDiff.ID, from start: LineLocation?, to end: LineLocation) {
            guard let start, start.hunkIndex == end.hunkIndex, start < end, let lines = files[file]?.hunks[end.hunkIndex].lines else { return }
            rangeLines[file, default: []].formUnion(lines[start.lineIndex...end.lineIndex].map(\.numbers))
        }

        let placedThreads = diff.place(threads, anchor: \.anchor)
        offDiffThreads = placedThreads.unplaced
        for placed in placedThreads.placed {
            guard let line = numbers(placed.fileID, placed.end) else { continue }
            lines[placed.fileID, default: [:]][line, default: LineItems()].threads.append(placed.thread)
            markRange(placed.fileID, from: placed.start, to: placed.end)
        }

        let threadIDs = Set(threads.map(\.id))
        var lineDrafts: [DraftComment] = []
        for draft in drafts {
            switch draft.target {
            case .line: lineDrafts.append(draft)
            case .reply(let threadID) where threadIDs.contains(threadID): replies[threadID, default: []].append(draft)
            case .reply: outdatedDrafts.append(draft)
            }
        }
        let placedDrafts = diff.place(lineDrafts, anchor: \.anchor)
        outdatedDrafts += placedDrafts.unplaced
        for placed in placedDrafts.placed {
            // A range that lost its first line would be sent as a different comment, so it counts as outdated.
            guard let line = numbers(placed.fileID, placed.end),
                  placed.thread.anchor?.start == nil || placed.start?.hunkIndex == placed.end.hunkIndex
            else {
                outdatedDrafts.append(placed.thread)
                continue
            }
            lines[placed.fileID, default: [:]][line, default: LineItems()].drafts.append(placed.thread)
            markRange(placed.fileID, from: placed.start, to: placed.end)
        }
        let outdated = Set(outdatedDrafts.map(\.id))
        submittable = drafts.filter { !outdated.contains($0.id) }
    }

    /// The badge each line with comments gets in the diff.
    ///
    /// - Parameter writing: The line the comment being written belongs to: its new thread's line, the line of
    ///   the thread it replies to, or the line of the draft it edits.
    func badges(writing: ReviewModel.LineRef?) -> [FileDiff.ID: [DiffLine.Numbers: LineBadge]] {
        var badges: [FileDiff.ID: [DiffLine.Numbers: LineBadge]] = [:]
        for (file, items) in lines {
            for (line, item) in items {
                let hasDraft = !item.drafts.isEmpty || item.threads.contains { replies[$0.id] != nil }
                let style: LineBadge.Style = if hasDraft || writing == ReviewModel.LineRef(file: file, line: line) {
                    .draft
                } else if item.threads.contains(where: { !$0.isResolved }) {
                    .open
                } else {
                    .resolved
                }
                badges[file, default: [:]][line] = LineBadge(count: item.threads.count + item.drafts.count, style: style)
            }
        }
        if let writing, badges[writing.file]?[writing.line] == nil {
            badges[writing.file, default: [:]][writing.line] = LineBadge(count: 0, style: .draft)
        }
        return badges
    }

    /// The line a thread is shown at.
    func line(of thread: String) -> ReviewModel.LineRef? {
        for (file, items) in lines {
            if let line = items.first(where: { $0.value.threads.contains { $0.id == thread } })?.key {
                return ReviewModel.LineRef(file: file, line: line)
            }
        }
        return nil
    }

    /// The line a new-thread draft is shown at.
    func line(ofDraft draft: DraftComment.ID) -> ReviewModel.LineRef? {
        for (file, items) in lines {
            if let line = items.first(where: { $0.value.drafts.contains { $0.id == draft } })?.key {
                return ReviewModel.LineRef(file: file, line: line)
            }
        }
        if let thread = replies.first(where: { $0.value.contains { $0.id == draft } })?.key { return line(of: thread) }
        return nil
    }

    /// Comment counts by new-file line number, for the rendered Markdown view's badges.
    func markers(for file: FileDiff.ID) -> [Int: Int] {
        var markers: [Int: Int] = [:]
        for (numbers, items) in lines[file] ?? [:] {
            let line: Int? = switch numbers {
            case .addition(let new), .context(_, let new): new
            case .deletion: nil
            }
            if let line { markers[line] = items.threads.count + items.drafts.count }
        }
        return markers
    }
}

extension ReviewSubmission {
    /// The submission that sends `drafts` in one review.
    init(pullRequestID: String, commitOID: String, event: Event, body: String, drafts: [DraftComment]) {
        var threads: [Thread] = []
        var replies: [Reply] = []
        for draft in drafts {
            switch draft.target {
            case .line(let path, let start, let end):
                threads.append(Thread(path: path, start: start?.submission, end: end.submission, body: draft.body))
            case .reply(let threadID):
                replies.append(Reply(threadID: threadID, body: draft.body))
            }
        }
        self.init(pullRequestID: pullRequestID, commitOID: commitOID, event: event, body: body, threads: threads, replies: replies)
    }
}

extension DraftComment.Position {
    fileprivate var submission: ReviewSubmission.Position {
        ReviewSubmission.Position(line: line, side: side == "LEFT" ? .left : .right)
    }
}

/// A sentence for the user about why a range cannot hold a comment.
func explanation(for error: RangeSelectionError) -> String {
    switch error {
    case .notInDiff(let position):
        "Line \(position.line) is not part of the diff. GitHub only accepts comments on changed lines and the few unchanged lines shown around them."
    case .differentHunks:
        "A comment can't span two separate blocks of changes. Select lines within one block."
    }
}

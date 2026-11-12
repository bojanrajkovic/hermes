import DiffKit
import Foundation
import GitHubKit
import Observation

/// The review of one pull request: its threads on GitHub, the user's pending
/// comments, and the comment being written.
@Observable @MainActor
final class ReviewModel {
    /// The comment being written. There is one at a time.
    struct Composer: Equatable {
        enum Target: Equatable {
            /// A new thread at `anchor`, written under the line `under` of `file`.
            case thread(file: FileDiff.ID, under: DiffLine.Numbers, anchor: CommentAnchor)
            case reply(threadID: String)
            case edit(draft: DraftComment.ID)
        }

        var target: Target
        var text = ""
    }

    /// A line of a file.
    struct LineRef: Hashable {
        let file: FileDiff.ID
        let line: DiffLine.Numbers
    }

    /// A message shown under a line (or under a file's rendered Markdown when `line` is `nil`).
    struct Notice: Equatable {
        let file: FileDiff.ID
        let line: DiffLine.Numbers?
        let text: String
    }

    enum Submission: Equatable {
        case idle
        case sending
        case failed(String)
    }

    let pullRequest: PullRequest
    private(set) var threads: [ReviewThread] = []
    private(set) var pending: PendingReview
    private(set) var layout = ReviewLayout() {
        didSet { updateAttachedLines() }
    }
    /// The lines that have threads, drafts, a notice, or the composer. Set only when it changes,
    /// so typing in the composer does not wake what watches it.
    private(set) var attachedLines: [FileDiff.ID: Set<DiffLine.Numbers>] = [:]
    /// The line whose comments the popover shows. `nil` while the popover is closed.
    var focusedLine: LineRef?
    /// Why the threads could not be loaded. Drafts still work without them.
    private(set) var threadsError: String?
    /// Saved with the drafts as it changes, so its text is still there after
    /// the user leaves the pull request or quits.
    var composer: Composer? {
        didSet {
            updateAttachedLines()
            let saved = composer.flatMap(saved)
            guard saved != pending.composer else { return }
            pending.composer = saved
            save()
        }
    }

    /// What waits for the user to confirm discarding the text in `composer`.
    enum Discard: Equatable {
        case close
        case open(Composer.Target)
    }

    var discardRequest: Discard?
    private(set) var notice: Notice? {
        didSet { updateAttachedLines() }
    }
    /// The lines of the range being selected or commented on.
    private(set) var selection: (file: FileDiff.ID, lines: Set<DiffLine.Numbers>)?
    /// Where a gutter drag started.
    private(set) var dragOrigin: (file: FileDiff.ID, line: DiffLine)?
    @ObservationIgnored private var dragTarget: DiffLine?
    /// The outdated draft that the next gutter click gives a new line.
    var reanchoring: DraftComment.ID?
    /// Resolved threads the user has opened.
    var expandedThreads: Set<String> = []
    private(set) var submission = Submission.idle
    /// Whether the signed-in user opened the pull request. GitHub rejects
    /// approving or requesting changes on one's own pull request.
    private(set) var isOwnPullRequest = false

    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private let draftsURL: URL
    @ObservationIgnored private var diff = Diff(parsing: "")
    @ObservationIgnored private var head: String?
    @ObservationIgnored private var pullRequestID: String?
    /// The signed-in user's login, once known.
    @ObservationIgnored private var viewer: String?
    @ObservationIgnored private var saving: Task<Void, Never>?

    init(pullRequest: PullRequest, client: GitHubClient, draftsRoot: URL = PendingReview.defaultRoot) {
        self.pullRequest = pullRequest
        self.client = client
        draftsURL = PendingReview.url(root: draftsRoot, repository: pullRequest.repository, number: pullRequest.number)
        // A few hundred bytes, read once, so the drafts are there before the first frame.
        pending = PendingReview.load(from: draftsURL)
        // A reply or an edit can reopen now. A new thread waits for the diff, in `show(diff:head:)`.
        if let saved = pending.composer {
            switch saved.target {
            case .new(.reply(let threadID)):
                composer = Composer(target: .reply(threadID: threadID), text: saved.text)
                expandedThreads.insert(threadID)
            case .edit(let id) where draft(id) != nil:
                composer = Composer(target: .edit(draft: id), text: saved.text)
            case .edit:
                pending.composer = nil
            case .new(.line):
                break
            }
        }
    }

    /// The form of `composer` that is saved. `nil` when there is no text to keep.
    private func saved(_ composer: Composer) -> PendingReview.Composer? {
        guard !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let target: PendingReview.Composer.Target = switch composer.target {
        case .thread(_, _, let anchor): .new(DraftComment(anchor: anchor, body: "").target)
        case .reply(let threadID): .new(.reply(threadID: threadID))
        case .edit(let id): .edit(draft: id)
        }
        return PendingReview.Composer(target: target, text: composer.text)
    }

    /// Reopens a saved comment on a new thread, once the diff says where its lines are.
    /// When they are not in the diff, `moveComposer()` turns the text into an outdated draft.
    private func restoreComposer() {
        guard composer == nil, let saved = pending.composer, case .new(let target) = saved.target,
              let anchor = DraftComment(target: target, body: "").anchor
        else { return }
        let file = diff.place([anchor]) { $0 }.placed.first?.fileID ?? anchor.path
        // `moveComposer()` sets the line the composer sits under.
        composer = Composer(target: .thread(file: file, under: .addition(new: anchor.end.line), anchor: anchor), text: saved.text)
    }

    var summary: String {
        get { pending.summary }
        set {
            pending.summary = newValue
            save()
        }
    }

    // MARK: Loading

    /// Matches threads and drafts against a new diff, then reloads the threads from GitHub.
    /// - Returns: Whether the threads were loaded.
    @discardableResult
    func refresh(diff: Diff, head: String?) async -> Bool {
        show(diff: diff, head: head)
        return await reloadThreads()
    }

    /// Matches the threads and drafts already loaded against a diff.
    func show(diff: Diff, head: String?) {
        self.diff = diff
        self.head = head
        restoreComposer()
        moveComposer()
        rebuild()
    }

    /// Keeps the comment being written visible after the diff changed under it.
    /// When its lines left the diff, there is no row to show it under, so its
    /// text becomes an outdated draft.
    private func moveComposer() {
        guard let composer, case .thread(let id, _, let anchor) = composer.target else { return }
        let file = file(id)
        if let end = file?.line(at: anchor.end), anchor.start.map({ file?.line(at: $0) != nil }) ?? true {
            if case .thread(_, let under, _) = composer.target, focusedLine == LineRef(file: id, line: under) {
                focusedLine = LineRef(file: id, line: end.numbers)
            }
            self.composer?.target = .thread(file: id, under: end.numbers, anchor: anchor)
            selection = (id, lines(of: anchor, in: id))
            return
        }
        let body = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            pending.comments.append(DraftComment(anchor: anchor, body: body))
            save()
        }
        self.composer = nil
        selection = nil
    }

    /// - Returns: Whether the threads were loaded. The caller asks again when they were not.
    @discardableResult
    func reloadThreads() async -> Bool {
        var loaded = false
        do {
            let detail = try await client.pullRequestDetail(repository: pullRequest.repository, number: pullRequest.number)
            pullRequestID = detail.id
            threads = detail.reviewThreads
            threadsError = nil
            // A reply to a thread that is gone has no row to show its composer, so its text becomes an outdated draft.
            if case .reply(let id) = composer?.target, !threads.contains(where: { $0.id == id }) { addComposerToReview() }
            rebuild()
            loaded = true
        } catch is CancellationError {
        } catch {
            threadsError = DiffLoader.message(for: error)
        }
        if viewer == nil {
            struct Viewer: Decodable, Sendable { let login: String }
            viewer = (try? await client.get("/user", as: Viewer.self))?.login
            isOwnPullRequest = viewer != nil && viewer == pullRequest.author?.login
        }
        return loaded
    }

    private func rebuild() {
        layout = ReviewLayout(diff: diff, threads: threads, drafts: pending.comments)
    }

    private func save() {
        let pending = pending
        let url = draftsURL
        let previous = saving
        // Each write waits for the one before it, so the last change is what stays on disk.
        saving = Task.detached {
            await previous?.value
            try? pending.save(to: url)
        }
    }

    /// Waits until every change so far is on disk.
    func flush() async { await saving?.value }

    // MARK: Starting a comment

    private func file(_ id: FileDiff.ID) -> FileDiff? { diff.files.first { $0.id == id } }

    /// Starts a comment on the lines from `first` to `last` of a file, or
    /// explains under `last` why GitHub would not take it.
    func startComment(file id: FileDiff.ID, from first: DiffLine, to last: DiffLine) {
        guard let file = file(id) else { return }
        do {
            let anchor = try file.rangeAnchor(from: first.commentPosition, to: last.commentPosition)
            // The composer sits under the range's last line in the diff.
            let end = file.location(of: anchor.end).map { file.hunks[$0.hunkIndex].lines[$0.lineIndex].numbers } ?? last.numbers
            start(anchor, file: file, under: end)
        } catch {
            notice = Notice(file: id, line: last.numbers, text: explanation(for: error))
            focusedLine = LineRef(file: id, line: last.numbers)
            selection = nil
        }
    }

    /// Starts a comment on new-file lines of a file, from its rendered Markdown.
    func startComment(file id: FileDiff.ID, newLines: ClosedRange<Int>) {
        guard let file = file(id) else { return }
        switch markdownAnchor(file: file, lines: newLines) {
        case .success(let anchor):
            guard let location = file.location(of: anchor.end) else { return }
            // Its composer is docked under the rendered file, so no line's popover opens.
            start(anchor, file: file, under: file.hunks[location.hunkIndex].lines[location.lineIndex].numbers, focuses: false)
        case .failure(let reason):
            notice = Notice(file: id, line: nil, text: reason.text)
        }
    }

    private func start(_ anchor: CommentAnchor, file: FileDiff, under line: DiffLine.Numbers, focuses: Bool = true) {
        notice = nil
        if let draft = reanchoring, let index = pending.comments.firstIndex(where: { $0.id == draft }) {
            pending.comments[index].target = DraftComment(anchor: anchor, body: "").target
            reanchoring = nil
            selection = nil
            changed()
            return
        }
        open(.thread(file: file.id, under: line, anchor: anchor))
        if !focuses, focusedLine == LineRef(file: file.id, line: line) { focusedLine = nil }
    }

    /// Opens the composer for `target`. Asks first when that discards text.
    func open(_ target: Composer.Target) {
        guard composer?.target != target else { return }
        if let composer, isDirty(composer) {
            discardRequest = .open(target)
        } else {
            show(target)
        }
    }

    /// Closes the composer. Asks first when that discards text.
    func cancelComposer() {
        guard let composer else { return }
        if isDirty(composer) {
            discardRequest = .close
        } else {
            show(nil)
        }
    }

    /// The user confirmed that the composer's text can go.
    func confirmDiscard() {
        guard let request = discardRequest else { return }
        discardRequest = nil
        switch request {
        case .close: show(nil)
        case .open(let target): show(target)
        }
    }

    private func isDirty(_ composer: Composer) -> Bool {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .edit(let id) = composer.target { return text != draft(id)?.body }
        return !text.isEmpty
    }

    private func show(_ target: Composer.Target?) {
        var text = ""
        if case .edit(let id) = target { text = draft(id)?.body ?? "" }
        composer = target.map { Composer(target: $0, text: text) }
        if case .thread(let file, let under, let anchor) = target {
            selection = (file, lines(of: anchor, in: file))
            focusedLine = LineRef(file: file, line: under)
        } else {
            selection = nil
        }
    }

    private func lines(of anchor: CommentAnchor, in id: FileDiff.ID) -> Set<DiffLine.Numbers> {
        guard let file = file(id), let end = file.location(of: anchor.end) else { return [] }
        let start = anchor.start.flatMap(file.location(of:)) ?? end
        guard start.hunkIndex == end.hunkIndex, start <= end else { return [] }
        return Set(file.hunks[end.hunkIndex].lines[start.lineIndex...end.lineIndex].map(\.numbers))
    }

    func dismissNotice() { notice = nil }

    /// The line the comment being written belongs to. `nil` when nothing is being written.
    var writingLine: LineRef? {
        switch composer?.target {
        case .thread(let file, let under, _): LineRef(file: file, line: under)
        case .reply(let threadID): layout.line(of: threadID)
        case .edit(let id): layout.line(ofDraft: id)
        case nil: nil
        }
    }

    private func updateAttachedLines() {
        var lines = layout.lines.mapValues { Set($0.keys) }
        if let notice, let line = notice.line { lines[notice.file, default: []].insert(line) }
        if case .thread(let file, let under, _) = composer?.target { lines[file, default: []].insert(under) }
        if lines != attachedLines { attachedLines = lines }
    }

    // MARK: Gutter drag

    func beginDrag(file: FileDiff.ID, line: DiffLine) {
        dragTarget = line
        dragOrigin = (file, line)
        selection = (file, [line.numbers])
    }

    /// Extends the selection to the row under the pointer.
    /// - Parameter row: The lines of that row: one, or the two sides of a split row.
    func drag(over row: [DiffLine]) {
        guard let origin = dragOrigin else { return }
        // In the split layout a deletion shares its row with the addition that
        // replaces it. The drag stays on the side it started on.
        let side = origin.line.commentPosition.side
        guard let target = row.first(where: { $0.commentPosition.side == side }) ?? row.first else { return }
        // An invalid target is kept, so that ending the drag there explains why.
        dragTarget = target
        guard let anchor = try? file(origin.file)?.rangeAnchor(from: origin.line.commentPosition, to: target.commentPosition)
        else { return }
        let lines = lines(of: anchor, in: origin.file)
        if selection?.lines != lines { selection = (origin.file, lines) }
    }

    /// Ends a drag: starts a comment on the lines between the origin and the last row the drag reached.
    /// - Parameter extendsSelection: Shift was held, so a click extends the open composer's range.
    func endDrag(extendsSelection: Bool) {
        guard let origin = dragOrigin else { return }
        dragOrigin = nil
        let target = dragTarget ?? origin.line
        if extendsSelection, target == origin.line, case .thread(let file, _, let anchor) = composer?.target, file == origin.file,
           let first = self.file(file)?.line(at: anchor.start ?? anchor.end)
        {
            extend(from: first, to: origin.line, in: file)
        } else {
            startComment(file: origin.file, from: origin.line, to: target)
        }
    }

    /// Changes the open composer's range to `first...last`, keeping its text.
    private func extend(from first: DiffLine, to last: DiffLine, in id: FileDiff.ID) {
        guard let file = file(id), let text = composer?.text else { return }
        do {
            let anchor = try file.rangeAnchor(from: first.commentPosition, to: last.commentPosition)
            let under = file.line(at: anchor.end)?.numbers ?? last.numbers
            composer = Composer(target: .thread(file: id, under: under, anchor: anchor), text: text)
            selection = (id, lines(of: anchor, in: id))
            notice = nil
            focusedLine = LineRef(file: id, line: under)
        } catch {
            notice = Notice(file: id, line: last.numbers, text: explanation(for: error))
            focusedLine = LineRef(file: id, line: last.numbers)
        }
    }

    // MARK: Drafts

    func draft(_ id: DraftComment.ID) -> DraftComment? { pending.comments.first { $0.id == id } }

    /// Adds the composer's text to the pending review, or updates the draft being edited.
    func addComposerToReview() {
        guard let composer else { return }
        let body = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        switch composer.target {
        case .thread(_, _, let anchor):
            pending.comments.append(DraftComment(anchor: anchor, body: body))
        case .reply(let threadID):
            pending.comments.append(DraftComment(target: .reply(threadID: threadID), body: body))
        case .edit(let id):
            guard let index = pending.comments.firstIndex(where: { $0.id == id }) else { break }
            pending.comments[index].body = body
        }
        show(nil)
        changed()
    }

    func delete(_ draft: DraftComment.ID) {
        pending.comments.removeAll { $0.id == draft }
        if composer?.target == .edit(draft: draft) { show(nil) }
        if reanchoring == draft { reanchoring = nil }
        changed()
    }

    private func changed() {
        rebuild()
        save()
    }

    // MARK: Submitting

    /// Whether a review with this verdict and the current summary has anything to send.
    func canSubmit(_ event: ReviewSubmission.Event) -> Bool {
        guard submission != .sending, pullRequestID != nil, head != nil else { return false }
        if event != .comment, isOwnPullRequest { return false }
        let hasText = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return event == .approve || hasText || !layout.submittable.isEmpty
    }

    /// Sends every draft that still has a place as one review. A draft that is
    /// open for editing is updated from the composer first. On success the
    /// sent drafts are removed and the threads reloaded; on failure everything stays.
    /// - Returns: Whether the review was submitted.
    @discardableResult
    func submit(_ event: ReviewSubmission.Event) async -> Bool {
        guard let pullRequestID, let head, submission != .sending else { return false }
        // An edit that is still open is part of the review, so the draft goes out with the text on screen.
        if case .edit = composer?.target { addComposerToReview() }
        let sent = layout.submittable
        let request = ReviewSubmission(
            pullRequestID: pullRequestID, commitOID: head, event: event,
            body: summary.trimmingCharacters(in: .whitespacesAndNewlines), drafts: sent
        )
        submission = .sending
        do {
            _ = try await client.submitReview(request)
        } catch {
            submission = .failed(DiffLoader.message(for: error))
            return false
        }
        let sentIDs = Set(sent.map(\.id))
        pending.comments.removeAll { sentIDs.contains($0.id) }
        // Only an edit whose text was empty is still open. Its draft is gone, so no view would show it.
        if case .edit(let id) = composer?.target, sentIDs.contains(id) { show(nil) }
        pending.summary = ""
        submission = .idle
        changed()
        await reloadThreads()
        return true
    }
}

extension FileDiff {
    /// The diff line at `position`, or `nil` when no hunk has it.
    func line(at position: DiffPosition) -> DiffLine? {
        location(of: position).map { hunks[$0.hunkIndex].lines[$0.lineIndex] }
    }
}

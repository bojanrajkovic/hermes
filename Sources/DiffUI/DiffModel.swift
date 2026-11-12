import DiffKit
import Foundation
import GitHubKit
import Observation
import RepoKit

/// One file of the diff and its view state.
///
/// The object lives as long as the file stays in the diff. A reload that
/// leaves the file's diff alone keeps `isCollapsed` and `isViewed`.
@Observable @MainActor
final class FileModel: Identifiable {
    nonisolated let id: FileDiff.ID
    private(set) var diff: FileDiff
    /// What the list shows for this file. Rebuilt whenever an input changes.
    private(set) var rows: [DiffRow] = []
    var isCollapsed = false
    private(set) var isViewed = false
    /// Whether the unchanged lines around the hunks are known, so the expanders work.
    private(set) var hasRegions = false
    /// Whether syntax colors and intraline emphasis have been applied.
    private(set) var isStyled = false

    var layout: DiffLayout {
        didSet { if layout != oldValue { rebuildRows() } }
    }

    /// The old and new text of a Markdown file, for its rendered diff.
    enum Markdown: Equatable {
        case loading
        case loaded(old: String, new: String)
        case failed(String)
    }

    /// Whether a Markdown file shows its rendered diff in place of its lines.
    var showsRendered = false
    var markdown: Markdown?

    /// Whether the rendered diff is shown and its text is not loaded or loading.
    /// A failed load counts, so the next attempt can replace the error.
    var needsMarkdown: Bool {
        guard showsRendered else { return false }
        if case .failed = markdown { return true }
        return markdown == nil
    }

    var isMarkdown: Bool {
        ["md", "markdown"].contains(diff.path.split(separator: ".").last?.lowercased() ?? "") && diff.content != .binary
    }

    @ObservationIgnored private var expansion = FileExpansion()
    @ObservationIgnored private var styled: [DiffLine.Numbers: AttributedString] = [:]
    @ObservationIgnored private var showsLargeDiff = false

    init(diff: FileDiff, layout: DiffLayout) {
        id = diff.id
        self.diff = diff
        self.layout = layout
        rebuildRows()
    }

    /// Whether the diff is long enough to wait behind the "Load diff" button.
    var isHeldBack: Bool {
        !showsLargeDiff && diff.hunks.reduce(0) { $0 + $1.lines.count } > largeFileLineLimit
    }

    /// Whether the file has unchanged lines that could be read from the source tree.
    var wantsRegions: Bool {
        guard !hasRegions, diff.content != .binary, diff.newPath != nil else { return false }
        if case .added = diff.change { return false }
        return true
    }

    /// The widest line number the gutter has to fit, in digits. At least 3,
    /// so most files share one gutter width.
    var gutterDigits: Int {
        let last = diff.hunks.last.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) } ?? 0
        return max(3, String(max(last, lastRevealedLine)).count)
    }

    @ObservationIgnored private var lastRevealedLine = 0

    func setViewed(_ viewed: Bool) {
        isViewed = viewed
        isCollapsed = viewed
    }

    /// Replaces the file's diff after a reload. Styling and expansion start over,
    /// and the file opens unviewed, because it has changes the user has not read.
    func replace(_ diff: FileDiff) {
        self.diff = diff
        isViewed = false
        isCollapsed = false
        expansion = FileExpansion()
        styled = [:]
        hasRegions = false
        isStyled = false
        lastRevealedLine = 0
        markdown = nil
        rebuildRows()
    }

    func showLargeDiff() {
        showsLargeDiff = true
        rebuildRows()
    }

    /// Stores styled text computed for `diff`. Ignored when the file has changed since.
    func apply(styled: [DiffLine.Numbers: AttributedString], for diff: FileDiff, isHunkText: Bool = true) {
        guard diff == self.diff else { return }
        self.styled.merge(styled) { _, new in new }
        if isHunkText { isStyled = true }
        rebuildRows()
    }

    func apply(regions: [HiddenRegion], for diff: FileDiff) {
        guard diff == self.diff, !hasRegions else { return }
        expansion = FileExpansion(regions: regions)
        hasRegions = true
        lastRevealedLine = regions.last?.lines.last?.newNumber ?? 0
        rebuildRows()
    }

    /// Reveals hidden lines of a region. The lines show at once as plain
    /// text and get their syntax colors a moment later.
    func expand(region: Int, _ amount: Expansion) {
        let revealed = expansion.expand(region: region, amount)
        guard !revealed.isEmpty else { return }
        rebuildRows()
        let diff = diff
        Task {
            let styled = await Task.detached { LineStyler.style(context: revealed, path: diff.path) }.value
            apply(styled: styled, for: diff, isHunkText: false)
        }
    }

    private func rebuildRows() {
        rows = diffRows(file: diff, expansion: expansion, layout: layout, showsLargeDiff: showsLargeDiff) { [styled] line in
            styled[line.numbers] ?? LineStyler.plain(line)
        }
    }
}

/// Where the diff list is scrolled to. Kept apart from ``DiffModel`` so that
/// scrolling only re-evaluates the views that show the current file.
@Observable @MainActor
final class DiffScrollState {
    struct Request: Equatable {
        /// Where in the list the row goes.
        enum Anchor {
            /// At the top, below the file's pinned header.
            case top
            /// In the middle, for a line the user asked to see with the code around it.
            case center
        }

        let row: RowID
        let anchor: Anchor
        /// The name the user came for, when the row was revealed for one. The list marks it on the line.
        let symbol: String?
        /// Makes two requests for the same row distinct.
        let serial: Int
    }

    /// The file at the top of the list.
    private(set) var currentFile: FileDiff.ID?
    /// The row to bring to the top next. The list scrolls when this changes.
    private(set) var request: Request?
    /// The rows on screen, in no particular order. Not observed: it changes on every scrolled row.
    @ObservationIgnored private(set) var visible: [RowID] = []

    /// Whether `currentFile` was asked for by `scroll(to:)` and has been on screen since.
    @ObservationIgnored private var isRequested = false

    func scroll(to row: RowID, anchor: Request.Anchor = .top, symbol: String? = nil) {
        request = Request(row: row, anchor: anchor, symbol: symbol, serial: (request?.serial ?? 0) + 1)
        if currentFile != row.file { currentFile = row.file }
        isRequested = true
    }

    func scroll(to file: FileDiff.ID) {
        scroll(to: RowID(file: file, item: .header))
    }

    /// Records the rows on screen. `currentFile` becomes the first of their files in `order`.
    ///
    /// A file that `scroll(to:)` asked for stays current while any of its rows
    /// is on screen. The list cannot bring a short file near the end to the
    /// top, so the first file on screen would be an earlier one.
    ///
    /// This runs for every row that scrolls in or out, so it looks a file up
    /// only when the file differs from the row before.
    func setVisible(_ rows: [RowID], order: [FileDiff.ID: Int]) {
        visible = rows
        if isRequested {
            if rows.contains(where: { $0.file == currentFile }) { return }
            isRequested = false
        }
        var top: (file: FileDiff.ID, index: Int)?
        var previous: FileDiff.ID?
        for row in rows where row.file != previous {
            previous = row.file
            if let index = order[row.file], index < top?.index ?? .max { top = (row.file, index) }
        }
        if let top, top.file != currentFile { currentFile = top.file }
    }
}

/// Loads one ``DiffSource`` and keeps it current.
@Observable @MainActor
final class DiffModel {
    enum Phase: Equatable {
        case loading
        case failed(String)
        case loaded
    }

    let source: DiffSource
    private(set) var phase = Phase.loading
    /// The changed files in diff order.
    private(set) var files: [FileModel] = []
    /// When a reload last changed what is shown. `nil` until then.
    private(set) var updatedAt: Date?
    /// Why the last reload failed while older content stays on screen.
    private(set) var refreshError: String?
    let scroll = DiffScrollState()
    /// Review comments. `nil` for local sources, which are read-only.
    let review: ReviewModel?
    /// The definition pane docked under the list.
    let definitions: DefinitionModel
    /// The definition popover over a clicked identifier. It reads the same source tree as the pane.
    let peek: DefinitionModel
    /// A "+" was clicked in a rendered Markdown file of a source that takes no comments.
    var isReadOnlyNoticeShown = false

    var layout: DiffLayout {
        didSet {
            guard layout != oldValue else { return }
            // The layouts differ in height, so hold on to the rows on screen.
            let anchors = visibleLineRows()
            files.forEach { $0.layout = layout }
            restoreScroll(to: anchors)
        }
    }

    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private let repoCache: RepoCache
    @ObservationIgnored private var loadedText: String?
    @ObservationIgnored private var diff = Diff(parsing: "")
    /// When GitHub last recorded activity on the pull request.
    @ObservationIgnored private var revisionDate: Date?
    @ObservationIgnored private var head: String?
    /// How many reloads in a row returned the old diff for a new head.
    @ObservationIgnored private var staleFetches = 0
    @ObservationIgnored private var tree: (any SourceTree)?
    @ObservationIgnored private var treeHead: String?
    /// Whether the source tree could not be read after the last load, so the next reload tries again.
    @ObservationIgnored private var treeFailed = false
    @ObservationIgnored private var fileOrder: [FileDiff.ID: Int] = [:]
    /// Highlighting and file reads that follow a load. Tests await it.
    @ObservationIgnored private(set) var background: Task<Void, Never>?

    init(
        source: DiffSource, client: GitHubClient, repoCache: RepoCache, layout: DiffLayout = .unified,
        draftsRoot: URL = PendingReview.defaultRoot
    ) {
        self.source = source
        self.client = client
        self.repoCache = repoCache
        self.layout = layout
        if case .pullRequest(let pullRequest) = source {
            review = ReviewModel(pullRequest: pullRequest, client: client, draftsRoot: draftsRoot)
        } else {
            review = nil
        }
        let fetchStatus = review == nil ? "Reading the files…" : "Fetching the commit from GitHub…"
        definitions = DefinitionModel(fetchStatus: fetchStatus)
        peek = DefinitionModel(fetchStatus: fetchStatus)
        let tree: @MainActor () async throws -> any SourceTree = { [weak self] in
            guard let tree = try await self?.sourceTree() else { throw DefinitionError.noSourceTree }
            return tree
        }
        definitions.tree = tree
        peek.tree = tree
    }

    var additions: Int { files.reduce(0) { $0 + $1.diff.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.diff.deletions } }
    var viewedCount: Int { files.count { $0.isViewed } }

    /// The file at the top of the list.
    var currentFile: FileModel? {
        files.first { $0.id == scroll.currentFile } ?? files.first
    }

    // MARK: Loading

    /// Loads the diff, then reloads it as the source changes: a pull request
    /// is polled every 10 seconds for a new head commit, a working tree is
    /// watched for file changes, and a local branch for commits. Runs until
    /// its task is cancelled.
    func run() async {
        await reload()
        switch source {
        case .pullRequest(let pullRequest):
            // The sleep throws when the screen goes away, which ends the polling.
            while (try? await Task.sleep(for: .seconds(10))) != nil {
                let revision = try? await client.pullRequestRevision(
                    repository: pullRequest.repository, number: pullRequest.number
                )
                guard let revision else { continue }
                if revision.headOID != head || treeFailed {
                    await reload()
                } else if revision.updatedAt != revisionDate {
                    // A comment or a review, with no new commit.
                    // A failed read keeps the old date, so the next poll asks again.
                    if await review?.reloadThreads() != false { revisionDate = revision.updatedAt }
                }
            }
        case .workingTree(let directory, _):
            for await _ in WorkingTree(directory: directory).changes() { await reload() }
        case .localBranch(let checkout, _):
            // Branch refs are shared by all of the checkout's worktrees, so watching its main one sees every commit.
            for await _ in WorkingTree(directory: checkout.directory).changes() { await reload() }
        }
    }

    /// Fetches the diff and updates the files in place. Content already on
    /// screen stays there while this runs, and when it fails.
    func reload() async {
        if case .failed = phase { phase = .loading }
        do {
            let fetched = try await DiffLoader.fetch(source, client: client, repoCache: repoCache)
            refreshError = nil
            // For a few seconds after a push, GitHub serves the previous diff.
            // Keeping the old head makes the next poll ask again. A commit that
            // really leaves the diff as it was is accepted after a minute.
            if head != nil, fetched.head != head, fetched.text == loadedText, staleFetches < 6 {
                staleFetches += 1
                return
            }
            staleFetches = 0
            head = fetched.head
            await show(text: fetched.text)
            let threadsLoaded = await review?.refresh(diff: diff, head: head) != false
            // The threads were read after this revision, so the next poll need not read them again.
            // When reading them failed, no date matches and the next poll reads them.
            revisionDate = threadsLoaded ? fetched.updatedAt : nil
        } catch is CancellationError {
        } catch {
            let message = DiffLoader.message(for: error)
            if phase == .loaded { refreshError = message } else { phase = .failed(message) }
        }
    }

    /// Parses and shows diff text, then starts the background work for it.
    /// Does nothing when the text is what is already shown.
    func show(text: String) async {
        guard text != loadedText else {
            phase = .loaded
            if treeFailed { startBackgroundWork() }
            return
        }
        let diff = await Task.detached { Diff(parsing: text) }.value
        self.diff = diff
        let isUpdate = loadedText != nil
        loadedText = text
        let anchors = visibleLineRows()
        let movesContent = changesContent(aboveOrIn: scroll.currentFile, diff)
        apply(diff)
        phase = .loaded
        if isUpdate {
            updatedAt = .now
            if movesContent { restoreScroll(to: anchors) }
        }
        startBackgroundWork()
    }

    /// Shows a parsed diff. Files that are unchanged keep their model and everything in it.
    private func apply(_ diff: Diff) {
        let existing = Dictionary(files.map { ($0.id, $0) }) { first, _ in first }
        files = diff.files.map { file in
            guard let model = existing[file.id] else { return FileModel(diff: file, layout: layout) }
            if model.diff != file { model.replace(file) }
            return model
        }
        fileOrder = Dictionary(files.enumerated().map { ($0.element.id, $0.offset) }) { first, _ in first }
    }

    // MARK: Scroll position

    /// Called by the list as rows scroll in and out of view.
    func visibleRowsChanged(_ rows: [RowID]) {
        scroll.setVisible(rows, order: fileOrder)
    }

    /// The code lines of the current file that are on screen, top first.
    private func visibleLineRows() -> [RowID] {
        guard let file = files.first(where: { $0.id == scroll.currentFile }) else { return [] }
        let visible = Set(scroll.visible)
        return file.rows.map(\.id).filter { row in
            if case .line = row.item { visible.contains(row) } else { false }
        }
    }

    /// Whether showing `diff` changes any file from the top of the list through `file`.
    /// Changes further down leave the rows on screen where they are.
    private func changesContent(aboveOrIn file: FileDiff.ID?, _ diff: Diff) -> Bool {
        guard let index = files.firstIndex(where: { $0.id == file }) else { return false }
        return files[...index].map(\.diff) != Array(diff.files.prefix(index + 1))
    }

    /// Scrolls the first of `anchors` that still exists back to the top. The
    /// list would otherwise keep its offset in points while the rows above
    /// grow or shrink, which moves what the user is reading.
    private func restoreScroll(to anchors: [RowID]) {
        guard let first = anchors.first, let file = files.first(where: { $0.id == first.file }) else { return }
        let rows = Set(file.rows.map(\.id))
        scroll.scroll(to: anchors.first(where: rows.contains) ?? RowID(file: file.id, item: .header))
    }

    /// Highlights the files that need it, then reads the source tree for context expansion.
    private func startBackgroundWork() {
        background?.cancel()
        background = Task { [weak self] in
            await self?.highlight()
            await self?.loadRegions()
        }
    }

    private func highlight() async {
        let pending = files.filter { !$0.isStyled && !$0.isHeldBack }
        let models = Dictionary(pending.map { ($0.id, $0) }) { first, _ in first }
        await forEachConcurrently(pending.map(\.diff), limit: 8) { diff in
            LineStyler.style(diff)
        } receive: { diff, styled in
            models[diff.id]?.apply(styled: styled, for: diff)
        }
    }

    /// The files at the diff's new side. Fetched once per head commit.
    func sourceTree() async throws -> (any SourceTree)? {
        if tree == nil || treeHead != head {
            let head = head
            tree = try await DiffLoader.tree(for: source, head: head, repoCache: repoCache)
            treeHead = head
        }
        return tree
    }

    private func loadRegions() async {
        // Before the tree is read: a file that can't be loaded shows why, not "Rendering…".
        for file in files where file.needsMarkdown { loadMarkdown(file) }
        let tree: (any SourceTree)?
        do {
            tree = try await sourceTree()
            treeFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            treeFailed = true
            refreshError = DiffLoader.message(for: error)
            return
        }
        guard let tree, !Task.isCancelled else { return }
        let pending = files.filter(\.wantsRegions)
        let models = Dictionary(pending.map { ($0.id, $0) }) { first, _ in first }
        await forEachConcurrently(pending.map(\.diff), limit: 8) { diff in
            await DiffLoader.hiddenRegions(of: diff, in: tree)
        } receive: { diff, regions in
            if let regions { models[diff.id]?.apply(regions: regions, for: diff) }
        }
    }

    // MARK: Actions

    func showLargeDiff(_ file: FileModel) {
        file.showLargeDiff()
        let diff = file.diff
        Task {
            let styled = await Task.detached { LineStyler.style(diff) }.value
            file.apply(styled: styled, for: diff)
        }
    }

    /// Scrolls to the file after (`offset` 1) or before (`offset` -1) the current one.
    func selectFile(offset: Int) {
        guard let current = currentFile, let index = files.firstIndex(where: { $0 === current }) else { return }
        let target = min(max(index + offset, 0), files.count - 1)
        scroll.scroll(to: files[target].id)
    }

    func toggleCurrentFileViewed() {
        guard let file = currentFile else { return }
        file.setViewed(!file.isViewed)
    }

    // MARK: Rendered Markdown

    /// Whether the dock under the list has a composer or a notice to show.
    var hasRenderedDock: Bool {
        guard let review else { return isReadOnlyNoticeShown }
        if review.notice?.line == nil, review.notice != nil { return true }
        guard case .thread(let file, _, _) = review.composer?.target else { return false }
        return files.first { $0.id == file }?.showsRendered == true
    }

    func setRendered(_ rendered: Bool, for file: FileModel) {
        file.showsRendered = rendered
        if file.needsMarkdown { loadMarkdown(file) }
        // The two views differ in height, so the list would otherwise land somewhere else in the file.
        scroll.scroll(to: file.id)
    }

    /// Reads the file's new text and derives the old text from the diff.
    private func loadMarkdown(_ file: FileModel) {
        let diff = file.diff
        file.markdown = .loading
        Task {
            let result: FileModel.Markdown
            do {
                guard let tree = try await sourceTree() else { throw DefinitionError.noSourceTree }
                result = try await Task.detached {
                    // A deleted file has no new text. Its old text is what the diff removes.
                    let new = if let path = diff.newPath { try await tree.readFile(path) } else { "" }
                    return .loaded(old: oldText(newText: new, hunks: diff.hunks), new: new)
                }.value
            } catch {
                result = .failed(DiffLoader.message(for: error))
            }
            if file.diff == diff { file.markdown = result }
        }
    }

    /// The directory of a file in a local source, so a rendered Markdown file finds its images.
    func baseURL(for file: FileDiff) -> URL? {
        guard case .workingTree(let directory, _) = source else { return nil }
        return directory.appending(path: file.path).deletingLastPathComponent()
    }

    // MARK: Definitions

    /// The location's page on GitHub at the head commit. `nil` for local sources.
    /// The zero-based `line` of the file at `path` on GitHub, at the pull request's head commit.
    func gitHubURL(path: String, line: Int) -> URL? {
        guard case .pullRequest(let pullRequest) = source, let head else { return nil }
        let file = URL(string: "https://github.com/\(pullRequest.repository)/blob/\(head)")?.appending(path: path)
        return file.flatMap { URL(string: "\($0.absoluteString)#L\(line + 1)") }
    }

    /// The diff row that shows the zero-based `line` of the file at `path`, when the diff has that line.
    func diffRow(path: String, line: Int) -> RowID? {
        for file in files where file.diff.newPath == path {
            if let line = file.diff.line(at: DiffPosition(side: .right, line: line + 1)) {
                return RowID(file: file.id, item: .line(line.numbers))
            }
        }
        return nil
    }

    /// Opens the new version of a file in the definition pane, at its first change.
    func openFile(_ file: FileModel) {
        guard let path = file.diff.newPath else { return }
        definitions.openFile(path, line: (file.diff.firstChangedLine ?? 1) - 1)
    }

    /// Scrolls a row to the middle of the list, opening its file first when it is collapsed or rendered.
    /// The list highlights the line for a moment, and `symbol` on it more strongly.
    func reveal(_ row: RowID, symbol: String? = nil) {
        guard let file = files.first(where: { $0.id == row.file }) else { return }
        file.isCollapsed = false
        file.showsRendered = false
        scroll.scroll(to: row, anchor: .center, symbol: symbol)
    }

    /// The file's page in the pull request on GitHub. `nil` for local sources.
    func gitHubURL(for file: FileDiff) -> URL? {
        guard case .pullRequest(let pullRequest) = source else { return nil }
        return DiffLoader.gitHubURL(pullRequest: pullRequest.url, path: file.path)
    }
}

enum DefinitionError: LocalizedError {
    case noSourceTree

    var errorDescription: String? {
        "The files of this branch can't be read. Check the branch out in a worktree to browse its code."
    }
}

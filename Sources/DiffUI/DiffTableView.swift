import AppKit
import DiffKit
import SwiftUI

/// The diff list's scrolling container: an `NSTableView`. A code line is a
/// `NativeLineCell`, which draws itself. Every other row is a SwiftUI view in a hosting cell.
///
/// A table knows every row's height without building the row, so the scroll
/// bar keeps its size while scrolling, and it reuses a screenful of cells.
///
/// The table does not observe the models. Its caller reads them in a SwiftUI
/// `body` and passes the values in, so a change arrives through `updateNSView`.
struct DiffTableView: NSViewRepresentable {
    let model: DiffModel
    let rows: [DiffTableRow]
    let metrics: DiffMetrics
    let request: DiffScrollState.Request?

    func makeCoordinator() -> DiffTableCoordinator {
        DiffTableCoordinator(model: model, metrics: metrics, request: request)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(model: model, rows: rows, metrics: metrics, request: request)
    }
}

/// What a table cell hosts: one row's SwiftUI view with the environment the row views read.
private struct HostedRow: View {
    let row: DiffTableRow
    let model: DiffModel
    let metrics: DiffMetrics
    /// Changes each time a cell is given another row whose view has to start over. See `startsOver`.
    let generation: Int
    let heightChanged: (CGFloat) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightChanged($0) }
            .id(generation)
            // The cell has the estimated height until the table learns the real one.
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.diffMetrics, metrics)
            .environment(model.review)
            .environment(model.definitions)
    }

    @ViewBuilder private var content: some View {
        switch row.kind {
        case .header:
            FileHeader(file: row.file, model: model, gitHubURL: model.gitHubURL(for: row.file.diff))
        case .line(let line, _):
            switch line.kind {
            case .hunk(let header): HunkHeaderRow(header: header, file: row.file)
            case .notice(let notice): NoticeRow(notice: notice) { model.showLargeDiff(row.file) }
            // A code line is a `NativeLineCell`.
            case .unified, .split: EmptyView()
            }
        case .attachments(let line):
            LineAttachments(file: row.file, line: line)
        case .rendered:
            RenderedMarkdown(file: row.file, model: model)
        case .spacer:
            Color.clear.frame(height: DiffMetrics.fileSpacing)
        }
    }
}

private final class DiffTableCell: NSTableCellView {
    private(set) var host: NSHostingView<HostedRow>?
    private(set) var generation = 0
    /// Filled behind the hosted view. The pinned header has one: its bar is a translucent material,
    /// and without a backing the rows it covers show through.
    var backing: NSColor? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let backing else { return }
        backing.setFill()
        bounds.fill()
    }
    /// The height the hosted view last reported.
    var reportedHeight: CGFloat?

    func show(_ row: HostedRow, isNewRow: Bool) {
        if isNewRow {
            generation += 1
            reportedHeight = nil
        }
        if let host {
            host.rootView = row
        } else {
            let host = NSHostingView(rootView: row)
            // The table sizes the cell. The hosting view must not add constraints or safe area padding of its own.
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            self.host = host
        }
    }
}

/// A row with no drawing of its own: its cell draws everything.
private final class DiffTableRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class DiffNSTableView: NSTableView {
    var liveResizeEnded: (() -> Void)?
    /// Where the pointer is, in the table's coordinates. `nil` when it left the table.
    var pointerMoved: ((CGPoint?) -> Void)?
    /// A press on a row. Returns whether the coordinator takes it and the drag and release after it.
    var pointerDown: ((NSEvent) -> Bool)?
    var pointerDragged: ((NSEvent) -> Void)?
    var pointerUp: ((NSEvent) -> Void)?
    private var isTrackingPointer = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // One tracking area for the whole table. The code lines have none of their own.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // Clicks belong to the rows. The table has no selection to move with the keyboard.
    override var acceptsFirstResponder: Bool { false }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointerMoved?(nil)
    }

    // A press on a code line reaches the table, because `NativeLineCell` does not handle it.
    override func mouseDown(with event: NSEvent) {
        isTrackingPointer = pointerDown?(event) == true
        if !isTrackingPointer { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if isTrackingPointer { pointerDragged?(event) } else { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if isTrackingPointer { pointerUp?(event) } else { super.mouseUp(with: event) }
        isTrackingPointer = false
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        liveResizeEnded?()
    }
}

@MainActor
final class DiffTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    private let tableView = DiffNSTableView()

    private var model: DiffModel
    private var metrics: DiffMetrics
    private var estimator: RowHeightEstimator
    private(set) var rows: [DiffTableRow] = [] {
        didSet {
            var header = 0
            headerIndexes = rows.indices.map { index in
                if rows[index].kind == .header { header = index }
                return header
            }
        }
    }
    /// For each row, the index of its file's header row.
    private var headerIndexes: [Int] = []
    /// A second copy of the current file's header, kept at the top of the list above the rows.
    ///
    /// The table's own floating group rows are not used: after a jump, such as
    /// a scroll request or a drag of the scroll bar, the table keeps floating
    /// the header it floated before.
    private let pinnedHeader = DiffTableCell()
    private var pinnedRow: DiffTableRow?
    /// The real heights of hosted rows that have been on screen at the current width.
    private var measured: [RowID: CGFloat] = [:]
    /// The heights of code lines at the current width and font.
    private var lineHeights: [RowID: CGFloat] = [:]
    /// The width the heights are for.
    private var width: CGFloat = 0
    /// The last revealed line and when. Its cell may be made a moment after the request.
    private var highlighted: (request: DiffScrollState.Request, time: CFTimeInterval)?
    /// The review state the code lines draw in their gutters.
    private var marks = ReviewMarks()

    /// The code line under the pointer.
    private weak var hoveredCell: NativeLineCell?
    private var showsLinkCursor = false
    /// When the list last scrolled. The pointer is ignored until the scroll is over.
    private var lastScroll: CFTimeInterval = 0
    private var isWaitingForScrollEnd = false
    /// How long after the last scrolled step the row under a resting pointer gets its hover.
    private static let scrollEndDelay: CFTimeInterval = 0.1
    private var isDraggingGutter = false
    /// The identifier a press started on. A release on it looks it up.
    private var pressedIdentifier: String?
    private let popover = LinePopover()

    private var request: DiffScrollState.Request?
    /// The last request, held in place while rows around it get their real heights. The user's own scrolling ends it.
    private var target: DiffScrollState.Request?

    /// Whether the bounds change in progress comes from `scroll(toY:)`.
    private var isScrollingItself = false
    private var isFlushScheduled = false
    /// Rows whose measured height the table has not been told yet.
    private var remeasured: [(cell: DiffTableCell, id: RowID)] = []
    /// The width or the code font changed, so the estimates have to be redone.
    private var widthChanged = false
    private var visibleRowsChanged = false

    init(model: DiffModel, metrics: DiffMetrics, request: DiffScrollState.Request?) {
        self.model = model
        self.metrics = metrics
        estimator = RowHeightEstimator(metrics: metrics)
        // A request made before the list was on screen is not for this table.
        self.request = request
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.backgroundColor = .textBackgroundColor
        tableView.usesAutomaticRowHeights = false
        tableView.allowsColumnResizing = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.liveResizeEnded = { [weak self] in self?.scheduleFlush() }
        tableView.pointerMoved = { [weak self] in self?.pointerMoved(to: $0) }
        tableView.pointerDown = { [weak self] in self?.pointerDown($0) ?? false }
        tableView.pointerDragged = { [weak self] in self?.pointerDragged($0) }
        tableView.pointerUp = { [weak self] in self?.pointerUp($0) }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Above the rows and below the scroll bar.
        // What a header in the list has behind it.
        pinnedHeader.backing = .textBackgroundColor
        scrollView.addSubview(pinnedHeader, positioned: .above, relativeTo: scrollView.contentView)
        tableView.postsFrameChangedNotifications = true

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: tableView)
        center.addObserver(self, selector: #selector(userScrolled), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        if ProcessInfo.processInfo.environment["HERMES_SCROLL_BENCH"] != nil {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(runScrollBenchmark), name: Notification.Name("com.coderinserepeat.hermes.scrollBenchmark"), object: nil
            )
        }
        observeReview()
    }

    /// Scrolls down and back up at 120 steps a second for six seconds and writes how long the steps
    /// took to the file named by `HERMES_SCROLL_BENCH`. A step later than 12.5 ms is a dropped frame.
    @objc private func runScrollBenchmark() {
        guard let path = ProcessInfo.processInfo.environment["HERMES_SCROLL_BENCH"] else { return }
        var intervals: [Double] = []
        var last = CACurrentMediaTime()
        var tick = 0
        let ticks = 720
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let now = CACurrentMediaTime()
            intervals.append((now - last) * 1000)
            last = now
            let y = scrollView.contentView.bounds.minY + (tick < ticks / 2 ? 40 : -40)
            scroll(toY: y)
            scrollView.displayIfNeeded()
            tick += 1
            guard tick == ticks else { return }
            timer.invalidate()
            let sorted = intervals.sorted()
            let report = String(
                format: "steps %d  mean %.2f ms  p95 %.2f ms  max %.2f ms  dropped %d\n",
                sorted.count, sorted.reduce(0, +) / Double(sorted.count), sorted[sorted.count * 95 / 100], sorted.last ?? 0,
                sorted.count { $0 > 12.5 }
            )
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Updating

    func update(model: DiffModel, rows new: [DiffTableRow], metrics: DiffMetrics, request: DiffScrollState.Request?) {
        if model !== self.model {
            self.model = model
            rows = []
            measured = [:]
            lineHeights = [:]
            target = nil
            self.request = request
            tableView.reloadData()
            observeReview()
        }
        if metrics != self.metrics {
            self.metrics = metrics
            estimator = RowHeightEstimator(metrics: metrics)
            lineHeights = [:]
            for (cell, row) in liveCells() { show(rows[row], in: cell, isNewRow: false) }
            widthChanged = true
            scheduleFlush()
        }
        apply(new)
        if request != self.request {
            self.request = request
            target = request
            settle(anchor: nil)
            // A revealed line, not a jump from the navigator.
            if let request, request.anchor == .center { highlight(request) }
        }
        layoutPinnedHeader()
    }

    /// Marks a revealed line for a moment, so the eye finds it.
    private func highlight(_ request: DiffScrollState.Request) {
        highlighted = (request, CACurrentMediaTime())
        tableView.layoutSubtreeIfNeeded()
        guard let row = rows.firstIndex(where: { $0.id == request.row }) else { return }
        (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeLineCell)?.highlight(symbol: request.symbol)
    }

    /// Shows `new` by removing, inserting, and updating rows, so the rows that stay keep their place.
    private func apply(_ new: [DiffTableRow]) {
        let old = rows
        guard let changes = rowChanges(from: old.map(\.id), to: new.map(\.id)) else {
            rows = new
            let ids = Set(new.map(\.id))
            measured = measured.filter { ids.contains($0.key) }
            lineHeights = [:]
            tableView.reloadData()
            reportVisibleRowsSoon()
            return
        }
        let anchor = anchor()
        rows = new
        if !changes.removed.isEmpty || !changes.inserted.isEmpty {
            for index in changes.removed {
                measured[old[index].id] = nil
                lineHeights[old[index].id] = nil
            }
            tableView.beginUpdates()
            tableView.removeRows(at: changes.removed, withAnimation: [])
            tableView.insertRows(at: changes.inserted, withAnimation: [])
            tableView.endUpdates()
        }

        // Rows that stay and show something else: styled text, the other layout, another gutter width.
        var stale = IndexSet()
        var oldIndex = 0
        for (index, row) in new.enumerated() where !changes.inserted.contains(index) {
            while changes.removed.contains(oldIndex) { oldIndex += 1 }
            let before = old[oldIndex]
            oldIndex += 1
            guard before != row else { continue }
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
            if let cell { show(row, in: cell, isNewRow: false) }
            if row.codeLine != nil {
                let height = height(of: before)
                lineHeights[row.id] = nil
                if height != self.height(of: row) { stale.insert(index) }
            } else if cell == nil, estimator.height(of: before.kind, width: width) != estimator.height(of: row.kind, width: width) {
                // A hosted row on screen reports its height itself when it changes.
                measured[row.id] = nil
                stale.insert(index)
            }
        }
        noteHeights(stale)
        tableView.layoutSubtreeIfNeeded()
        settle(anchor: anchor)
        reportVisibleRowsSoon()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        height(of: rows[row])
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffTableRowView { return view }
        let view = DiffTableRowView()
        view.identifier = identifier
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        if item.codeLine != nil {
            let identifier = NSUserInterfaceItemIdentifier("code")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NativeLineCell ?? NativeLineCell()
            cell.identifier = identifier
            show(item, in: cell, isNewRow: true)
            return cell
        }
        let identifier = switch item.kind {
        case .header: NSUserInterfaceItemIdentifier("header")
        case .line: NSUserInterfaceItemIdentifier("line")
        case .attachments: NSUserInterfaceItemIdentifier("attachments")
        case .rendered: NSUserInterfaceItemIdentifier("rendered")
        case .spacer: NSUserInterfaceItemIdentifier("spacer")
        }
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffTableCell ?? DiffTableCell()
        cell.identifier = identifier
        show(item, in: cell, isNewRow: true)
        return cell
    }

    private func show(_ row: DiffTableRow, in view: NSView, isNewRow: Bool) {
        if let cell = view as? NativeLineCell, let line = row.codeLine {
            cell.show(line.row, digits: line.digits, metrics: metrics, file: row.file, model: model, marks: marks)
            if isNewRow, let highlighted, highlighted.request.row == row.id,
               CACurrentMediaTime() - highlighted.time < NativeLineCell.highlightHold
            {
                cell.highlight(symbol: highlighted.request.symbol)
            }
        } else if let cell = view as? DiffTableCell {
            show(row, in: cell, isNewRow: isNewRow)
        }
    }

    /// Whether a cell that gets this row builds its view again, so no view state carries over.
    /// A file header and a hunk header have no state, and updating the view in place costs a
    /// fraction of building it.
    private func startsOver(_ row: DiffTableRow) -> Bool {
        switch row.kind {
        case .header: false
        case .line(let line, _): if case .hunk = line.kind { false } else { true }
        case .attachments, .rendered, .spacer: true
        }
    }

    private func show(_ row: DiffTableRow, in cell: DiffTableCell, isNewRow: Bool) {
        let isNewRow = isNewRow && startsOver(row)
        let generation = cell.generation + (isNewRow ? 1 : 0)
        let hosted = HostedRow(row: row, model: model, metrics: metrics, generation: generation) { [weak self, weak cell] height in
            guard let self, let cell else { return }
            cell.reportedHeight = height
            self.measuredHeight(height, of: row, in: cell)
        }
        cell.show(hosted, isNewRow: isNewRow)
        // A view updated in place reports its height only when it changes. Until then the new row is as tall as the last one.
        if let height = cell.reportedHeight { measuredHeight(height, of: row, in: cell) }
    }

    /// The cells the table holds, on screen or just off it, with their rows.
    private func liveCells() -> [(cell: NSView, row: Int)] {
        var cells: [(NSView, Int)] = []
        tableView.enumerateAvailableRowViews { rowView, row in
            if let cell = rowView.view(atColumn: 0) as? NSView { cells.append((cell, row)) }
        }
        return cells
    }

    // MARK: Heights

    private func height(of row: DiffTableRow) -> CGFloat {
        guard row.codeLine != nil else { return measured[row.id] ?? estimator.height(of: row.kind, width: width) }
        if let height = lineHeights[row.id] { return height }
        let height = estimator.height(of: row.kind, width: width)
        lineHeights[row.id] = height
        return height
    }

    /// Called by a hosted row when SwiftUI has laid it out. This can be before the table has the cell.
    private func measuredHeight(_ height: CGFloat, of row: DiffTableRow, in cell: DiffTableCell) {
        guard height > 0 else { return }
        let known = self.height(of: row)
        measured[row.id] = height
        guard abs(known - height) > 0.01 else { return }
        // SwiftUI is in the middle of its layout here. The table is told afterwards.
        remeasured.append((cell, row.id))
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        // On the run loop, so it also runs while a scroll or a resize is being tracked.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        isFlushScheduled = false
        // A row gets its real height just after it scrolls in at an edge. Holding the middle row
        // moves the difference off screen, whichever edge it was.
        // At the top or the bottom of the list, the edge is held instead: the user scrolled there to see it.
        let visible = tableView.visibleRect
        let isAtBottom = visible.minY > 0 && visible.maxY >= tableView.bounds.maxY - 0.5
        let anchor = anchor(inMiddle: visible.minY > 0)
        var indexes = IndexSet(remeasured.compactMap { cell, id in
            let row = tableView.row(for: cell)
            return rows.indices.contains(row) && rows[row].id == id ? row : rows.firstIndex { $0.id == id }
        })
        remeasured = []

        // Heights depend on the width. They are redone once a live resize is over. Each of its
        // frames redoes only the rows on screen.
        if widthChanged, tableView.inLiveResize {
            let range = tableView.rows(in: visible)
            indexes.formUnion(IndexSet(integersIn: range.location..<(range.location + range.length)))
        } else if widthChanged {
            widthChanged = false
            let live = Set(liveCells().map { rows[$0.row].id })
            measured = measured.filter { live.contains($0.key) }
            indexes = IndexSet(integersIn: 0..<rows.count)
        }
        noteHeights(indexes)
        if isAtBottom, target == nil {
            scroll(toY: tableView.bounds.maxY)
        } else {
            settle(anchor: anchor)
        }
        layoutPinnedHeader()
        if visibleRowsChanged { reportVisibleRows() }
    }

    private func noteHeights(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        NSAnimationContext.endGrouping()
    }

    @objc private func frameChanged() {
        // Until the scroll view has a size, the table is as wide as a new column: 100 points.
        // Every line wraps at that width, and laying them all out for it is wasted.
        guard scrollView.frame.width > 0 else { return }
        let new = tableView.bounds.width
        guard new != width else { return }
        // The first width is known before any row has been measured.
        if width == 0 {
            width = new
            lineHeights = [:]
            noteHeights(IndexSet(integersIn: 0..<rows.count))
            return
        }
        width = new
        lineHeights = [:]
        widthChanged = true
        layoutPinnedHeader()
        scheduleFlush()
    }

    // MARK: Scroll position

    /// A row to hold in place while rows change height or come and go: the
    /// one at the top of the visible area, or the one in its middle.
    private struct Anchor {
        let id: RowID
        /// From the row's top to the top of the visible area.
        let offset: CGFloat
    }

    private func anchor(inMiddle: Bool = false) -> Anchor? {
        let visible = tableView.visibleRect
        let row = tableView.row(at: CGPoint(x: 0, y: inMiddle ? visible.midY : visible.minY))
        guard rows.indices.contains(row) else { return nil }
        return Anchor(id: rows[row].id, offset: visible.minY - tableView.rect(ofRow: row).minY)
    }

    /// Puts the list back where it was after rows changed: on the pending
    /// request when there is one, otherwise on the row that was at the top.
    private func settle(anchor: Anchor?) {
        if let target, let row = rows.firstIndex(where: { $0.id == target.row }) {
            let frame = tableView.rect(ofRow: row)
            var y = frame.minY
            // A line goes below the pinned header of its file.
            if rows[row].kind != .header { y -= height(of: rows[headerIndexes[row]]) }
            if target.anchor == .center {
                // The middle of what the header leaves free. A row taller than that starts at its top.
                y -= max(0, tableView.visibleRect.maxY - tableView.visibleRect.minY - (frame.minY - y) - frame.height) / 2
            }
            scroll(toY: y)
        } else if let anchor, let row = rows.firstIndex(where: { $0.id == anchor.id }) {
            scroll(toY: tableView.rect(ofRow: row).minY + anchor.offset)
        }
    }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y = y
        let origin = clip.constrainBoundsRect(bounds).origin
        guard origin != clip.bounds.origin else { return }
        isScrollingItself = true
        clip.scroll(to: origin)
        isScrollingItself = false
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func userScrolled() {
        target = nil
    }

    @objc private func boundsChanged() {
        // Any scroll the list did not make itself is the user's, and ends the hold on a requested row.
        // A mouse wheel posts no live-scroll notification, so that alone left the hold in place and
        // each height update pulled the list back to the requested row.
        if !isScrollingItself { target = nil }
        scrolled()
        layoutPinnedHeader()
        reportVisibleRows()
    }

    /// Shows the header of the file at the top of the list over the rows.
    /// The next file's header pushes it out as it arrives.
    private func layoutPinnedHeader() {
        let clip = scrollView.contentView
        let top = clip.bounds.minY
        let topRow = min(max(tableView.row(at: CGPoint(x: 0, y: max(top, 0))), 0), rows.count - 1)
        pinnedHeader.isHidden = rows.isEmpty
        guard !rows.isEmpty else { return }
        let index = headerIndexes[topRow]
        let header = rows[index]
        if header != pinnedRow {
            show(header, in: pinnedHeader, isNewRow: header.id != pinnedRow?.id)
            pinnedRow = header
        }

        let height = height(of: header)
        // Where the header is in the list, when that is lower: the list is pulled down past its top.
        var y = max(tableView.rect(ofRow: index).minY - top, 0)
        let below = tableView.row(at: CGPoint(x: 0, y: top + height))
        if rows.indices.contains(below), headerIndexes[below] != index {
            y = min(y, tableView.rect(ofRow: headerIndexes[below]).minY - top - height)
        }
        pinnedHeader.frame = CGRect(x: clip.frame.minX, y: clip.frame.minY + y, width: clip.frame.width, height: height)
    }

    /// Reports the visible rows after the current SwiftUI update, which must not change the model.
    private func reportVisibleRowsSoon() {
        visibleRowsChanged = true
        scheduleFlush()
    }

    /// Tells the model which rows are on screen. A line hidden under the
    /// pinned header does not count, so a row the model scrolls back to is
    /// one the user could see.
    private func reportVisibleRows() {
        visibleRowsChanged = false
        let visible = tableView.visibleRect
        let range = tableView.rows(in: visible)
        guard range.length > 0, range.location + range.length <= rows.count else { return }
        let first = rows[range.location]
        let covered = first.kind == .header ? 0 : height(of: RowID(file: first.id.file, item: .header))
        var ids: [RowID] = []
        for index in range.location..<(range.location + range.length) {
            let row = rows[index]
            switch row.kind {
            case .spacer: continue
            case .header: ids.append(row.id)
            case .line, .attachments, .rendered:
                if tableView.rect(ofRow: index).maxY > visible.minY + covered { ids.append(row.id) }
            }
        }
        model.visibleRowsChanged(ids)
    }

    private func height(of header: RowID) -> CGFloat {
        measured[header] ?? DiffMetrics.headerHeight
    }

    // MARK: Review marks

    /// Gives the code lines on screen the review's selection and comment ranges, now and whenever they change.
    private func observeReview() {
        let marks = withObservationTracking { ReviewMarks(model.review) } onChange: { [weak self] in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { self?.observeReview() }
            }
        }
        guard marks != self.marks else { return }
        self.marks = marks
        for (cell, _) in liveCells() { (cell as? NativeLineCell)?.show(marks: marks) }
    }

    // MARK: Pointer

    /// The code line at a point of the table, and the point in the cell's coordinates.
    private func lineCell(at point: CGPoint) -> (cell: NativeLineCell, point: CGPoint)? {
        let row = tableView.row(at: point)
        guard row >= 0, let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeLineCell else { return nil }
        return (cell, cell.convert(point, from: tableView))
    }

    /// Moves the hover to the code line under the pointer. Only that line and the one the pointer left redraw.
    private func pointerMoved(to point: CGPoint?) {
        guard !isWaitingForScrollEnd, !isDraggingGutter else { return }
        var hit: (cell: NativeLineCell, point: CGPoint)?
        // The pinned header covers the rows under it.
        if let point, tableView.visibleRect.contains(point), !pinnedHeader.frame.contains(scrollView.convert(point, from: tableView)) {
            hit = lineCell(at: point)
        }
        if hoveredCell !== hit?.cell { _ = hoveredCell?.pointerMoved(to: nil) }
        hoveredCell = hit?.cell
        let isOverLink = hit.map { $0.cell.pointerMoved(to: $0.point) } ?? false
        // Set only on a change, so the cursors of the hosted rows are left alone.
        if isOverLink != showsLinkCursor {
            showsLinkCursor = isOverLink
            (isOverLink ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    /// Takes the hover away while the list scrolls, and gives it to the row under the pointer once the scroll is over.
    private func scrolled() {
        lastScroll = CACurrentMediaTime()
        guard !isWaitingForScrollEnd else { return }
        pointerMoved(to: nil)
        isWaitingForScrollEnd = true
        perform(#selector(scrollMayHaveEnded), with: nil, afterDelay: Self.scrollEndDelay, inModes: [.common])
    }

    @objc private func scrollMayHaveEnded() {
        let remaining = Self.scrollEndDelay - (CACurrentMediaTime() - lastScroll)
        guard remaining <= 0 else {
            perform(#selector(scrollMayHaveEnded), with: nil, afterDelay: remaining, inModes: [.common])
            return
        }
        isWaitingForScrollEnd = false
        // An offscreen window has no pointer over it.
        guard let window = tableView.window, window.isVisible else { return }
        pointerMoved(to: tableView.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// A press on a code line: on its "+" it starts a gutter drag, on an identifier it arms a lookup.
    private func pointerDown(_ event: NSEvent) -> Bool {
        guard let hit = lineCell(at: tableView.convert(event.locationInWindow, from: nil)) else { return false }
        if let review = model.review, let file = hit.cell.file, let line = hit.cell.plusLine(at: hit.point) {
            isDraggingGutter = true
            review.beginDrag(file: file.id, line: line)
        } else {
            pressedIdentifier = hit.cell.identifier(at: hit.point)?.name
        }
        return true
    }

    private func pointerDragged(_ event: NSEvent) {
        guard isDraggingGutter else { return }
        tableView.autoscroll(with: event)
        dragGutter(to: event)
    }

    /// Extends the dragged range to the row at the pointer's height. Rows are found by position, so
    /// one that scrolled into view during the drag counts.
    private func dragGutter(to event: NSEvent) {
        guard let review = model.review, let origin = review.dragOrigin else { return }
        let row = tableView.row(at: CGPoint(x: tableView.bounds.midX, y: tableView.convert(event.locationInWindow, from: nil).y))
        guard rows.indices.contains(row), rows[row].file.id == origin.file, let line = rows[row].codeLine else { return }
        review.drag(over: line.row.cells.map(\.line))
    }

    private func pointerUp(_ event: NSEvent) {
        if isDraggingGutter {
            isDraggingGutter = false
            dragGutter(to: event)
            // A shift-click extends the open comment's range to the clicked line.
            model.review?.endDrag(extendsSelection: event.modifierFlags.contains(.shift))
        } else if let name = pressedIdentifier, let hit = lineCell(at: tableView.convert(event.locationInWindow, from: nil)),
                  hit.cell.identifier(at: hit.point)?.name == name, let file = hit.cell.file
        {
            showDefinition(of: name, from: file.diff.path, at: hit.cell.identifierRect(at: hit.point).map { hit.cell.convert($0, to: tableView) })
        }
        pressedIdentifier = nil
    }

    // MARK: Popover

    /// Looks `name` up in the definition popover, shown over `rect` of the table.
    private func showDefinition(of name: String, from path: String, at rect: CGRect?) {
        let peek = model.peek
        peek.lookUp(name: name, from: path)
        let content = DefinitionPane(model: model, definitions: peek, style: .popover { [weak self, model] in
            if let page = peek.current { model.definitions.show(page) }
            self?.popover.close()
        })
        .environment(\.diffMetrics, metrics)
        .environment(model.review)
        popover.show(
            content, size: DiffMetrics.definitionPopoverSize, relativeTo: rect ?? .zero, of: tableView
        ) { peek.isOpen = false }
    }
}

import AppKit
import Observation

/// A request to bring a log line into view. A new `id` makes the text view act
/// again, even for the same line.
struct LogFocus: Equatable {
    var id: Int
    var line: Int
    /// The match to select on the line. Nil scrolls the line near the top.
    var match: LogMatch?
}

/// State of the log viewer for one job log.
@Observable @MainActor
final class LogViewModel {
    let document: LogDocument

    private(set) var rendered = RenderedLog.empty
    private(set) var expanded: Set<Int>
    private(set) var focus: LogFocus?

    var showTimestamps = false { didSet { if showTimestamps != oldValue { render() } } }
    var wrapsLines = false

    var query = ""
    private(set) var matches: [LogMatch] = []
    private(set) var currentMatch: Int?

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var focusCount = 0

    /// Parses and renders a raw job log off the main actor. The log opens
    /// with the groups that contain an error expanded, at the first error.
    static func load(raw: String) async -> LogViewModel {
        let (document, rendered) = await Task.detached {
            let document = LogParser.parse(raw)
            return (document, LogRenderer.render(document, expanded: document.sectionsWithErrors, showTimestamps: false))
        }.value
        return LogViewModel(document: document, rendered: rendered)
    }

    private init(document: LogDocument, rendered: RenderedLog) {
        self.document = document
        self.rendered = rendered
        expanded = document.sectionsWithErrors
        if let firstError = document.firstError { setFocus(line: firstError, match: nil) }
    }

    var allExpanded: Bool { expanded.count == document.sections.count }

    /// Opens or closes the group whose title is on a log line.
    func toggleGroup(titledAt line: Int) {
        guard let section = document.lines[line].section else { return }
        expanded.formSymmetricDifference([section])
        render()
    }

    func setAllExpanded(_ isExpanded: Bool) {
        expanded = isExpanded ? Set(document.sections.indices) : []
        render()
    }

    /// Runs the search for `query`. Call from a task keyed on `query`, so a
    /// newer query cancels this one.
    func search() async {
        let query = query, document = document
        guard !query.isEmpty else {
            (matches, currentMatch) = ([], nil)
            return
        }
        // Wait out fast typing before scanning a large log.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let found = await Task.detached { LogSearch.matches(of: query, in: document) }.value
        guard !Task.isCancelled else { return }
        matches = found
        currentMatch = nil
        step(by: 1)
    }

    /// Moves to the next (`1`) or previous (`-1`) match, wrapping around.
    func step(by offset: Int) {
        guard !matches.isEmpty else { return }
        let next = ((currentMatch ?? (offset > 0 ? -1 : 0)) + offset + matches.count) % matches.count
        currentMatch = next

        let match = matches[next]
        if let section = document.lines[match.line].section, !expanded.contains(section),
           document.lines[match.line].kind != .group {
            expanded.insert(section)
                render()
        }
        setFocus(line: match.line, match: match)
    }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LogRenderer.plainText(document, showTimestamps: showTimestamps), forType: .string)
    }

    private func setFocus(line: Int, match: LogMatch?) {
        focusCount += 1
        focus = LogFocus(id: focusCount, line: line, match: match)
    }

    private func render() {
        renderTask?.cancel()
        let document = document, expanded = expanded, showTimestamps = showTimestamps
        renderTask = Task {
            let result = await Task.detached {
                LogRenderer.render(document, expanded: expanded, showTimestamps: showTimestamps)
            }.value
            guard !Task.isCancelled else { return }
            rendered = result
        }
    }
}

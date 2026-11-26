import AppKit
import Observation
import RepoKit

/// The definition pane: what it shows and the pages visited before it.
@Observable @MainActor
final class DefinitionModel {
    /// One stop in the pane's history.
    struct Page: Identifiable {
        enum Phase {
            /// Working, with a line that says on what.
            case searching(String)
            /// Nothing to show, and why.
            case message(title: String, detail: String)
            /// Several definitions to pick from.
            case choices([DefinitionLocation])
            /// The lines that use the name. `isTruncated` is true when the search stopped before the last match.
            case references([ReferenceLocation], isTruncated: Bool)
            /// A file, at a zero-based line that is marked.
            case file(path: String, line: Int, CodeFile)
        }

        let id: Int
        /// The identifier that was looked up, or the file that was opened.
        let name: String
        var phase: Phase
    }

    private(set) var pages: [Page] = []
    /// The index of the page on screen.
    private(set) var index = 0
    var isOpen = false

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The files to search. Fetching a pull request's commit can take a while.
    @ObservationIgnored var tree: @MainActor () async throws -> any SourceTree = { throw DefinitionError.noSourceTree }
    @ObservationIgnored private let fetchStatus: String

    /// - Parameter fetchStatus: What the pane says while `tree` runs.
    init(fetchStatus: String) {
        self.fetchStatus = fetchStatus
    }

    var current: Page? { pages.indices.contains(index) ? pages[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < pages.count - 1 }

    func goBack() { if canGoBack { index -= 1 } }
    func goForward() { if canGoForward { index += 1 } }

    /// Whether a click on an identifier looks up its definition or its references.
    enum Lookup {
        case definition
        case references

        /// Maps ⌘-click to `.references` and a plain click to `.definition`.
        init(_ modifiers: NSEvent.ModifierFlags) {
            self = modifiers.contains(.command) ? .references : .definition
        }
    }

    /// Looks up `name`, clicked in the file at `origin`, on a new page.
    func lookUp(_ lookup: Lookup = .definition, name: String, from origin: String) {
        switch lookup {
        case .definition: findDefinition(of: name, from: origin)
        case .references: findReferences(to: name, from: origin)
        }
    }

    private func findDefinition(of name: String, from origin: String) {
        let page = push(name: name, phase: .searching(fetchStatus))
        run(on: page) { [tree] model in
            let tree = try await tree()
            model.update(page, .searching("Searching for “\(name)”…"))
            switch try await DefinitionSearch.find(name: name, origin: origin, in: tree) {
            case .found(let locations) where locations.count == 1:
                model.update(page, try await Self.load(path: locations[0].path, line: locations[0].line, from: tree))
            case .found(let locations):
                model.update(page, .choices(locations))
            case .notFound:
                model.update(page, .message(
                    title: "No Definition Found",
                    detail: "Nothing in this repository defines “\(name)”. It may come from a library or from generated code."
                ))
            case .unsupported(let files):
                model.update(page, .message(
                    title: "Language Not Supported",
                    detail: "“\(name)” appears in \(files == 1 ? "1 file" : "\(files) files"), but in no language Hermes can find definitions in."
                ))
            }
        }
    }

    private func findReferences(to name: String, from origin: String) {
        let page = push(name: name, phase: .searching(fetchStatus))
        run(on: page, failure: "Couldn't Find References") { [tree] model in
            let tree = try await tree()
            model.update(page, .searching("Searching for uses of “\(name)”…"))
            let found = try await ReferenceSearch.find(name: name, origin: origin, in: tree)
            model.update(page, found.locations.isEmpty
                ? .message(title: "No References Found", detail: "No code in this repository uses “\(name)”.")
                : .references(found.locations, isTruncated: found.isTruncated))
        }
    }

    /// Opens `path` at `line` on a new page. `name` is the identifier the list of definitions or references was for.
    func open(path: String, line: Int, name: String) {
        let page = push(name: name, phase: .searching("Opening \(path)…"))
        run(on: page) { [tree] model in
            model.update(page, try await Self.load(path: path, line: line, from: try await tree()))
        }
    }

    /// Opens a whole file on a new page, at a zero-based line.
    func openFile(_ path: String, line: Int) {
        let page = push(name: (path as NSString).lastPathComponent, phase: .searching(fetchStatus))
        run(on: page, failure: "Couldn't Open the File") { [tree] model in
            model.update(page, try await Self.load(path: path, line: line, from: try await tree()))
        }
    }

    /// Shows a page from another definition model, such as the popover's, on a new page.
    func show(_ page: Page) {
        _ = push(name: page.name, phase: page.phase)
    }

    private func push(name: String, phase: Page.Phase) -> Int {
        nextID += 1
        // A new page replaces whatever was ahead in the history.
        pages = Array(pages.prefix(index + 1)) + [Page(id: nextID, name: name, phase: phase)]
        index = pages.count - 1
        isOpen = true
        return nextID
    }

    private func run(
        on page: Int, failure: String = "Couldn't Look Up the Definition", _ body: @escaping @MainActor (DefinitionModel) async throws -> Void
    ) {
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await body(self)
            } catch is CancellationError {
                update(page, .message(title: "Cancelled", detail: "Something else opened before this finished."))
            } catch {
                update(page, .message(title: failure, detail: DiffLoader.message(for: error)))
            }
        }
    }

    private func update(_ page: Int, _ phase: Page.Phase) {
        guard let index = pages.firstIndex(where: { $0.id == page }) else { return }
        pages[index].phase = phase
    }

    private nonisolated static func load(path: String, line: Int, from tree: any SourceTree) async throws -> Page.Phase {
        .file(path: path, line: line, CodeFile(source: try await tree.readFile(path), path: path))
    }
}

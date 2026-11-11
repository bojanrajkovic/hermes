import Foundation
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
            case file(DefinitionLocation, CodeFile)
        }

        let id: Int
        /// The identifier that was looked up.
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

    /// Looks up `name`, clicked in the file at `origin`, on a new page.
    func lookUp(name: String, from origin: String) {
        let page = push(name: name, phase: .searching(fetchStatus))
        run(on: page) { [tree] model in
            let tree = try await tree()
            model.update(page, .searching("Searching for “\(name)”…"))
            switch try await DefinitionSearch.find(name: name, origin: origin, in: tree) {
            case .found(let locations) where locations.count == 1:
                model.update(page, .file(locations[0], try await Self.load(locations[0], from: tree)))
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

    /// Opens one of several definitions on a new page.
    func open(_ location: DefinitionLocation, name: String) {
        let page = push(name: name, phase: .searching("Opening \(location.path)…"))
        run(on: page) { [tree] model in
            model.update(page, .file(location, try await Self.load(location, from: try await tree())))
        }
    }

    private func push(name: String, phase: Page.Phase) -> Int {
        nextID += 1
        // A new page replaces whatever was ahead in the history.
        pages = Array(pages.prefix(index + 1)) + [Page(id: nextID, name: name, phase: phase)]
        index = pages.count - 1
        isOpen = true
        return nextID
    }

    private func run(on page: Int, _ body: @escaping @MainActor (DefinitionModel) async throws -> Void) {
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await body(self)
            } catch is CancellationError {
                update(page, .message(title: "Lookup Cancelled", detail: "Another lookup started before this one finished."))
            } catch {
                update(page, .message(title: "Couldn't Look Up the Definition", detail: DiffLoader.message(for: error)))
            }
        }
    }

    private func update(_ page: Int, _ phase: Page.Phase) {
        guard let index = pages.firstIndex(where: { $0.id == page }) else { return }
        pages[index].phase = phase
    }

    private nonisolated static func load(_ location: DefinitionLocation, from tree: any SourceTree) async throws -> CodeFile {
        CodeFile(source: try await tree.readFile(location.path), path: location.path)
    }
}

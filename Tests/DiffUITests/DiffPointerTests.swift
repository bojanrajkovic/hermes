import AppKit
import DiffKit
import Foundation
import GitHubKit
import RepoKit
import SwiftUI
import Testing
@testable import DiffUI

private let sample = """
    diff --git a/Sources/App/Greeter.swift b/Sources/App/Greeter.swift
    index 1111111..2222222 100644
    --- a/Sources/App/Greeter.swift
    +++ b/Sources/App/Greeter.swift
    @@ -3,5 +3,7 @@ struct Greeter {
         let name: String

    -    func greet() -> String { "Hello" }
    +    func greet() -> String { "Hello!" }
    +    func part() -> String { "Bye" }
    +    func third() -> String { name }

     }

    """

/// The pointer on the code lines the table draws itself: the "+" in the gutter, the gutter drag,
/// and a click on an identifier. The events are made by hand and sent to the views, in a window that is not on screen.
///
/// `DIFFUI_RENDER=<directory>` also writes PNGs of the hovered and the selected rows.
@MainActor
struct DiffPointerTests {
    private let model: DiffModel
    private let window: NSWindow
    private let host: NSHostingView<DiffList>
    private let root = FileManager.default.temporaryDirectory.appending(path: "hermes-pointer-\(UUID().uuidString)")
    private let metrics = DiffMetrics()

    init() async throws {
        let pullRequest = PullRequest(
            id: "PR", number: 1, title: "", url: URL(string: "https://github.com/a/b/pull/1")!,
            repository: RepositoryRef(owner: "a", name: "b"), author: nil, isDraft: false, createdAt: .now, updatedAt: .now,
            headRefName: "", baseRefName: "", headOID: "", reviewDecision: nil, additions: 0, deletions: 0,
            changedFileCount: 0, mergeable: .unknown, labels: [], checkState: nil, stack: nil, closingIssueNumbers: []
        )
        model = DiffModel(source: .pullRequest(pullRequest), client: GitHubClient(), repoCache: RepoCache(), draftsRoot: root)
        await model.show(text: sample)
        // A reload gives the review its diff. `show(text:)` alone does not.
        model.review?.show(diff: Diff(parsing: sample), head: nil)
        await model.background?.value
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        host = NSHostingView(rootView: DiffList(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView = host
        try await settle()
    }

    private func settle() async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
    }

    private var table: NSTableView {
        func find(_ view: NSView) -> NSTableView? { view as? NSTableView ?? view.subviews.lazy.compactMap(find).first }
        return find(host)!
    }

    private var lines: [DiffLine] { model.files[0].diff.hunks[0].lines }

    /// The table row of a line. Row 0 is the file header and row 1 the hunk header.
    private func row(of line: DiffLine) -> Int {
        tableRows(files: model.files, attached: model.review?.attachedLines ?? [:]).firstIndex { $0.id == RowID(file: model.files[0].id, item: .line(line.numbers)) }!
    }

    /// The "+" of a unified row: the last 16 points of the gutter.
    private var plusX: CGFloat {
        metrics.gutterWidth(digits: model.files[0].gutterDigits, columns: 2) + metrics.markerWidth - ReviewMetrics.plusWidth / 2
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat, line: DiffLine, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let point = table.convert(CGPoint(x: x, y: table.rect(ofRow: row(of: line)).midY), to: nil)
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func cell(of line: DiffLine) -> NSView {
        table.view(atColumn: 0, row: row(of: line), makeIfNecessary: false)!
    }

    private func write(_ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DIFFUI_RENDER"] else { return }
        try FileManager.default.createDirectory(at: URL(filePath: directory), withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: directory).appending(path: name))
    }

    @Test func aDragDownTheGutterStartsACommentOnTheRange() async throws {
        let review = try #require(model.review)
        // The press goes to the line's cell, which passes it up to the table.
        cell(of: lines[3]).mouseDown(with: event(.leftMouseDown, x: plusX, line: lines[3]))
        #expect(review.dragOrigin?.line == lines[3])
        #expect(review.selection?.lines == [lines[3].numbers])
        table.mouseDragged(with: event(.leftMouseDragged, x: 300, line: lines[5]))
        #expect(review.selection?.lines == Set(lines[3...5].map(\.numbers)))
        try await settle()
        try write("pointer-drag.png")
        table.mouseUp(with: event(.leftMouseUp, x: 300, line: lines[5]))

        #expect(review.dragOrigin == nil)
        guard case .thread(_, let under, let anchor) = review.composer?.target else {
            Issue.record("no composer")
            return
        }
        #expect(under == lines[5].numbers)
        #expect(anchor.start == lines[3].commentPosition)
        #expect(anchor.end == lines[5].commentPosition)
        // The composer is a row of its own, after the range's last line.
        try await settle()
        #expect(table.numberOfRows == 2 + lines.count + 1 + 1)
        #expect(!(table.view(atColumn: 0, row: row(of: lines[5]) + 1, makeIfNecessary: false) is NativeLineCell))
        try write("pointer-composer.png")
    }

    @Test func aShiftClickExtendsTheOpenComment() async throws {
        let review = try #require(model.review)
        review.startComment(file: model.files[0].id, from: lines[3], to: lines[3])
        review.composer?.text = "kept"
        // The composer's row pushes the lines below it down.
        try await settle()
        cell(of: lines[5]).mouseDown(with: event(.leftMouseDown, x: plusX, line: lines[5], flags: .shift))
        table.mouseUp(with: event(.leftMouseUp, x: plusX, line: lines[5], flags: .shift))
        #expect(review.composer?.text == "kept")
        #expect(review.selection?.lines == Set(lines[3...5].map(\.numbers)))
    }

    @Test func aPressAwayFromThePlusStartsNothing() throws {
        let review = try #require(model.review)
        cell(of: lines[3]).mouseDown(with: event(.leftMouseDown, x: 5, line: lines[3]))
        table.mouseUp(with: event(.leftMouseUp, x: 5, line: lines[3]))
        #expect(review.dragOrigin == nil)
        #expect(review.composer == nil)
    }

    @Test func theRowUnderThePointerShowsItsPlusAndAnIdentifierIsALink() async throws {
        let native = try #require(cell(of: lines[4]) as? NativeLineCell)
        let codeX = metrics.gutterWidth(digits: model.files[0].gutterDigits, columns: 2) + metrics.markerWidth
        // "    func part() ...": the name starts at column 9.
        let nameX = codeX + 11 * metrics.characterWidth
        table.mouseMoved(with: event(.mouseMoved, x: nameX, line: lines[4]))
        // The line is parsed when the pointer first reaches it.
        try await Task.sleep(for: .milliseconds(300))
        table.mouseMoved(with: event(.mouseMoved, x: nameX, line: lines[4]))
        let point = native.convert(event(.mouseMoved, x: nameX, line: lines[4]).locationInWindow, from: nil)
        #expect(native.identifier(at: point)?.name == "part")
        #expect(native.identifier(at: CGPoint(x: codeX + 2, y: point.y)) == nil)
        #expect(native.plusLine(at: CGPoint(x: plusX, y: point.y)) == lines[4])
        try await settle()
        try write("pointer-hover.png")

        table.mouseDown(with: event(.leftMouseDown, x: nameX, line: lines[4]))
        table.mouseUp(with: event(.leftMouseUp, x: nameX, line: lines[4]))
        #expect(model.peek.current?.name == "part")
    }

    /// The tints over a line that was just revealed: the row's, then one per marked symbol.
    private func highlights(of line: DiffLine) -> [NSView] {
        let tints = cell(of: line).subviews
        return tints + tints.flatMap(\.subviews)
    }

    @Test func aRevealedLineIsHighlightedAndAJumpIsNot() async throws {
        let id = RowID(file: model.files[0].id, item: .line(lines[4].numbers))
        model.scroll.scroll(to: id)
        try await Task.sleep(for: .milliseconds(60))
        #expect(highlights(of: lines[4]).isEmpty)

        model.reveal(id, symbol: "part")
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        // The row's tint and the symbol's mark. The row is as tall as before.
        #expect(highlights(of: lines[4]).count == 2)
        #expect(highlights(of: lines[3]).isEmpty)
        #expect(table.rect(ofRow: row(of: lines[4])).height == metrics.lineHeight + 2 * DiffMetrics.rowPadding)
        try write("reveal-highlight.png")

        // Revealing the same line again starts over, with one tint.
        model.reveal(id)
        try await Task.sleep(for: .milliseconds(60))
        #expect(highlights(of: lines[4]).count == 1)

        // It fades and goes away.
        try await Task.sleep(for: .milliseconds(Int((NativeLineCell.highlightHold + NativeLineCell.highlightFade) * 1000) + 400))
        #expect(highlights(of: lines[4]).isEmpty)
    }

    @Test func theMenuCopiesTheLineAndVoiceOverReadsIt() throws {
        let native = try #require(cell(of: lines[4]) as? NativeLineCell)
        let menu = try #require(native.menu(for: event(.rightMouseDown, x: 300, line: lines[4])))
        #expect(menu.items.map(\.title) == ["Copy Line", "Add Comment…"])
        #expect(native.accessibilityLabel() == "Added line 6:     func part() -> String { \"Bye\" }")
        let actions = try #require(native.accessibilityCustomActions())
        #expect(actions.map(\.name) == ["Comment on line 6"])
        _ = actions[0].handler?()
        #expect(model.review?.composer != nil)
    }
}

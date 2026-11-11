import Testing
@testable import DiffKit

@Suite struct CommentAnchorTests {
    private let file = twoHunkDiff.files[0]
    private func left(_ line: Int) -> DiffPosition { DiffPosition(side: .left, line: line) }
    private func right(_ line: Int) -> DiffPosition { DiffPosition(side: .right, line: line) }

    @Test func anchorSideFollowsTheLineKind() throws {
        let lines = file.hunks[1].lines
        #expect(file.anchor(for: lines[0]) == CommentAnchor(path: "lines.txt", end: right(13)))
        #expect(file.anchor(for: lines[3]) == CommentAnchor(path: "lines.txt", end: left(15)))
        #expect(file.anchor(for: file.hunks[0].lines[3]) == CommentAnchor(path: "lines.txt", end: right(4)))
        #expect(DiffSide.left.rawValue == "LEFT")
        #expect(DiffSide.right.rawValue == "RIGHT")
    }

    @Test func anchorsUseTheNewPathOfARenamedFile() throws {
        let renamed = try fixture("git-cases").files[5]
        let deletion = try #require(renamed.hunks[0].lines.first { $0.kind == .deletion })
        #expect(renamed.anchor(for: deletion) == CommentAnchor(path: "moved to.txt", end: left(8)))
    }

    @Test func locationFindsContextLinesFromEitherSide() {
        // "L4" is old line 4 and new line 5.
        #expect(file.location(of: left(4)) == LineLocation(hunkIndex: 0, lineIndex: 4))
        #expect(file.location(of: right(5)) == LineLocation(hunkIndex: 0, lineIndex: 4))
        #expect(file.location(of: right(4)) == LineLocation(hunkIndex: 0, lineIndex: 3))
        #expect(file.location(of: left(15)) == LineLocation(hunkIndex: 1, lineIndex: 3))
        #expect(file.location(of: right(9)) == nil)
        #expect(file.location(of: left(8)) == nil)
    }

    @Test func rangeWithinOneHunk() throws {
        #expect(try file.rangeAnchor(from: right(2), to: right(5)) == CommentAnchor(path: "lines.txt", start: right(2), end: right(5)))
        // A range may start on a deletion and end on the new side.
        #expect(try file.rangeAnchor(from: left(15), to: right(16)) == CommentAnchor(path: "lines.txt", start: left(15), end: right(16)))
    }

    @Test func rangeSelectedUpwardIsPutInDiffOrder() throws {
        #expect(try file.rangeAnchor(from: right(16), to: left(15)) == CommentAnchor(path: "lines.txt", start: left(15), end: right(16)))
    }

    @Test func rangeOnOneLineIsASingleLineAnchor() throws {
        #expect(try file.rangeAnchor(from: right(4), to: right(4)) == CommentAnchor(path: "lines.txt", end: right(4)))
    }

    @Test func rangeAcrossHunksIsRejected() {
        #expect(throws: RangeSelectionError.differentHunks) { try file.rangeAnchor(from: right(2), to: right(14)) }
    }

    @Test func rangeEndingOutsideTheDiffIsRejected() {
        #expect(throws: RangeSelectionError.notInDiff(right(9))) { try file.rangeAnchor(from: right(7), to: right(9)) }
        #expect(throws: RangeSelectionError.notInDiff(left(99))) { try file.rangeAnchor(from: left(99), to: right(7)) }
    }
}

@Suite struct ThreadPlacementTests {
    private struct Thread: Equatable {
        let id: Int
        let anchor: CommentAnchor?
    }

    private func anchor(_ path: String, _ side: DiffSide, _ line: Int, start: DiffPosition? = nil) -> CommentAnchor {
        CommentAnchor(path: path, start: start, end: DiffPosition(side: side, line: line))
    }

    @Test func placesThreadsOnEitherEntryOfATypeChange() {
        let threads = [Thread(id: 1, anchor: anchor("f", .left, 2)), Thread(id: 2, anchor: anchor("f", .right, 1))]
        let result = typeChangeDiff.place(threads, anchor: \.anchor)
        #expect(result.unplaced.isEmpty)
        #expect(result.placed.map(\.fileID) == typeChangeDiff.files.map(\.id))
        #expect(result.placed.map(\.end) == [LineLocation(hunkIndex: 0, lineIndex: 1), LineLocation(hunkIndex: 0, lineIndex: 0)])
    }

    @Test func placesThreadsAndReportsTheRest() throws {
        let diff = try fixture("git-cases")
        let threads = [
            Thread(id: 1, anchor: anchor("my file.txt", .right, 2)),
            Thread(id: 2, anchor: anchor("my file.txt", .left, 2)),
            Thread(id: 3, anchor: anchor("my file.txt", .right, 99)),
            Thread(id: 4, anchor: anchor("not/in/diff.txt", .right, 1)),
            Thread(id: 5, anchor: nil),
            Thread(id: 6, anchor: anchor("moved to.txt", .right, 8, start: DiffPosition(side: .right, line: 6))),
            Thread(id: 7, anchor: anchor("moved to.txt", .right, 8, start: DiffPosition(side: .right, line: 1))),
            Thread(id: 8, anchor: anchor("bin.dat", .right, 1)),
        ]

        let result = diff.place(threads, anchor: \.anchor)

        #expect(result.unplaced.map(\.id) == [3, 4, 5, 8])
        #expect(result.placed.map(\.thread.id) == [1, 2, 6, 7])
        #expect(result.placed.map(\.fileID) == ["my file.txt", "my file.txt", "moved to.txt", "moved to.txt"])
        #expect(result.placed.map(\.end) == [
            LineLocation(hunkIndex: 0, lineIndex: 2), LineLocation(hunkIndex: 0, lineIndex: 1),
            LineLocation(hunkIndex: 0, lineIndex: 4), LineLocation(hunkIndex: 0, lineIndex: 4),
        ])
        // A start line outside the diff is dropped; the thread still shows at its end line.
        #expect(result.placed.map(\.start) == [nil, nil, LineLocation(hunkIndex: 0, lineIndex: 1), nil])

        let file = try #require(diff.files.first { $0.id == "my file.txt" })
        #expect(file.hunks[0].lines[2].text == "2")
    }
}

extension ThreadPlacementTests {
    /// Review threads from airway PR 61 (`GET /pulls/61/comments`), placed on
    /// that PR's diff. The expected text is the last line of each comment's
    /// `diff_hunk`. Threads whose `line` is null are outdated.
    @Test func realThreadsLandOnTheLineGitHubShows() throws {
        let diff = try fixture("airway-pr61-reviewed-files")
        let threads: [(path: String, line: Int?, text: String)] = [
            (".github/workflows/ci.yml", 27, "      - uses: jdx/mise-action@f5be966e4a917d54244728e6a5fdcd1d93a35e6c # v5.2.6"),
            (".github/workflows/ci.yml", 53, "        image: postgres:18@sha256:"),
            (".github/workflows/ci.yml", 32, "      - if: github.ref == 'refs/heads/main'"),
            ("docs/ci.md", nil, ""),
            ("docs/ci.md", 22, "## The ruleset on main"),
            ("docs/development.md", nil, ""),
            ("docs/development.md", nil, ""),
        ]

        let result = diff.place(threads) { thread in
            thread.line.map { CommentAnchor(path: thread.path, end: DiffPosition(side: .right, line: $0)) }
        }

        #expect(result.unplaced.count == 3)
        #expect(result.placed.count == 4)
        for placed in result.placed {
            let file = try #require(diff.files.first { $0.id == placed.fileID })
            let line = file.hunks[placed.end.hunkIndex].lines[placed.end.lineIndex]
            #expect(line.text.hasPrefix(placed.thread.text))
            #expect(line.newNumber == placed.thread.line)
        }
    }
}

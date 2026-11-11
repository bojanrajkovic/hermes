import Testing
@testable import DiffKit

@Suite struct ContextExpansionTests {
    @Test func regionsCoverEveryLineTheHunksLeaveOut() {
        let file = twoHunkDiff.files[0]
        let regions = file.hiddenRegions(newText: twoHunkNewText)

        #expect(regions.map(\.hunkIndex) == [1, 2])
        // Between the hunks the insertion has shifted new numbers up by one.
        #expect(regions[0].lines.map(\.numbers) == (7...11).map { .context(old: $0, new: $0 + 1) })
        // After the second hunk the deletion has shifted them back.
        #expect(regions[1].lines.map(\.numbers) == [.context(old: 19, new: 19), .context(old: 20, new: 20)])

        // Hunks and regions together show each new line once, with the old line's text.
        let shown = (file.hunks.flatMap(\.lines) + regions.flatMap(\.lines)).filter { $0.kind != .deletion }
        #expect(shown.compactMap(\.newNumber).sorted() == Array(1...20))
        for line in shown where line.kind == .context {
            #expect(line.text == "L\(line.oldNumber ?? 0)")
        }
    }

    @Test func expandsInChunksFromEitherEnd() {
        var region = twoHunkDiff.files[0].hiddenRegions(newText: twoHunkNewText)[0]

        #expect(region.expand(.down(2)).map(\.text) == ["L7", "L8"])
        #expect(region.expand(.up(2)).map(\.text) == ["L10", "L11"])
        #expect(region.lines.map(\.text) == ["L9"])
        #expect(region.expand(.up(20)).map(\.text) == ["L9"])
        #expect(region.lines.isEmpty)
        #expect(region.expand(.down(20)).isEmpty)

        var all = twoHunkDiff.files[0].hiddenRegions(newText: twoHunkNewText)[0]
        #expect(all.expand(.all).count == 5)
        #expect(all.lines.isEmpty)
    }

    @Test func regionBeforeTheFirstHunkAndZeroCountHunks() {
        // Two lines inserted after old line 10, then old lines 14 and 15 deleted.
        let diff = Diff(parsing: """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -10,0 +11,2 @@
            +x
            +y
            @@ -14,2 +15,0 @@
            -n
            -o

            """)
        let newText = (1...10).map { "\($0)" }.joined(separator: "\r\n") + "\r\nx\r\ny\r\n11\r\n12\r\n13\r\n16\r\nlast"
        let regions = diff.files[0].hiddenRegions(newText: newText)

        #expect(regions.map(\.hunkIndex) == [0, 1, 2])
        #expect(regions[0].lines.map(\.numbers) == (1...10).map { .context(old: $0, new: $0) })
        #expect(regions[1].lines.map(\.numbers) == (11...13).map { .context(old: $0, new: $0 + 2) })
        #expect(regions[1].lines.map(\.text) == ["11", "12", "13"])
        #expect(regions[2].lines.map(\.numbers) == [.context(old: 16, new: 16), .context(old: 17, new: 17)])
        #expect(regions[2].lines.map(\.text) == ["16", "last"])
        #expect(regions[2].lines.map(\.ending) == [.crlf, .none])
    }

    @Test func filesWithNothingToExpand() throws {
        let diff = try fixture("git-cases")
        // Deleted, binary, and a file whose single hunk covers all of it.
        #expect(diff.files[4].hiddenRegions(newText: "").isEmpty)
        #expect(diff.files[0].hiddenRegions(newText: "anything\n").isEmpty)
        #expect(diff.files[6].hiddenRegions(newText: "one\n2\nthree\n").isEmpty)
    }

    @Test func pureRenameExpandsToTheWholeFile() throws {
        let renamed = try fixture("git-cases").files[8]
        let regions = renamed.hiddenRegions(newText: "1\n2\n3\n")
        #expect(regions.count == 1)
        #expect(regions[0].hunkIndex == 0)
        #expect(regions[0].lines.map(\.numbers) == (1...3).map { .context(old: $0, new: $0) })
    }
}

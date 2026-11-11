import Testing
@testable import DiffKit

@Suite struct SplitRowTests {
    @Test func pairsDeletionsWithAdditionsInsideEachChangeBlock() {
        let diff = Diff(parsing: """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,8 +1,7 @@
             top
            -old one
            -old two
            -old three
            +new one
             middle
            -gone
             between
            +added one
            +added two
             bottom

            """)
        let rows = diff.files[0].hunks[0].splitRows
        #expect(rows.map { $0.old?.text } == ["top", "old one", "old two", "old three", "middle", "gone", "between", nil, nil, "bottom"])
        #expect(rows.map { $0.new?.text } == ["top", "new one", nil, nil, "middle", nil, "between", "added one", "added two", "bottom"])
        #expect(rows.map { $0.old?.oldNumber } == [1, 2, 3, 4, 5, 6, 7, nil, nil, 8])
        #expect(rows.map { $0.new?.newNumber } == [1, 2, nil, nil, 3, nil, 4, 5, 6, 7])

        guard case .paired(let deletion, let addition) = rows[1] else {
            Issue.record("expected a pair, got \(rows[1])")
            return
        }
        #expect(deletion.kind == .deletion)
        #expect(addition.kind == .addition)
    }

    @Test func realRenameHunk() throws {
        let rows = try fixture("git-cases").files[5].hunks[0].splitRows
        #expect(rows.count == 4)
        #expect(rows[3].old?.text == "8")
        #expect(rows[3].new?.text == "eight")
    }
}

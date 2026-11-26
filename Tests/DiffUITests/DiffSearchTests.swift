import DiffKit
import Foundation
import Testing
@testable import DiffUI

private let sample = """
    diff --git a/a.swift b/a.swift
    index 1111111..2222222 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,3 +1,3 @@
     let total = 1
    -print(Total + total)
    +print(total + subtotal)
     done
    diff --git a/b.swift b/b.swift
    index 1111111..2222222 100644
    --- a/b.swift
    +++ b/b.swift
    @@ -1,1 +1,1 @@
    -old
    +TOTAL

    """

private func rows(_ layout: DiffLayout) -> [[DiffRow]] {
    Diff(parsing: sample).files.map {
        diffRows(file: $0, expansion: FileExpansion(), layout: layout) { AttributedString($0.text) }
    }
}

private func describe(_ matches: [DiffMatch]) -> [String] {
    matches.map { "\($0.row.file) \($0.line) \($0.range)" }
}

struct DiffSearchTests {
    @Test func matchesEveryOccurrenceIgnoringCaseInDiffOrder() {
        #expect(describe(DiffSearch.matches(of: "total", in: rows(.unified))) == [
            "a.swift context(old: 1, new: 1) 4..<9",
            "a.swift deletion(old: 2) 6..<11", "a.swift deletion(old: 2) 14..<19",
            "a.swift addition(new: 2) 6..<11", "a.swift addition(new: 2) 17..<22",
            "b.swift addition(new: 1) 0..<5",
        ])
    }

    @Test func splitRowsMatchBothSidesAndKeepTheRowsID() {
        let matches = DiffSearch.matches(of: "subtotal", in: rows(.split))
        let row = rows(.split)[0][2]
        #expect(matches.map(\.row) == [row.id])
        let removed = DiffSearch.matches(of: "Total + total", in: rows(.split))
        #expect(removed.map(\.row) == [row.id])
        #expect(removed.map(\.line) == [.deletion(old: 2)])
    }

    @Test func aContextLineInASplitRowCountsOnce() {
        #expect(DiffSearch.matches(of: "done", in: rows(.split)).count == 1)
    }

    @MainActor @Test func aNewQueryStartsAtItsFirstMatchAndStepsWrap() {
        let find = DiffFind()
        let matches = DiffSearch.matches(of: "total", in: rows(.unified))
        #expect(find.show(matches, for: "total") == matches[0])
        #expect(find.step(by: -1) == matches[5])
        #expect(find.step(by: 1) == matches[0])
        #expect(find.ranges["a.swift"]?[.deletion(old: 2)] == [6..<11, 14..<19])
    }

    @MainActor @Test func searchingAgainKeepsTheMatchOnScreen() {
        let find = DiffFind()
        let matches = DiffSearch.matches(of: "total", in: rows(.unified))
        _ = find.show(matches, for: "total")
        _ = find.step(by: 1)
        _ = find.step(by: 1)
        // The rows changed and the first match went away: the current one stays current, at its new index.
        #expect(find.show(Array(matches.dropFirst()), for: "total") == nil)
        #expect(find.current == 1)
        #expect(find.currentMatch == matches[2])
    }

    @MainActor @Test func aRemovedLineStaysCurrentAcrossLayouts() {
        let find = DiffFind()
        let unified = DiffSearch.matches(of: "Total + total", in: rows(.unified))
        _ = find.show(unified, for: "Total + total")
        let split = DiffSearch.matches(of: "Total + total", in: rows(.split))
        #expect(split[0].row != unified[0].row)
        _ = find.show(split, for: "Total + total")
        #expect(find.current == 0)
    }

    @Test func anEmptyQueryMatchesNothing() {
        #expect(DiffSearch.matches(of: "", in: rows(.unified)).isEmpty)
    }
}

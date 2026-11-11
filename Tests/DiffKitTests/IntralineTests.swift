import Testing
@testable import DiffKit

@Suite struct IntralineTests {
    /// The changed substrings on each side, or `nil` when highlighting is skipped.
    private func changed(_ old: String, _ new: String) -> [[String]]? {
        intralineChange(old: old, new: new).map { change in
            [change.old.map { String(old[$0]) }, change.new.map { String(new[$0]) }]
        }
    }

    @Test func changedToken() {
        #expect(changed("let x = 1", "let x = 2") == [["1"], ["2"]])
        #expect(changed("call(alpha, beta)", "call(alpha, gamma, beta)") == [[], ["gamma, "]])
    }

    @Test func changedTokenIsTrimmedToTheCharactersThatDiffer() {
        #expect(changed("fooBar()", "fooBaz()") == [["r"], ["z"]])
        #expect(changed("    indented()", "  indented()") == [["  "], []])
    }

    @Test func severalChanges() {
        #expect(changed("let total = price * count", "let total = cost * count + tax") == [["price"], ["cost", " + tax"]])
    }

    @Test func insertionAtTheEnd() {
        #expect(changed("return a", "return a + b") == [[], [" + b"]])
    }

    @Test func equalLinesHaveNoRanges() {
        #expect(changed("same", "same") == [[], []])
        #expect(changed("", "") == [[], []])
    }

    @Test func dissimilarLinesAreSkipped() {
        #expect(changed("import Foundation", "let value = compute(input)") == nil)
        #expect(changed("a", "b") == nil)
    }

    @Test func veryLongLinesAreSkipped() {
        let long = String(repeating: "x ", count: 1500)
        #expect(changed(long, long + "y") == nil)
    }

    @Test func linesOfManyTokensAreSkipped() {
        let numbers = (0..<250).map(String.init).joined(separator: ",")
        #expect(changed(numbers, numbers + ",250") == nil)
        let fewer = (0..<150).map(String.init).joined(separator: ",")
        #expect(changed(fewer, fewer + ",150") == [[], [",150"]])
    }

    @Test func rangesDoNotSplitMultiByteCharacters() {
        // "é" and "è" share their first UTF-8 byte.
        #expect(changed("let s = \"héllo\"", "let s = \"hèllo\"") == [["é"], ["è"]])
        #expect(changed("say(\"日本\")", "say(\"日本語\")") == [[], ["語"]])
    }
}

import Testing
@testable import DiffKit

@Suite struct ParsingTests {
    // MARK: A real GitHub diff

    @Test func gitHubDiffMatchesGitHubsFileList() throws {
        let diff = try fixture("airway-pr95")
        // Paths and counts as reported by `gh pr view 95 --json files`.
        let expected: [(String, Int, Int, Bool)] = [
            ("docs/explorer.md", 24, 1, false),
            ("docs/query.md", 14, 0, false),
            ("packages/contract/src/query/canonical.ts", 108, 0, true),
            ("packages/contract/src/query/link.ts", 34, 0, true),
            ("packages/contract/src/query/short-code.ts", 37, 0, true),
            ("packages/contract/tests/query/canonical.test.ts", 172, 0, true),
            ("packages/contract/tests/query/link.test.ts", 69, 0, true),
            ("packages/contract/tests/query/short-code.test.ts", 62, 0, true),
        ]
        #expect(diff.files.count == expected.count)
        for (file, (path, additions, deletions, isAdded)) in zip(diff.files, expected) {
            #expect(file.id == path)
            #expect(file.additions == additions)
            #expect(file.deletions == deletions)
            #expect(file.change == (isAdded ? .added(path: path) : .modified(path: path)))
            #expect(file.oldPath == (isAdded ? nil : path))
            #expect(file.oldMode == (isAdded ? nil : "100644"))
            #expect(file.newMode == "100644")
            expectConsistentNumbering(file)
        }
    }

    @Test func gitHubDiffHunkHeaders() throws {
        let diff = try fixture("airway-pr95")
        let first = try #require(diff.files[0].hunks.first)
        #expect([first.oldStart, first.oldCount, first.newStart, first.newCount] == [2, 4, 2, 27])
        #expect(first.sectionHeading == "")

        let second = try #require(diff.files[1].hunks.first)
        #expect([second.oldStart, second.oldCount, second.newStart, second.newCount] == [91, 3, 91, 17])
        #expect(second.sectionHeading.hasPrefix("Each limit keeps one group's series"))

        let added = try #require(diff.files[2].hunks.first)
        #expect([added.oldStart, added.oldCount, added.newStart, added.newCount] == [0, 0, 1, 108])
        #expect(added.lines.first?.numbers == .addition(new: 1))
        #expect(added.lines.last?.numbers == .addition(new: 108))
    }

    // MARK: Real `git diff` output for the unusual cases

    @Test func binaryFiles() throws {
        let diff = try fixture("git-cases")
        #expect(diff.files[0].change == .modified(path: "bin.dat"))
        #expect(diff.files[0].content == .binary)
        #expect(diff.files[0].hunks.isEmpty)

        let second = try fixture("git-cases-2")
        #expect(second.files[0].change == .added(path: "added.bin"))
        #expect(second.files[0].content == .binary)
        #expect(second.files[1].change == .deleted(path: "bin.dat"))
        #expect(second.files[1].content == .binary)
        #expect(second.files[1].newMode == nil)
        // `git diff --binary` prints a base85 patch instead of "Binary files differ".
        #expect(second.files[5].change == .added(path: "added.bin"))
        #expect(second.files[5].content == .binary)
        #expect(second.files.count == 6)
    }

    @Test func copyWithChanges() throws {
        let file = try fixture("git-cases").files[1]
        #expect(file.change == .copied(from: "my file.txt", to: "copy.txt"))
        #expect(file.oldPath == "my file.txt")
        #expect(file.newPath == "copy.txt")
        #expect(file.id == "copy.txt")
        #expect((file.additions, file.deletions) == (1, 1))
    }

    @Test func crlfContentKeepsTextCleanAndRecordsTheEnding() throws {
        let lines = try fixture("git-cases").files[2].hunks[0].lines
        #expect(lines.map(\.text) == ["a", "b", "B"])
        #expect(lines.map(\.ending) == [.crlf, .crlf, .crlf])
    }

    @Test func renames() throws {
        let diff = try fixture("git-cases")
        let pure = diff.files[3]
        #expect(pure.change == .renamed(from: "emptygone.txt", to: "empty.txt"))
        #expect(pure.content == .text([]))
        #expect((pure.additions, pure.deletions) == (0, 0))

        let changed = diff.files[5]
        #expect(changed.change == .renamed(from: "same.txt", to: "moved to.txt"))
        #expect(changed.id == "moved to.txt")
        #expect(changed.hunks[0].lines.map(\.numbers) == [
            .context(old: 5, new: 5), .context(old: 6, new: 6), .context(old: 7, new: 7),
            .deletion(old: 8), .addition(new: 8),
        ])
        #expect(changed.hunks[0].lines.map(\.text) == ["5", "6", "7", "8", "eight"])
    }

    @Test func deletedFile() throws {
        let file = try fixture("git-cases").files[4]
        #expect(file.change == .deleted(path: "gone.txt"))
        #expect(file.newPath == nil)
        #expect(file.id == "gone.txt")
        #expect((file.oldMode, file.newMode) == ("100644", nil))
        // "@@ -1 +0,0 @@" leaves out the count of 1.
        #expect([file.hunks[0].oldStart, file.hunks[0].oldCount, file.hunks[0].newCount] == [1, 1, 0])
        #expect(file.hunks[0].lines.map(\.numbers) == [.deletion(old: 1)])
    }

    @Test func pathWithSpacesDropsTheTrailingTab() throws {
        let file = try fixture("git-cases").files[6]
        #expect(file.change == .modified(path: "my file.txt"))
    }

    @Test func noNewlineAtEndOfFile() throws {
        let lines = try fixture("git-cases").files[7].hunks[0].lines
        #expect(lines.map(\.text) == ["x", "y", "y2"])
        #expect(lines.map(\.ending) == [.lf, .none, .none])
        #expect(lines.map(\.numbers) == [.context(old: 1, new: 1), .deletion(old: 2), .addition(new: 2)])
    }

    @Test func modeChangeOnly() throws {
        let file = try fixture("git-cases").files[9]
        #expect(file.change == .modified(path: "run.sh"))
        #expect((file.oldMode, file.newMode) == ("100644", "100755"))
        #expect(file.isModeChange)
        #expect(file.content == .text([]))
    }

    @Test func quotedPaths() throws {
        let diff = try fixture("git-cases")
        #expect(diff.files[10].change == .modified(path: "t\tab.txt"))
        #expect(diff.files[11].change == .modified(path: "é.txt"))
        #expect(diff.files[11].hunks[0].lines.map(\.text) == ["e", "e2"])
        #expect(diff.files.count == 12)
        diff.files.forEach { expectConsistentNumbering($0) }
    }

    // MARK: Hand-written cases

    @Test func emptyAddedAndDeletedFilesTakeTheirPathFromTheGitLine() {
        let diff = Diff(parsing: #"""
            diff --git a/new empty.txt b/new empty.txt
            new file mode 100644
            index 0000000..e69de29
            diff --git a/old.txt b/old.txt
            deleted file mode 100644
            index e69de29..0000000
            diff --git "a/q\"uote.txt" "b/q\"uote.txt"
            new file mode 100755
            index 0000000..e69de29

            """#)
        #expect(diff.files.map(\.change) == [
            .added(path: "new empty.txt"), .deleted(path: "old.txt"), .added(path: "q\"uote.txt"),
        ])
        #expect(diff.files.map(\.content) == [.text([]), .text([]), .text([])])
        #expect(diff.files[2].newMode == "100755")
    }

    @Test func renameWithModeChangeAndContentInOneEntry() {
        let diff = Diff(parsing: """
            diff --git a/old.sh b/bin/new name.sh
            old mode 100644
            new mode 100755
            similarity index 66%
            rename from old.sh
            rename to bin/new name.sh
            index 1111111..2222222
            --- a/old.sh
            +++ b/bin/new name.sh\t
            @@ -1,2 +1,3 @@ main()
             echo one
            +echo two
             echo three

            """)
        let file = diff.files[0]
        #expect(file.change == .renamed(from: "old.sh", to: "bin/new name.sh"))
        #expect((file.oldMode, file.newMode) == ("100644", "100755"))
        #expect(file.isModeChange)
        #expect(file.hunks[0].sectionHeading == "main()")
        #expect((file.additions, file.deletions) == (1, 0))
    }

    @Test func contentThatLooksLikeHeadersStaysContent() {
        // A deleted line "-- a/x" prints as "--- a/x", and so on.
        let diff = Diff(parsing: """
            diff --git a/notes.md b/notes.md
            index 1111111..2222222 100644
            --- a/notes.md
            +++ b/notes.md
            @@ -1,4 +1,4 @@
             keep
            --- a/x
            -diff --git a/y b/y
            -@@ -1 +1 @@
            +++ b/x
            +\\ not a marker
            +@@ also not a header
            diff --git a/next.txt b/next.txt
            index 1111111..2222222 100644
            --- a/next.txt
            +++ b/next.txt
            @@ -1 +1 @@
            -a
            +b

            """)
        #expect(diff.files.map(\.id) == ["notes.md", "next.txt"])
        #expect(diff.files[0].hunks[0].lines.map(\.text) == [
            "keep", "-- a/x", "diff --git a/y b/y", "@@ -1 +1 @@", "++ b/x", "\\ not a marker", "@@ also not a header",
        ])
        #expect((diff.files[0].additions, diff.files[0].deletions) == (3, 3))
        diff.files.forEach { expectConsistentNumbering($0) }
    }

    @Test func textAroundTheDiffIsIgnored() {
        let diff = Diff(parsing: """
            From 1234 Mon Sep 17 00:00:00 2001
            Subject: [PATCH] something

            diff --git a/a.txt b/a.txt
            index 1111111..2222222 100644
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -a
            +b
            --\u{20}
            2.50.0
            """)
        #expect(diff.files.count == 1)
        #expect(diff.files[0].hunks[0].lines.count == 2)
    }

    @Test func truncatedHunkKeepsTheLinesItHas() {
        let diff = Diff(parsing: "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,5 +1,5 @@\n one\n-two")
        #expect(diff.files[0].hunks[0].lines.map(\.text) == ["one", "two"])
    }

    @Test func emptyInputHasNoFiles() {
        #expect(Diff(parsing: "").files.isEmpty)
        #expect(Diff(parsing: "\n\n").files.isEmpty)
    }

    @Test func typeChangeEntriesHaveDistinctIDs() {
        let files = typeChangeDiff.files
        #expect(files.map(\.change) == [.deleted(path: "f"), .added(path: "f")])
        #expect(files.map(\.path) == ["f", "f"])
        #expect(files[0].id == "f")
        #expect(files[1].id != "f")
    }

    @Test func hugeHunkCountsDoNotReserveMemory() {
        let diff = Diff(parsing: "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,999999999999999 +1,999999999999999 @@\n-a\n+b\n")
        #expect(diff.files[0].hunks[0].lines.map(\.text) == ["a", "b"])
    }

    @Test func combinedEntryDoesNotChangeTheFileBeforeIt() {
        let diff = Diff(parsing: """
            diff --git a/script.sh b/script.sh
            old mode 100644
            new mode 100755
            diff --cc merged.txt
            index 1111111,2222222..3333333
            --- a/merged.txt
            +++ b/merged.txt
            @@@ -1,1 -1,1 +1,1 @@@
            - a
             -b
            ++c

            """)
        #expect(diff.files.map(\.change) == [.modified(path: "script.sh")])
    }

    // MARK: Performance

    @Test func parsesFiftyThousandLinesWellUnderASecond() {
        var text = ""
        for file in 0..<250 {
            text += "diff --git a/src/file\(file).swift b/src/file\(file).swift\nindex 1111111..2222222 100644\n"
            text += "--- a/src/file\(file).swift\n+++ b/src/file\(file).swift\n"
            for hunk in 0..<4 {
                text += "@@ -\(hunk * 100 + 1),40 +\(hunk * 100 + 1),40 @@ func example\(hunk)()\n"
                for line in 0..<30 { text += "     let value\(line) = compute(input: \(line), scale: 2.0) // context\n" }
                for line in 0..<10 { text += "-    let old\(line) = oldCompute(input: \(line))\n" }
                for line in 0..<10 { text += "+    let new\(line) = newCompute(input: \(line), extra: true)\n" }
            }
        }
        var diff = Diff(parsing: "")
        let elapsed = ContinuousClock().measure { diff = Diff(parsing: text) }
        #expect(diff.files.count == 250)
        #expect(diff.files.reduce(0) { $0 + $1.hunks.reduce(0) { $0 + $1.lines.count } } == 50_000)
        #expect(elapsed < .milliseconds(500), "parsing took \(elapsed)")
    }
}

import Testing
@testable import DiffKit

@Suite struct FirstChangeTests {
    private func file(_ body: String) -> FileDiff {
        Diff(parsing: "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n" + body).files[0]
    }

    @Test func anAdditionIsItsOwnLine() {
        let file = file("@@ -4,3 +4,4 @@\n one\n two\n+new\n three\n")
        #expect(file.firstChangedLine == 6)
    }

    @Test func aDeletionIsTheNewLineThatFollowsIt() {
        let file = file("@@ -4,3 +4,2 @@\n one\n-gone\n two\n")
        #expect(file.firstChangedLine == 5)
    }

    @Test func aDeletionAtTheEndIsTheLineBeforeIt() {
        let file = file("@@ -4,2 +4,1 @@\n one\n-gone\n")
        #expect(file.firstChangedLine == 4)
    }

    @Test func aDeletedFileHasNoNewLine() {
        let file = Diff(parsing: """
            diff --git a/a.txt b/a.txt
            deleted file mode 100644
            --- a/a.txt
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -one
            -two

            """).files[0]
        #expect(file.firstChangedLine == nil)
    }
}

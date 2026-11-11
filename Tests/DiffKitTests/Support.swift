import Foundation
import Testing
@testable import DiffKit

/// Loads a diff saved under `Fixtures/`.
func fixture(_ name: String) throws -> Diff {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "diff", subdirectory: "Fixtures"))
    return Diff(parsing: try String(contentsOf: url, encoding: .utf8))
}

/// A file with two hunks: `NEW` inserted after `L3`, and `L15` deleted.
/// The old file is `L1`...`L20`, one per line.
let twoHunkDiff = Diff(parsing: """
    diff --git a/lines.txt b/lines.txt
    index 1111111..2222222 100644
    --- a/lines.txt
    +++ b/lines.txt
    @@ -1,6 +1,7 @@
     L1
     L2
     L3
    +NEW
     L4
     L5
     L6
    @@ -12,7 +13,6 @@ heading text
     L12
     L13
     L14
    -L15
     L16
     L17
     L18

    """)

let twoHunkNewText = (["L1", "L2", "L3", "NEW"] + (4...14).map { "L\($0)" } + (16...20).map { "L\($0)" })
    .joined(separator: "\n") + "\n"

/// Real `git diff` output for a file replaced by a symlink: a deleted entry
/// and an added entry with the same path.
let typeChangeDiff = Diff(parsing: """
    diff --git a/f b/f
    deleted file mode 100644
    index 422c2b7..0000000
    --- a/f
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -a
    -b
    diff --git a/f b/f
    new file mode 120000
    index 0000000..ddcd8d2
    --- /dev/null
    +++ b/f
    @@ -0,0 +1 @@
    +target
    \\ No newline at end of file

    """)

/// Checks that line numbers run consecutively from the hunk header and that
/// the header's counts match the lines.
func expectConsistentNumbering(_ file: FileDiff, sourceLocation: SourceLocation = #_sourceLocation) {
    for hunk in file.hunks {
        var old = hunk.oldStart, new = hunk.newStart
        for line in hunk.lines {
            if let number = line.oldNumber {
                #expect(number == old, sourceLocation: sourceLocation)
                old += 1
            }
            if let number = line.newNumber {
                #expect(number == new, sourceLocation: sourceLocation)
                new += 1
            }
        }
        #expect(old - hunk.oldStart == hunk.oldCount, sourceLocation: sourceLocation)
        #expect(new - hunk.newStart == hunk.newCount, sourceLocation: sourceLocation)
    }
    #expect(file.additions == file.hunks.flatMap(\.lines).count { $0.kind == .addition }, sourceLocation: sourceLocation)
    #expect(file.deletions == file.hunks.flatMap(\.lines).count { $0.kind == .deletion }, sourceLocation: sourceLocation)
}

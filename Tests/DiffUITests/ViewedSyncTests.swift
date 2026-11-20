import Testing
@testable import DiffUI

@Suite struct ViewedSyncTests {
    private let files: [(id: String, path: String, isViewed: Bool)] = [
        ("a.swift", "a.swift", false),
        ("b.swift", "b.swift", true),
        ("c.swift", "c.swift", false),
    ]

    @Test func matchingMarksChangeNothing() {
        #expect(viewedUpdates(files: files, remote: ["b.swift"], skipping: [], held: []).isEmpty)
    }

    @Test func gitHubMarksAndUnmarks() {
        let updates = viewedUpdates(files: files, remote: ["a.swift"], skipping: [], held: [])
        #expect(updates == [.mark("a.swift"), .unmark("b.swift")])
    }

    @Test func pathsBeingSentKeepTheirMark() {
        let updates = viewedUpdates(files: files, remote: ["a.swift", "c.swift"], skipping: ["b.swift", "c.swift"], held: [])
        #expect(updates == [.mark("a.swift")])
    }

    @Test func aFileTheUserIsInStaysOpen() {
        let updates = viewedUpdates(files: files, remote: ["a.swift", "b.swift", "c.swift"], skipping: [], held: ["a.swift"])
        #expect(updates == [.markKeepingOpen("a.swift"), .mark("c.swift")])
    }

    @Test func aRenamedFileMatchesOnItsGitHubPath() {
        let renamed = [(id: "new.swift", path: "new.swift", isViewed: false)]
        #expect(viewedUpdates(files: renamed, remote: ["old.swift"], skipping: [], held: []).isEmpty)
        #expect(viewedUpdates(files: renamed, remote: ["new.swift"], skipping: [], held: []) == [.mark("new.swift")])
    }
}

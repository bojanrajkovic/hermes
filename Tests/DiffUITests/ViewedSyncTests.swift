import Testing
@testable import DiffUI

@Suite struct ViewedSyncTests {
    private let files: [(id: String, path: String, isViewed: Bool)] = [
        ("a.swift", "a.swift", false),
        ("b.swift", "b.swift", true),
        ("c.swift", "c.swift", false),
    ]

    @Test func matchingMarksChangeNothing() {
        #expect(viewedUpdates(files: files, remote: ["b.swift"], held: []).isEmpty)
    }

    @Test func gitHubMarksAndUnmarks() {
        let updates = viewedUpdates(files: files, remote: ["a.swift"], held: [])
        #expect(updates == [.mark("a.swift"), .unmark("b.swift")])
    }

    @Test func aFileTheUserIsInStaysOpen() {
        let updates = viewedUpdates(files: files, remote: ["a.swift", "b.swift", "c.swift"], held: ["a.swift"])
        #expect(updates == [.markKeepingOpen("a.swift"), .mark("c.swift")])
    }

    @Test func aRenamedFileMatchesOnItsGitHubPath() {
        let renamed = [(id: "new.swift", path: "new.swift", isViewed: false)]
        #expect(viewedUpdates(files: renamed, remote: ["old.swift"], held: []).isEmpty)
        #expect(viewedUpdates(files: renamed, remote: ["new.swift"], held: []) == [.mark("new.swift")])
    }
}

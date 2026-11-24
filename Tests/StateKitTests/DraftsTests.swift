import Foundation
import GitHubKit
import TestSupport
import Testing
@testable import StateKit

struct DraftsTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)")
    private let key = ItemKey(repository: airway, number: 12)

    @Test func aCommentIsKeptBesideTheReviewAndRemovedWhenEmptied() throws {
        try Drafts.saveComment("Half a thought", root: root, key: key)
        let file = Drafts.url(root: root, repository: airway, number: 12, extension: "comment.md")
        #expect(file.path().hasSuffix("drafts/bojan/airway/12.comment.md"))
        #expect(Drafts.comment(root: root, key: key) == "Half a thought")

        try Drafts.saveComment("", root: root, key: key)
        #expect(!FileManager.default.fileExists(atPath: file.path()))
        #expect(Drafts.comment(root: root, key: key) == "")
    }
}

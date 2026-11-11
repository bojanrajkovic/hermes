import DiffKit
import AppKit
import Foundation
import GitHubKit
import os
import SwiftUI
import Testing
@testable import DiffUI

private let sample = """
    diff --git a/docs/guide.md b/docs/guide.md
    index 1111111..2222222 100644
    --- a/docs/guide.md
    +++ b/docs/guide.md
    @@ -2,5 +2,6 @@
     two
     three
    -four
    +FOUR
    +four and a half
     five
     six
    @@ -10,3 +11,2 @@
     ten
    -eleven
     twelve

    """

private let newGuide = "one\ntwo\nthree\nFOUR\nfour and a half\nfive\nsix\nseven\neight\nnine\nten\ntwelve\nthirteen\n"
private let oldGuide = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen\n"

private func thread(_ id: String, line: Int?, start: Int? = nil, side: GitHubKit.DiffSide = .right, outdated: Bool = false) -> ReviewThread {
    ReviewThread(
        id: id, path: "docs/guide.md", line: line, startLine: start, diffSide: side, startDiffSide: start.map { _ in side },
        isResolved: false, isOutdated: outdated, comments: []
    )
}

private func draft(_ line: Int, start: Int? = nil, side: DiffKit.DiffSide = .right) -> DraftComment {
    let anchor = CommentAnchor(
        path: "docs/guide.md", start: start.map { DiffPosition(side: side, line: $0) }, end: DiffPosition(side: side, line: line)
    )
    return DraftComment(anchor: anchor, body: "note on \(line)")
}

struct OldTextTests {
    private let file = Diff(parsing: sample).files[0]

    @Test func reversingTheHunksGivesTheOldFile() {
        #expect(oldText(newText: newGuide, hunks: file.hunks) == oldGuide)
    }

    @Test func aDeletedFileIsRebuiltFromNothing() {
        let deleted = Diff(parsing: """
            diff --git a/gone.md b/gone.md
            deleted file mode 100644
            index 1111111..0000000
            --- a/gone.md
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -# Gone
            -text

            """).files[0]
        #expect(oldText(newText: "", hunks: deleted.hunks) == "# Gone\ntext\n")
    }

    @Test func aDeletionAtTheTopKeepsTheLinesAfterIt() {
        let top = Diff(parsing: """
            diff --git a/a.md b/a.md
            index 1111111..2222222 100644
            --- a/a.md
            +++ b/a.md
            @@ -1,2 +0,0 @@
            -first
            -second

            """).files[0]
        #expect(oldText(newText: "third\r\nfourth", hunks: top.hunks) == "first\nsecond\nthird\r\nfourth")
    }
}

struct MarkdownAnchorTests {
    private let file = Diff(parsing: sample).files[0]

    @Test func aBlockInOneHunkIsCoveredWhole() throws {
        let anchor = try markdownAnchor(file: file, lines: 4...5).get()
        #expect(anchor == CommentAnchor(path: "docs/guide.md", start: DiffPosition(side: .right, line: 4), end: DiffPosition(side: .right, line: 5)))
    }

    @Test func linesOutsideTheDiffAreLeftOut() throws {
        // Line 1 is above the first hunk; lines 8-10 are between the hunks.
        #expect(try markdownAnchor(file: file, lines: 1...2).get() == CommentAnchor(path: "docs/guide.md", end: DiffPosition(side: .right, line: 2)))
        #expect(markdownAnchor(file: file, lines: 8...10) == .failure(.notInDiff))
    }

    @Test func aBlockAcrossHunksStaysInTheFirst() throws {
        let anchor = try markdownAnchor(file: file, lines: 6...12).get()
        #expect(anchor.start == DiffPosition(side: .right, line: 6))
        #expect(anchor.end == DiffPosition(side: .right, line: 7))
    }
}

struct ReviewLayoutTests {
    private let diff = Diff(parsing: sample)
    private var file: FileDiff.ID { diff.files[0].id }

    @Test func threadsAndDraftsSitUnderTheirLastLine() {
        let layout = ReviewLayout(
            diff: diff, threads: [thread("t1", line: 5, start: 4), thread("t2", line: 4, side: .left)],
            drafts: [draft(5), draft(11, side: .left)]
        )
        let lines = layout.lines[file] ?? [:]
        #expect(lines[.addition(new: 5)]?.threads.map(\.id) == ["t1"])
        #expect(lines[.addition(new: 5)]?.drafts.count == 1)
        #expect(lines[.deletion(old: 4)]?.threads.map(\.id) == ["t2"])
        #expect(lines[.deletion(old: 11)]?.drafts.count == 1)
        #expect(layout.rangeLines[file] == [.addition(new: 4), .addition(new: 5)])
        #expect(layout.markers(for: file) == [5: 2])
        #expect(layout.submittable.count == 2)
    }

    @Test func whatHasNoLineInTheDiffIsSetAside() {
        let reply = DraftComment(target: .reply(threadID: "gone"), body: "reply")
        let kept = DraftComment(target: .reply(threadID: "t1"), body: "reply")
        let layout = ReviewLayout(
            diff: diff, threads: [thread("t1", line: 4), thread("t2", line: nil, outdated: true), thread("t3", line: 9)],
            // Line 9 is between the hunks. The range 7...11 starts in one hunk and ends in the next.
            drafts: [draft(9), draft(11, start: 7), reply, kept, draft(4)]
        )
        #expect(layout.offDiffThreads.map(\.id) == ["t2", "t3"])
        #expect(Set(layout.outdatedDrafts.map(\.body)) == ["note on 9", "note on 11", "reply"])
        #expect(layout.replies["t1"] == [kept])
        #expect(layout.submittable.map(\.body) == ["reply", "note on 4"])
    }

    @Test func aSubmissionCarriesThreadsAndReplies() {
        let drafts = [draft(5, start: 4), draft(11, side: .left), DraftComment(target: .reply(threadID: "t1"), body: "reply")]
        let submission = ReviewSubmission(pullRequestID: "PR", commitOID: "abc", event: .comment, body: "", drafts: drafts)
        #expect(submission.threads == [
            .init(path: "docs/guide.md", start: .init(line: 4, side: .right), end: .init(line: 5, side: .right), body: "note on 5"),
            .init(path: "docs/guide.md", end: .init(line: 11, side: .left), body: "note on 11"),
        ])
        #expect(submission.replies == [.init(threadID: "t1", body: "reply")])
    }

    @Test func aThreadWhoseStartIsItsLineIsASingleLine() {
        #expect(thread("t", line: 25, start: 25).anchor == CommentAnchor(path: "docs/guide.md", end: DiffPosition(side: .right, line: 25)))
    }
}

struct PendingReviewTests {
    @Test func draftsRoundTripThroughDisk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hermes-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = PendingReview.url(root: root, repository: RepositoryRef(owner: "acme", name: "app"), number: 7)
        #expect(url.path.hasSuffix("drafts/acme/app/7.json"))
        #expect(PendingReview.load(from: url) == PendingReview())

        let review = PendingReview(comments: [draft(5, start: 4), DraftComment(target: .reply(threadID: "t1"), body: "reply")], summary: "Looks good")
        try review.save(to: url)
        #expect(PendingReview.load(from: url) == review)

        // An empty review leaves no file behind.
        try PendingReview().save(to: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

struct DefinitionCandidateTests {
    @Test func candidatesAreRankedByCloseness() {
        let paths = [
            "web/app.ts", "src/ts/zones.ts", "README.md", "src/go/zones.go", "src/ts/pricing.ts", "src/ts/zones.ts",
            "config/zones.json", "lib/a.ts",
        ]
        #expect(DefinitionSearch.candidates(among: paths, origin: "src/ts/pricing.ts") == [
            "src/ts/pricing.ts", "src/ts/zones.ts", "lib/a.ts", "web/app.ts", "src/go/zones.go",
        ])
    }

    @Test func candidatesAreCapped() {
        let paths = (0..<100).map { "pkg/file\($0).go" }
        #expect(DefinitionSearch.candidates(among: paths, origin: "main.go", limit: 5).count == 5)
    }
}

struct DisplayRangeTests {
    @Test func tabsBeforeAnIdentifierShiftIt() {
        // Two tabs become eight columns; the tab inside the range widens it.
        #expect(displayRange(of: 2..<5, in: "\t\tfoo") == 8..<11)
        #expect(displayRange(of: 0..<3, in: "a\tb") == 0..<6)
    }
}

/// Answers GitHub requests without the network: a pull request with no
/// threads or pending review, and a review that is accepted. Everything else, and every request
/// of a client whose token is `offline`, gets status 500.
private final class GitHubStub: URLProtocol {
    /// The body of every request so far.
    static let bodies = OSAllocatedUnfairLock<[String]>(initialState: [])

    static func client(token: String = "token") -> GitHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStub.self]
        return GitHubClient(session: URLSession(configuration: configuration), token: { token })
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLSession hands a protocol the body as a stream.
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { data.append(buffer, count: count) }
            stream.close()
        }
        let body = String(decoding: data, as: UTF8.self)
        Self.bodies.withLock { $0.append(body) }

        var answer: String?
        if request.value(forHTTPHeaderField: "Authorization") != "Bearer offline" {
            if body.contains("states: PENDING") {
                answer = #"{"data":{"node":{"reviews":{"nodes":[]}}}}"#
            } else if body.contains("reviewThreads") {
                let empty = #"{"nodes":[]}"#
                answer = """
                    {"data":{"repository":{"pullRequest":{"id":"PR_1","body":"","comments":\(empty),"reviews":\(empty),\
                    "reviewRequests":\(empty),"commits":\(empty),"reviewThreads":\(empty)}}}}
                    """
            } else if body.contains("addPullRequestReview(") {
                answer = #"{"data":{"result":{"pullRequestReview":{"id":"R_1","url":"https://github.com/acme/app/pull/7"}}}}"#
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 500 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((answer ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
struct ReviewModelTests {
    private let diff = Diff(parsing: sample)
    private let root = FileManager.default.temporaryDirectory.appending(path: "hermes-review-\(UUID().uuidString)")
    private var file: FileDiff { diff.files[0] }
    private var lines: [DiffLine] { file.hunks[0].lines }

    private func makeModel(client: GitHubClient = GitHubClient(), showing shown: Diff? = nil) -> ReviewModel {
        let pullRequest = PullRequest(
            id: "PR", number: 7, title: "Guide", url: URL(string: "https://github.com/acme/app/pull/7")!,
            repository: RepositoryRef(owner: "acme", name: "app"), author: nil, isDraft: false, createdAt: .now, updatedAt: .now,
            headRefName: "guide", baseRefName: "main", headOID: "abc", reviewDecision: nil, additions: 2, deletions: 2,
            changedFileCount: 1, mergeable: .mergeable, labels: [], checkState: nil, stack: nil, closingIssueNumbers: []
        )
        let model = ReviewModel(pullRequest: pullRequest, client: client, draftsRoot: root)
        model.show(diff: shown ?? diff, head: "abc")
        return model
    }

    @Test func threadsThatCouldNotBeLoadedAreReportedSoTheCallerAsksAgain() async {
        let offline = makeModel(client: GitHubStub.client(token: "offline"))
        #expect(await offline.reloadThreads() == false)
        #expect(offline.threadsError != nil)
        #expect(!offline.canSubmit(.approve))

        let online = makeModel(client: GitHubStub.client())
        #expect(await online.reloadThreads())
        #expect(online.threadsError == nil)
        #expect(online.canSubmit(.approve))
    }

    @Test func aCommentGoesFromComposerToDiskAndBack() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        // "four" is a deletion, so its comment is on the left side.
        model.startComment(file: file.id, from: lines[2], to: lines[2])
        #expect(model.composer?.target == .thread(
            file: file.id, under: .deletion(old: 4), anchor: CommentAnchor(path: "docs/guide.md", end: DiffPosition(side: .left, line: 4))
        ))
        model.composer?.text = "  why?  "
        model.addComposerToReview()
        #expect(model.composer == nil)
        #expect(model.layout.lines[file.id]?[.deletion(old: 4)]?.drafts.map(\.body) == ["why?"])

        await model.flush()
        let reopened = makeModel()
        #expect(reopened.pending.comments.map(\.body) == ["why?"])

        let draft = reopened.pending.comments[0]
        reopened.open(.edit(draft: draft.id))
        #expect(reopened.composer?.text == "why?")
        reopened.composer?.text = "why not?"
        reopened.addComposerToReview()
        #expect(reopened.pending.comments.map(\.body) == ["why not?"])
        reopened.delete(draft.id)
        #expect(reopened.pending.comments.isEmpty)
    }

    @Test func theCommentBeingWrittenIsThereAfterReopening() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.startComment(file: file.id, from: lines[3], to: lines[4])
        model.composer?.text = "half written"
        await model.flush()

        let reopened = makeModel()
        #expect(reopened.composer == model.composer)
        #expect(reopened.selection?.lines == [.addition(new: 4), .addition(new: 5)])

        // An edit comes back with the text typed so far, not the draft's.
        reopened.addComposerToReview()
        let draft = reopened.pending.comments[0]
        reopened.open(.edit(draft: draft.id))
        reopened.composer?.text = "rewritten"
        await reopened.flush()
        let edited = makeModel()
        #expect(edited.composer == ReviewModel.Composer(target: .edit(draft: draft.id), text: "rewritten"))
        #expect(edited.pending.comments.map(\.body) == ["half written"])

        // So does a reply.
        edited.addComposerToReview()
        edited.open(.reply(threadID: "t1"))
        edited.composer?.text = "agreed"
        await edited.flush()
        let replying = makeModel()
        #expect(replying.composer == ReviewModel.Composer(target: .reply(threadID: "t1"), text: "agreed"))

        // Discarded text is gone from disk too.
        replying.cancelComposer()
        replying.confirmDiscard()
        await replying.flush()
        #expect(makeModel().composer == nil)
    }

    @Test func aSavedCommentWhoseLinesLeftTheDiffBecomesAnOutdatedDraft() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.startComment(file: file.id, from: lines[3], to: lines[3])
        model.composer?.text = "half written"
        await model.flush()

        let reopened = makeModel(showing: Diff(parsing: ""))
        #expect(reopened.composer == nil)
        #expect(reopened.layout.outdatedDrafts.map(\.body) == ["half written"])
        await reopened.flush()
        #expect(PendingReview.load(from: PendingReview.url(root: root, repository: reopened.pullRequest.repository, number: 7)).composer == nil)
    }

    @Test func submittingSendsTheTextOfAnEditThatIsStillOpen() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(client: GitHubStub.client())
        await model.reloadThreads()
        model.startComment(file: file.id, from: lines[3], to: lines[3])
        model.composer?.text = "first wording 7f3a"
        model.addComposerToReview()
        model.open(.edit(draft: model.pending.comments[0].id))
        model.composer?.text = "second wording 7f3a"

        #expect(await model.submit(.comment))
        let sent = GitHubStub.bodies.withLock { $0.filter { $0.contains("wording 7f3a") } }
        #expect(sent.count == 1 && sent[0].contains("second wording 7f3a"))
        #expect(model.composer == nil)
        #expect(model.pending.comments.isEmpty)
    }

    @Test func aDragSelectsARangeAndAShiftClickExtendsIt() {
        let model = makeModel()
        model.beginDrag(file: file.id, line: lines[3])
        model.drag(over: [lines[4]])
        #expect(model.selection?.lines == [.addition(new: 4), .addition(new: 5)])
        model.endDrag(extendsSelection: false)
        guard case .thread(_, let under, let anchor) = model.composer?.target else {
            Issue.record("no composer")
            return
        }
        #expect(under == .addition(new: 5))
        #expect(anchor.start == DiffPosition(side: .right, line: 4))

        model.composer?.text = "kept"
        model.beginDrag(file: file.id, line: lines[6])
        model.endDrag(extendsSelection: true)
        #expect(model.composer?.text == "kept")
        #expect(model.selection?.lines.count == 4)
        #expect(model.discardRequest == nil)
    }

    /// In the split layout "-four" and "+FOUR" are one row, so both are at the same height.
    @Test(arguments: [2, 3]) func aClickOnASharedSplitRowCommentsOnTheClickedSide(index: Int) {
        let model = makeModel()
        model.beginDrag(file: file.id, line: lines[index])
        model.drag(over: [lines[2], lines[3]])
        model.endDrag(extendsSelection: false)
        #expect(model.composer?.target == .thread(
            file: file.id, under: lines[index].numbers, anchor: CommentAnchor(path: "docs/guide.md", end: lines[index].commentPosition)
        ))
    }

    @Test func aCommentBeingWrittenSurvivesItsLineLeavingTheDiff() {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.startComment(file: file.id, from: lines[3], to: lines[3])
        model.composer?.text = "half written"

        // The same diff again leaves the composer where it is.
        model.show(diff: diff, head: "def")
        #expect(model.composer?.text == "half written")

        model.show(diff: Diff(parsing: ""), head: "ghi")
        #expect(model.composer == nil)
        #expect(model.layout.outdatedDrafts.map(\.body) == ["half written"])
        #expect(model.layout.submittable.isEmpty)
    }

    @Test func aRangeAcrossHunksIsExplainedAndTextIsNotDiscardedSilently() {
        let model = makeModel()
        model.startComment(file: file.id, from: lines[0], to: file.hunks[1].lines[0])
        #expect(model.composer == nil)
        #expect(model.notice?.line == .context(old: 10, new: 11))

        model.startComment(file: file.id, from: lines[0], to: lines[0])
        model.composer?.text = "draft"
        model.open(.reply(threadID: "t1"))
        #expect(model.discardRequest == .open(.reply(threadID: "t1")))
        #expect(model.composer?.text == "draft")
        model.confirmDiscard()
        #expect(model.composer?.target == .reply(threadID: "t1"))
        model.cancelComposer()
        #expect(model.composer == nil)
    }

    @Test func anOutdatedDraftIsLeftOutUntilItIsMoved() {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.startComment(file: file.id, from: lines[3], to: lines[3])
        model.composer?.text = "note"
        model.addComposerToReview()
        // The head moves and the line leaves the diff.
        model.show(diff: Diff(parsing: ""), head: "def")
        #expect(model.layout.outdatedDrafts.count == 1)
        #expect(model.layout.submittable.isEmpty)
        #expect(!model.canSubmit(.comment))

        // While a draft is being moved, the next "+" click gives it that line.
        model.show(diff: diff, head: "ghi")
        model.reanchoring = model.pending.comments[0].id
        model.startComment(file: file.id, from: lines[0], to: lines[0])
        #expect(model.composer == nil)
        #expect(model.reanchoring == nil)
        #expect(model.pending.comments[0].anchor?.end == DiffPosition(side: .right, line: 2))
        #expect(model.layout.outdatedDrafts.isEmpty)
        #expect(model.layout.submittable.count == 1)
    }
}

@MainActor
struct GlyphTests {
    /// The hover layer assumes character indices are UTF-16 offsets that start at 0.
    @Test func glyphOffsetsFollowTheText() async throws {
        final class Box { var glyphs: [(rect: CGRect, offset: Int)] = [] }
        let box = Box()
        let view = Text(verbatim: "let total = price")
            .font(.system(size: 12, design: .monospaced))
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    Color.clear.onAppear {
                        if let anchored = layouts.first { box.glyphs = glyphFrames(in: anchored.layout, origin: proxy[anchored.origin]) }
                    }
                }
            }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        #expect(box.glyphs.map(\.offset) == Array(0..<17))
        // Monospaced: "price" starts 12 characters in.
        let width = try #require(box.glyphs.first).rect.width
        #expect(abs(box.glyphs[12].rect.minX - box.glyphs[0].rect.minX - 12 * width) < 0.5)
    }
}

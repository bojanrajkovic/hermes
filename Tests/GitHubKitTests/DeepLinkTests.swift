import Foundation
import Testing
@testable import GitHubKit

@Suite struct DeepLinkTests {
    private let repo = RepositoryRef(owner: "octo", name: "app")
    private let hash = String(repeating: "ab", count: 32)

    private func link(_ string: String) -> DeepLink? { DeepLink(url: URL(string: string)!) }

    @Test func hermesAndGitHubLinksReadTheSame() {
        #expect(link("hermes://octo/app") == .repository(repo))
        #expect(link("https://github.com/octo/app/") == .repository(repo))
        #expect(link("hermes://octo/app/pull/12") == .pullRequest(repo, number: 12, target: nil))
        #expect(link("https://github.com/octo/app/issues/5") == .issue(repo, number: 5, comment: nil))
        #expect(link("hermes://octo/app/stack/97") == .stack(repo, number: 97))
    }

    @Test func commentsOnIssuesAndPullRequests() {
        #expect(link("hermes://octo/app/issues/5#issuecomment-123") == .issue(repo, number: 5, comment: 123))
        #expect(link("hermes://octo/app/pull/12#issuecomment-123") == .pullRequest(repo, number: 12, target: .comment(123)))
        #expect(link("hermes://octo/app/pull/12#discussion_r456") == .pullRequest(repo, number: 12, target: .reviewComment(456)))
        #expect(link("hermes://octo/app/pull/12/files#r456") == .pullRequest(repo, number: 12, target: .reviewComment(456)))
    }

    @Test func filesAndLines() {
        #expect(link("hermes://octo/app/pull/12/files") == .pullRequest(repo, number: 12, target: .files))
        #expect(link("hermes://octo/app/pull/12/changes") == .pullRequest(repo, number: 12, target: .files))
        #expect(link("hermes://octo/app/pull/12/files#diff-\(hash)")
            == .pullRequest(repo, number: 12, target: .file(pathHash: hash, lines: nil)))
        #expect(link("hermes://octo/app/pull/12/files#diff-\(hash)R45")
            == .pullRequest(repo, number: 12, target: .file(pathHash: hash, lines: .init(side: .right, start: 45, end: 45))))
        #expect(link("hermes://octo/app/pull/12/changes#diff-\(hash)L3-L7")
            == .pullRequest(repo, number: 12, target: .file(pathHash: hash, lines: .init(side: .left, start: 3, end: 7))))
    }

    @Test func otherLinksAreNotDeepLinks() {
        #expect(link("hermes://octo") == nil)
        #expect(link("https://gitlab.com/octo/app") == nil)
        #expect(link("hermes://octo/app/pull/abc") == nil)
        #expect(link("hermes://octo/app/wiki") == nil)
        // An unknown fragment still opens the pull request.
        #expect(link("hermes://octo/app/pull/12#top") == .pullRequest(repo, number: 12, target: nil))
    }

    @Test func aPathHashIsTheSHA256OfThePath() {
        #expect(DeepLink.pathHash("a") == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
    }
}

import Foundation
import GitHubKit
import Testing

struct PullRequestSearchTests {
    @Test func openListsEveryOpenPullRequestNewestFirst() {
        #expect(PullRequestSearch.open(owner: "acme") == "is:pr is:open archived:false user:acme sort:created-desc")
    }

    @Test func involvingCoversYourPullRequestsAndYourReviewRequests() {
        #expect(PullRequestSearch.involvingViewer(owner: "acme") == [
            "is:pr is:open archived:false user:acme involves:@me",
            "is:pr is:open archived:false user:acme review-requested:@me",
        ])
    }

    @Test func updatedStartsAMinuteEarlyInUTC() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z

        #expect(PullRequestSearch.updated(owner: "acme", since: since, open: true)
            == "is:pr is:open archived:false user:acme updated:>=2027-01-15T07:59:00Z")
        #expect(PullRequestSearch.updated(owner: "acme", since: since, open: false)
            == "is:pr is:closed archived:false user:acme updated:>=2027-01-15T07:59:00Z")
    }

    @Test func attentionSearchesStayInTheAccount() {
        #expect(PullRequestSearch.directlyRequested(owner: "acme") == "is:pr is:open archived:false user:acme user-review-requested:@me")
        #expect(PullRequestSearch.reviewedByViewer(owner: "acme") == "is:pr is:open archived:false user:acme reviewed-by:@me")
        #expect(PullRequestSearch.mentioningViewer(owner: "acme") == "is:pr is:open archived:false user:acme mentions:@me")
    }
}

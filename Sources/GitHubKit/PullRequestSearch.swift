import Foundation

/// Search queries for an account's pull requests. Each runs through
/// `GitHubClient.pullRequestIDs(matching:)`, which stops at GitHub's limit of
/// 1,000 results.
public enum PullRequestSearch {
    /// Every open pull request in the account's non-archived repositories, newest first.
    public static func open(owner: String) -> String {
        "\(base(owner: owner, open: true)) sort:created-desc"
    }

    /// The open pull requests that involve the viewer, and those that ask for
    /// the viewer's review. They load before the rest of a large account.
    public static func involvingViewer(owner: String) -> [String] {
        ["involves:@me", "review-requested:@me"].map { "\(base(owner: owner, open: true)) \($0)" }
    }

    /// The open pull requests that ask for the viewer's review, by name or through a team.
    public static func reviewRequested(owner: String) -> String {
        involvingViewer(owner: owner)[1]
    }

    /// The open pull requests that ask for the viewer's review by name.
    public static func directlyRequested(owner: String) -> String {
        "\(base(owner: owner, open: true)) user-review-requested:@me"
    }

    /// The open pull requests the viewer has reviewed.
    public static func reviewedByViewer(owner: String) -> String {
        "\(base(owner: owner, open: true)) reviewed-by:@me"
    }

    /// The open pull requests that mention the viewer.
    public static func mentioningViewer(owner: String) -> String {
        "\(base(owner: owner, open: true)) mentions:@me"
    }

    /// The open or closed pull requests updated since a time. Starts a minute
    /// early, so a pull request updated while the last refresh ran is not missed.
    public static func updated(owner: String, since: Date, open: Bool) -> String {
        let from = since.addingTimeInterval(-60).formatted(.iso8601)
        return "\(base(owner: owner, open: open)) updated:>=\(from)"
    }

    private static func base(owner: String, open: Bool) -> String {
        "is:pr is:\(open ? "open" : "closed") archived:false user:\(owner)"
    }
}

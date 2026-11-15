# The attention inbox

"Needs Your Attention" is the first filter in the sidebar and the default
view. It lists the open pull requests in the current account that need
something from you, ranked by why, with the reason on each row.

## Reasons

A pull request can have several reasons. It is listed once, under its
strongest. Within a reason, the most recently updated comes first.

| Rank | Reason | When |
|------|--------|------|
| 1 | Review requested | GitHub asks you by name |
| 2 | Changes requested | Yours, and a review asks for changes |
| 3 | Checks failing, Conflicts, Needs rebase | Yours, and a required check fails, it conflicts with its base, or its base branch is the head of a pull request Hermes saw merge |
| 4 | Team review | GitHub asks a team you're on, and not you by name |
| 5 | New commits | Not yours, and its head moved past the commit of your latest review |
| 6 | Mentioned | Someone mentioned you |
| 7 | Ready to merge | Yours, approved, no required check failed and none is running, it can merge, and it is not a draft |
| 8 | Opened recently | Yours, opened in the last 24 hours |

A stack shows whole, as one node at the rank of its most urgent member.
Members that need you carry their reason; the others show without one. The bot filter
applies here as in the other lists.

## Signals

`attentionReason(for:viewer:signals:now:)` in `Sources/Hermes/Attention.swift`
decides, from the pull request and `AttentionSignals`. The pull request holds
most of what a reason needs, so a reason is as current as the pull request:

- `requestedReviewers`: the people and teams it asks. A request by name is
  "Review requested". A request to a team in `AttentionSignals.teams` is
  "Team review".
- `viewerReviewedCommit`: the commit of your latest submitted review, to
  compare with the head.

`AttentionSignals` holds the rest:

- `teams`: the teams you are on, from `GET /user/teams`. They reload with the
  repositories, every 10 minutes.
- `mentions`: from the search `mentions:@me`, run on every refresh. GitHub has
  no field for it on the pull request.
- `mergedBranches`: head branches of pull requests Hermes saw merge.

Three searches scoped to the account run on every refresh to find pull requests
Hermes does not hold yet: `review-requested:@me`, `reviewed-by:@me`, and
`mentions:@me`.

Every pull request these searches name loads, even from a repository you
cannot push to, which the org-wide lists leave out.

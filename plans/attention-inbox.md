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
| 3 | Checks failing, Conflicts, Needs rebase | Yours, and a check fails, it conflicts with its base, or its base branch is the head of a pull request Hermes saw merge |
| 4 | Team review | GitHub asks a team you're on, and not you by name |
| 5 | New commits | Not yours, and its head moved past the commit of your latest review |
| 6 | Mentioned | Someone mentioned you |
| 7 | Ready to merge | Yours, approved, its checks pass or it has none, it can merge, and it is not a draft |
| 8 | Opened recently | Yours, opened in the last 24 hours |

A stack shows as one node, at the rank of its most urgent member, with the
members that need you under it, each with its own reason. The bot filter
applies here as in the other lists.

## Signals

`attentionReason(for:viewer:signals:now:)` in `Sources/Hermes/Attention.swift`
decides, from the pull request and `AttentionSignals`. Most reasons come from
the pull request's own fields. The rest come from searches scoped to the
account, run on every refresh:

- `user-review-requested:@me`: requests by name.
- `review-requested:@me`: requests by name or team. Team requests are these
  minus the ones by name.
- `reviewed-by:@me`: pull requests you reviewed. For these, one more request
  loads the commit of your latest review, to compare with the head.
- `mentions:@me`: mentions.

Every pull request these searches name loads, even from a repository you
cannot push to, which the org-wide lists leave out.

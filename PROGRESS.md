# Progress

What is built and works, and what is known not to work or is unverified.
[PLAN.md](PLAN.md) lists the documents that explain each part.

## Built and working

**Accounts and lists**

- Sign-in through the GitHub CLI. A startup screen explains a missing or
  logged-out `gh` and shows the command that fixes it.
- An account picker for the personal account and the viewer's organizations.
  The choice is remembered.
- Open pull requests and repositories per account. Issues load per repository,
  30 at a time.
- The attention inbox, "Needs Your Attention": review requests, your pull requests that need action or can merge, new commits since your review, and mentions, ranked by reason. See [plans/attention-inbox.md](plans/attention-inbox.md).
- Webhook forwarders, off by default: with "Get changes as they happen" on in Settings, a change in one of your own repositories, or in an organization you own and picked, shows in about two seconds. See [plans/webhooks.md](plans/webhooks.md).
- Ignored repositories: a list in Settings, picked from the repositories Hermes has loaded. Their pull requests leave every list, the sidebar, and ⌘K. `HERMES_SHOW_IGNORED=1` switches the list off for one run.
- Inbox navigation: filters across repositories, then the repositories, with one list in the middle column.
- Local stacks: a repository with a checkout has a Local tab of its stacked
  branches, and a branch with no pull request opens a read-only diff against
  its parent. The stack switcher includes local branches above a pull request.
- Stacks: stacked pull requests are grouped in the lists, and the detail pane
  has a stack switcher.
- The bot filter: a bot's pull request shows only when a check fails or it
  has merge conflicts.
- Failed checks that merging does not require show as a yellow warning, not a
  red failure, and do not count as failing in the Failing filter or the
  attention inbox.
- The lists refresh every 15 seconds while Hermes is in front, on a timer in
  the background (30 seconds to 5 minutes, 1 minute by default), when the app
  becomes active, and on ⌘R. The first load shows the viewer's own pull
  requests before the rest of the account; later refreshes fetch what changed
  and load the pull requests on screen again by ID, so they do not wait for
  GitHub's search. Only repositories the viewer can push to load in full.
- First-run setup: a sheet confirms the signed-in account, asks where
  checkouts live, and offers webhook forwarders.
- The command palette: fuzzy search over repositories, pull requests, and
  issues, and `repo#123` references to items outside the lists.

**Pull request and issue panes**

- A pull request has four tabs: Conversation, Files, Checks, and Sessions.
- Conversation shows the description, comments, review summaries, commits,
  linked issues, and a checks summary, with Markdown rendered as on github.com.
- Merging from the Merge menu, with the methods the repository allows:
  merging now, merging past unmet requirements when GitHub allows a bypass, and
  turning auto-merge on or off, with a badge in the header while it is on.
- An issue pane shows the description, comments, assignees, labels, and the
  pull requests that close it.

**Diff viewer**

- Unified and side-by-side layouts, a file tree with a filter, sticky file
  headers, and collapsing files by marking them viewed.
- Syntax highlighting for 16 languages and intraline change emphasis.
- Context expansion around hunks.
- Rendered Markdown diffs with Mermaid.
- Go to definition for Swift, TypeScript, TSX, JavaScript, Go, Rust, C#,
  Python, Ruby, Bash, and HCL, in a popover over the identifier that can move
  into a docked pane.
- A file header's name opens the whole file in the docked pane at its first
  change.
- A pull request's diff reloads in place when the head commit changes, and
  keeps the scroll position.
- A diff that GitHub refuses to render is computed from a local bare clone.
- Local diffs: a session's worktree against its base, and one branch of a
  local stack against its parent.

- Failed or cancelled GitHub Actions jobs can be run again from the Checks
  tab: one job from its header or right-click menu, a workflow's failed jobs
  from the menu, or every failed job from the button under the list. Not yet
  tried against GitHub.

- `hermes://` links open repositories, issues, pull requests, stacks,
  comments, review threads, and file lines. They use GitHub's own paths.

- Several windows, each on its own account. New windows come from ⇧⌘N, Open
  Link in New Window… (⌥⌘O), ⌥↩ in ⌘K, row menus, and `?window=new` links.
  Windows come back after a relaunch when macOS keeps windows on quit.

**Reviews**

- Line and range comments from the gutter, replies to threads, and comments on
  blocks of a rendered Markdown file.
- A line with comments shows a badge. The line's threads, drafts, and composer
  open in a popover over it, so the diff has no rows of its own for comments.
- Drafts are saved on disk per pull request and survive quitting.
- Finishing a review sends every draft as one review. Submitting with the
  Comment verdict is verified against `bojanrajkovic/hermes-playground`.
- Outdated drafts are listed, and each can be moved to a new line or deleted.

**Checks**

- Checks grouped by workflow with a rollup, refreshed every 10 seconds while
  any check is queued or running.
- Steps for a running GitHub Actions job, and the log once it finishes.
- The log viewer: groups, ANSI colors, timestamps, search, and opening at the
  first error.
- Summaries for check runs that are not Actions jobs, and descriptions for
  legacy commit statuses.

**Sessions**

- Local Claude Code sessions in an embedded Ghostty terminal, started from a
  pull request or an issue, with or without Remote Control.
- A worktree per session branch under
  `~/Library/Application Support/Hermes/worktrees`. An existing worktree of
  the branch is reused.
- Cloning a repository that has no local checkout.
- The session screen: terminal beside a diff of the worktree that reloads as
  files change.
- Closing a session can remove its worktree, and asks before deleting
  uncommitted work.
- A session started from an issue links to the pull request opened from its
  branch.

**Relay**

- A Cloudflare Worker in `relay/` that registers tenants: an account's owner
  sends an invite code and their GitHub App's credentials, and the relay stores
  them in that tenant's Durable Object. An invite code registers one tenant,
  and the operator makes each one with `POST /invites`. It checks the signature of the App's
  webhook deliveries and deletes a tenant when its App is uninstalled. A user
  can sign in through the tenant's App in the browser and open a socket, which
  the relay closes after eight hours. It sends each delivery, unchanged, to the
  sockets of the users who can see its repository, and closes every socket
  when a delivery says someone's access changed. A user who can see no
  repository keeps their socket, unless GitHub says they are outside the
  organization Hermes names. A workflow attests the
  bundle and deploys it, and another checks hourly that the script Cloudflare
  runs is one the first attested. It runs at `hermes-relay.services.coderinserepeat.com`. See [plans/relay.md](plans/relay.md).

**Build and tests**

- `make relay-check` type-checks, lints, checks the formatting of, tests, and bundles the relay.
- `make build` produces a signed `build/Hermes.app`. `make test` runs the unit
  tests of every target.
- Tests that need the network, a real terminal, or a person to look at a PNG
  run only when their environment variable is set. See
  [plans/build-system.md](plans/build-system.md).
- `renovate.json` sets which dependency updates Renovate opens and which it
  merges. See [plans/build-system.md](plans/build-system.md#dependency-updates).

## Known limits

**Does not work**

- **Fork pull requests cannot run in a local session.** The worktree is made
  from the pull request's head branch on the checkout's remote. A fork's
  branch is not there, so the launch sheet reports that the branch is not on
  the remote.
- **Sessions do not survive quitting.** The session list lives in memory and
  the terminals end with the app. Worktrees and branches stay on disk.
- **Go to definition is pointer-only.** A click on an identifier opens the
  lookup. There is no keyboard command for it.

**Unverified**

- **The relay's membership question.** The relay asks GitHub
  `GET /user/memberships/orgs/{org}` with a tenant App's user token. Its tests
  stand in for GitHub. No real App's token has been used on that endpoint, for
  the App's own organization or for another.

- **Renovate.** `renovate.json` passes Renovate's validator, and a local run
  finds the dependencies in the workflows, `Package.swift`, and
  `.xcode-version`. Renovate has not run on this repository.

- **Cloud sessions.** `claude --environment <id>` is built from the output of
  `claude --help`. No cloud session has been run from Hermes.
- **Approve and Request Changes.** Every pull request in the playground
  repository is the viewer's own, and GitHub rejects both verdicts on one's
  own pull request. Hermes disables them there, so neither has been sent.
- **The release pipeline.** `make dist` needs a Developer ID (`TEAM_ID`) and a
  stored notary profile. The Makefile sets neither.

**Missing**

- Hermes reads, reviews, and merges. It cannot close, resolve threads, edit or
  delete posted comments, or comment on the conversation.
- Viewed marks are kept in memory and are not sent to GitHub.
- Only github.com is supported, not GitHub Enterprise Server.
- Lists are capped at what one query returns: 1,000 open pull requests per
  account, 100 review requests, and per pull request 100 comments, 100
  reviews, 100 review threads, and 250 commits.
- A definition lookup reads at most 40 files that contain the name.

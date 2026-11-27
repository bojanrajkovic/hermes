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
- One store of GitHub state for the app (`GitHubStore`). The sidebar's issue
  count and the repository's Issues list read the same field, which the
  repository load and every issue page update. See [plans/store.md](plans/store.md).
- Pull request lists and repositories show at launch from a cache of the store in
  `~/Library/Caches/Hermes/store.json`, saved every 2 minutes and on quit. Issue lists aren't
  cached. The first refresh loads only what changed since, and every fetch replaces what the
  cache restored. An account that loaded over a day ago starts empty, another `gh` user's
  cache is dropped at sign-in, and a cache this build can't read is deleted. See [plans/store.md](plans/store.md#cache-between-launches).
- The attention inbox, "Needs Your Attention": review requests, your pull requests that need action or can merge, new commits since your review, and mentions, ranked by reason. See [plans/attention-inbox.md](plans/attention-inbox.md).
- Webhook forwarders, off by default: with "Get changes as they happen" on in Settings, a change in one of your own repositories, or in an organization you own and picked, shows in about two seconds. See [plans/webhooks.md](plans/webhooks.md).
- Relay setup: "Set Up a Relay…" in Settings and in first-run setup takes an account the user owns, a relay server, and an invite code. It checks that the relay answers, opens GitHub to create the account's App, hands the App's secrets to the relay, and then offers the App's install page and the join link for members. Several accounts can each have a tenant. See [plans/relay-client.md](plans/relay-client.md).
- Relay tenants: opening a `hermes://relay.join` link joins a tenant and signs in through the browser. Hermes tells the relay which organization a tenant belongs to, when it knows, so the relay can tell a member with no repository yet from someone outside it. Each tenant keeps a connection to its relay, and a change in a repository the tenant covers reloads its pull request, and the review threads or checks on screen, at once. Those repositories get no webhook forwarder. Settings shows each tenant's connection, when it last sent an event, and its relay's commit. Connections are logged at notice level, so `log show` keeps them, and each event at info level. See [plans/relay-client.md](plans/relay-client.md#checking-a-tenant).
- Applied payloads: a forwarder's or a relay's delivery about a pull request's title, labels, draft state, state, reviewers, or auto-merge changes its row at once with no request. New commits change the row at once and then load the rest. An edited description, a review request, a conversation comment, and a review show in the open pull request at once. So do a reply in a review thread, a thread being resolved or reopened, a commit status, and a check run. A delivery that arrives late does not undo a newer one, and a load that was running when a delivery was applied runs once more. Deliveries write to the store whether or not a screen is up, so a tab opened later shows them. A delivery about a plain issue reloads that issue and its repository's issue list, not the whole account. See [plans/webhooks.md](plans/webhooks.md).
- Relay discovery: an owner can publish a tenant as `hermes-relay.json` in the account's `.github-private` repository, after confirming. Publish is on the tenant's row in Settings, also for a tenant the owner joined by a link. Hermes looks there once a launch for each of the viewer's accounts and offers a tenant it finds, so members need no join link. A tenant turned down is not asked about again, and Settings lists it with a Connect button.
- Ignored repositories: a list in Settings, picked from the repositories Hermes has loaded. Their pull requests leave every list, the sidebar, and ⌘K. `HERMES_SHOW_IGNORED=1` switches the list off for one run.
- Inbox navigation: filters across repositories, then the repositories, with one list in the middle column.
- Back and forward: ⌘[ and ⌘] and the list column's chevron buttons return to the window's
  earlier sidebar scope, list, item, and tab. Each window has its own history. Switching accounts
  clears it. See [plans/architecture.md](plans/architecture.md#back-and-forward).
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
  checkouts live, and offers webhook forwarders and relay setup.
- The command palette: fuzzy search over repositories, pull requests, and
  issues, and `repo#123` references to items outside the lists.

**Pull request and issue panes**

- A pull request has four tabs: Conversation, Files, Checks, and Sessions.
- Conversation shows the description, comments, review summaries, commits,
  linked issues, and a checks summary, with Markdown rendered as on github.com.
- A comment box at the end of a pull request's or an issue's conversation
  sends a comment outside any review. Unsent text is saved beside the item's
  review drafts, so it survives switching items and quitting.
- Merging from the Merge menu, with the methods the repository allows:
  merging now, merging past unmet requirements when GitHub allows a bypass, and
  turning auto-merge on or off, with a badge in the header while it is on.
  While the pull request, or any pull request below it in its stack, is a
  draft, a Ready for Review button replaces the Merge menu. The button marks
  each of those drafts ready for review.
- An issue pane shows the description, comments, assignees, labels, and the
  pull requests that close it.

**Diff viewer**

- Unified and side-by-side layouts, a file tree with a filter, sticky file
  headers, and collapsing files by marking them viewed. A pull request's viewed
  marks sync with GitHub both ways.
- Syntax highlighting for 16 languages and intraline change emphasis.
- Context expansion around hunks.
- Find in the diff (⌘F). It searches the visible lines of every file,
  including collapsed files, and opens a collapsed file to show a match. It
  skips unexpanded context, files shown as rendered Markdown, and large files
  that show a notice instead of the diff.
- Rendered Markdown diffs with Mermaid.
- Go to definition for Swift, TypeScript, TSX, JavaScript, Go, Rust, C#,
  Python, Ruby, Bash, and HCL, in a popover over the identifier that can move
  into a docked pane.
- Find references with ⌘-click or the line's right-click menu, in the same
  popover. In those 11 languages, the list leaves out a comment or string
  that only mentions the name.
- A file header's name opens the whole file in the docked pane at its first
  change.
- A pull request's diff reloads in place when the head commit changes, and
  keeps the scroll position.
- A diff that GitHub refuses to render is computed from a local bare clone.
- Local diffs: a session's worktree against its base, and one branch of a
  local stack against its parent.

- Failed or cancelled GitHub Actions jobs can be run again from the Checks
  tab: one job from its header or right-click menu, a workflow's failed jobs
  from the menu, or every failed job from the button under the list.

- `hermes://` links open repositories, issues, pull requests, stacks,
  comments, review threads, and file lines. They use GitHub's own paths.

- Several windows, each on its own account. New windows come from ⇧⌘N, Open
  Link in New Window… (⌥⌘O), ⌥↩ in ⌘K, row menus, and `?window=new` links.
  Windows come back after a relaunch when macOS keeps windows on quit, with
  their pull request tab and open list groups.

**Reviews**

- Line and range comments from the gutter, replies to threads, and comments on
  blocks of a rendered Markdown file.
- A line with comments shows a badge. The line's threads, drafts, and composer
  open in a popover over it, so the diff has no rows of its own for comments.
- Drafts are saved on disk per pull request and survive quitting.
- Finishing a review sends every draft as one review.
- Outdated drafts are listed, and each can be moved to a new line or deleted.

**Checks**

- Checks grouped by workflow with a rollup, refreshed every 10 seconds while
  any check is queued or running, or a workflow run waits for approval.
- Steps for a running GitHub Actions job, and the log once it finishes.
- The log viewer: groups, ANSI colors, timestamps, search, and opening at the
  first error.
- Summaries for check runs that are not Actions jobs, and descriptions for
  legacy commit statuses.
- Workflow runs from a fork that wait for a maintainer show above the checks,
  in the Checks tab and the overview, with an Approve button.

**Sessions**

- Local Claude Code sessions in an embedded Ghostty terminal, started from a
  pull request or an issue, with or without Remote Control.
- Cloud sessions on a cloud environment saved in Settings. They run in the
  embedded terminal, without a local worktree.
- A worktree per session branch under
  `~/Library/Application Support/Hermes/worktrees`. An existing worktree of
  the branch is reused.
- A session for a pull request from a fork reviews it on a local `pr-<number>`
  branch fetched from `refs/pull/<number>/head`. It can't push to the fork.
- Cloning a repository that has no local checkout.
- The session screen: terminal beside a diff of the worktree that reloads as
  files change, under one header with the session's origin, environment,
  branch, and buttons.
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
- Publishing a GitHub release runs `release.yml`, which signs, notarizes, and
  attests the app and attaches the zip. See
  [plans/build-system.md](plans/build-system.md#release).

## Known limits

**Does not work**

- **Sessions do not survive quitting.** The session list lives in memory and
  the terminals end with the app. Worktrees and branches stay on disk.
- **Go to definition and find references are pointer-only.** A click,
  ⌘-click, or right-click on an identifier starts the lookup. There is no
  keyboard command for either.

**Unverified**

- **The relay's membership question.** The relay asks GitHub
  `GET /user/memberships/orgs/{org}` only when an organization's App reaches
  none of the user's repositories. Its tests stand in for GitHub. Every real
  sign-in so far reached repositories, so no real token has made that call.
- **Approving a fork's workflow run.** Hermes reads waiting runs correctly from
  a public repository. Nobody has approved one from Hermes, which needs a pull
  request from a first-time contributor's fork.
- **Access changes on a personal account's tenant.** The relay checks access
  again when a delivery says someone's access changed. Nobody knows which of
  those events GitHub sends to a personal account's App, such as `member` when
  a collaborator is added. See [plans/relay-client.md](plans/relay-client.md).
- **The release workflow.** `release.yml` passes zizmor's auditor checks, but
  it hasn't run yet. The next published release is its first run. Installing
  with mise was tested against the v0.5.0 zip, not one the workflow built.

**Missing**

- Hermes reads, reviews, and merges pull requests, and marks drafts ready for
  review. It can't close pull requests, resolve threads, or edit or delete
  posted comments.
- Only github.com is supported, not GitHub Enterprise Server.
- GitHub's search returns at most 1,000 results, so Hermes lists at most
  1,000 open pull requests and 1,000 review requests per account. A pull
  request shows at most 250 commits, 50 requested reviewers, and 100 comments
  in each review thread. An issue shows its first 100 comments.
- A definition lookup reads at most 40 files that contain the name. A
  references search reads at most 100 files and 500 matching lines.
- Find references searches the head commit, so it doesn't list a use that the
  pull request deletes.

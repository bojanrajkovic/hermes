# Webhook forwarders

Hermes refreshes its lists on a timer. A webhook forwarder makes a change show
in about two seconds instead: GitHub pushes the repository's webhook deliveries
down a WebSocket, and Hermes applies each delivery's payload or reloads what
it names.

The forwarder is `gh webhook forward`, from the `cli/gh-webhook` extension of
the GitHub CLI. Only GitHub sees a forwarder's deliveries: no server sits
between it and Hermes.

A forwarder needs admin rights on its repository. For repositories where the
user has none, an account's owner can set up a [relay](relay-client.md)
tenant. A repository that a connected tenant covers gets no forwarder.

```mermaid
sequenceDiagram
    participant GH as GitHub
    participant F as gh-webhook (child process)
    participant H as Hermes
    H->>F: start for owner/name
    F->>GH: create webhook "cli", open WebSocket
    GH-->>F: delivery (JSON)
    F-->>H: one line on stdout
    H->>H: apply the payload's fields
    H->>GH: load what the payload does not carry
    Note over H,GH: The timer refresh keeps running.
```

## What it is for

Hermes reads the repository and the pull request number from a delivery. A
commit status names no pull request, and a check often names none, so Hermes
finds theirs by the commit: the held pull request whose head it is. Held means
in the open list, or loaded by number.

A delivery about a held pull request is applied or loads that pull request.
[Applying a payload](#applying-a-payload) says which.

A delivery about anything else loads the account. That covers a newly opened
pull request, and a commit that is no held pull request's head, which a push
makes true until its pull request loads again. A busy repository sends many of
those, so they share loads the way a burst about one pull request does.

The timer refresh never stops, so a forwarder that ends costs nothing but the
delay.

`AppStore.reload` does this for a relay's events too. A burst of deliveries
about one pull request loads it on the first and once more after, not once
per delivery. [relay-client.md](relay-client.md) has the rule.

## Applying a payload

A delivery's payload carries much of what changed. `WebhookChange` in
`Sources/GitHubKit/WebhookChange.swift` reads it, and Hermes puts those fields
into what it holds at once. It asks GitHub only for what the payload does not
carry.

| Delivery | Applied from the payload | Loaded from GitHub |
|---|---|---|
| `pull_request`: edited, labeled, unlabeled, converted to draft, ready for review, closed, review requested or removed, auto-merge on or off | Title, labels, draft, state, branches, head commit, line and file counts, auto-merge method, requested reviewers | Nothing |
| `pull_request`: new commits, reopened, a new base branch, any other action | The same fields | The pull request: its review decision, mergeability, checks, and stack |
| Anything else | Nothing | The pull request |

The pull request's update time is not applied. The description and the
conversation load when it changes, which is at the next refresh.

A payload Hermes can't read has no change, and its delivery loads the pull
request as before. A load that is running when a payload is applied runs once
more, because it may have asked GitHub before the change.

The payload types are small `Decodable` structs that hold only the fields
Hermes reads. Types generated from GitHub's REST schema refuse real deliveries:
a review's `body` is `null` in a delivery and a string in the schema.

## Which repositories

`Forwarders.targets(watched:viewer:organizations:waiting:)` in
`Sources/Hermes/Forwarders.swift` decides, every 15 seconds. A watched pull
request is the open one, one with a session, one in the attention inbox, or one
in the list on screen.

- **Organizations the signed-in user owns and picked in Settings**, when one
  has a watched pull request and the `gh` token has the `admin:org_hook` scope.
  None is picked at first: the webhook is one every owner of the organization
  sees. One forwarder
  covers every repository of the organization.
- **Repositories the signed-in user owns** that have a watched pull request, at
  most 20. Each forwarder is a process and a webhook.
- **None that a relay covers.** A connected relay tenant lists the repositories
  it sends events for. Those are left out before the two rules above, so an
  organization whose watched repositories are all covered gets no forwarder.
- **Nothing else.** A repository of an organization gets no forwarder of its
  own. The webhook is named `cli` and says nothing of who made it, which the
  other admins of a shared repository would have to puzzle over. An
  organization's forwarder is one webhook that its owner chose.
- Not the ones waiting to retry. A forwarder that ends on its own may start
  again after 30 seconds. The wait doubles each time it ends again, up to 30
  minutes, and starts over once a forwarder has run for 5 minutes. GitHub
  refuses a forwarder within seconds when the user is not an admin of the
  repository or it already has one (GitHub allows one per repository), so such
  a repository is tried twice an hour and otherwise stays on the timer.

## The setting

Settings has "Get changes as they happen", off by default, because turning it
on writes a webhook to repositories. The last page of first-run setup offers
the same switch. When the extension is missing, both offer to install it with
`gh extension install cli/gh-webhook`.

## Organizations

`gh auth login` does not ask for `admin:org_hook`, and `admin:org` does not
include it. To add it:

```bash
gh auth refresh -h github.com -s admin:org_hook
```

Hermes reads the token's scopes from the `X-OAuth-Scopes` header of
`HEAD /user` when the setting is turned on and each time Hermes comes to the
front, with the token `gh` holds at that moment. `viewerCanAdminister` on the
organization says whether the user owns it. Settings lists each owned
organization with a switch, and shows the command with a Copy button when one
is picked and the scope is missing.

## Logs

`Forwarders` logs under the `com.coderinserepeat.hermes` subsystem, category
`webhooks`: each start, and each end with how long the forwarder ran, what the
extension reported, and when the repository is tried again.

```bash
/usr/bin/log stream --predicate 'subsystem == "com.coderinserepeat.hermes" AND category == "webhooks"'
```

## The process

`WebhookForwarder` in `Sources/GitHubKit/WebhookForwarder.swift` runs one.

- It runs the extension's program directly, not `gh webhook forward`. `gh`
  starts the program as a child, and a signal sent to `gh` leaves the child and
  its webhook running.
- It passes the token in `GH_TOKEN`. The program cannot read a token that `gh`
  keeps in the keychain.
- It asks for the events that change a row or a pane: `pull_request`,
  `pull_request_review`, `pull_request_review_comment`, `issue_comment`,
  `check_suite`, and `status`.
- Each delivery is one line of JSON on stdout. The event's type is not in it,
  so `WebhookEvent` reads the keys that name a pull request: `pull_request`,
  `issue` with a `pull_request` key, and the `pull_requests` of a `check_suite`
  or a `check_run`. It reads the commit from a status's `sha` and a check's
  `head_sha`.
- A forwarder's target is a repository (`--repo`) or an organization (`--org`).
- GitHub deletes the webhook when the process ends, however it ends.
- GitHub allows one forwarder per target. An organization's forwarder and a
  forwarder of one of its repositories can run at once.
- Hermes stops its forwarders when it quits. A crash leaves them running,
  holding their targets' webhooks. Each is started with the webhook secret
  `hermes-forwarder`, and the next launch ends every process that has it.

## Testing

`HERMES_LIVE_WEBHOOKS=1 swift test --filter WebhookForwarderTests` forwards
`bojanrajkovic/hermes-playground`, comments on its pull request 53, expects the
event, and deletes the comment.

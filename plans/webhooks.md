# Webhook forwarders

Hermes refreshes its lists on a timer. A webhook forwarder makes a change show
in about two seconds instead: GitHub pushes the repository's webhook deliveries
down a WebSocket, and Hermes reloads what a delivery names.

The forwarder is `gh webhook forward`, from the `cli/gh-webhook` extension of
the GitHub CLI. Only GitHub sees the deliveries. There is no Hermes server.

```mermaid
sequenceDiagram
    participant GH as GitHub
    participant F as gh-webhook (child process)
    participant H as Hermes
    H->>F: start for owner/name
    F->>GH: create webhook "cli", open WebSocket
    GH-->>F: delivery (JSON)
    F-->>H: one line on stdout
    H->>GH: load that pull request by number
    Note over H,GH: The timer refresh keeps running.
```

## What it is for

A delivery is only a signal. Hermes reads the repository and the pull request
number from it and loads the pull request the usual way. A delivery that names
no pull request Hermes holds, such as a commit status or a newly opened pull
request, refreshes the account. The timer refresh never stops, so a forwarder
that ends costs nothing but the delay.

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
  `issue` with a `pull_request` key, and `check_suite.pull_requests`.
- A forwarder's target is a repository (`--repo`) or an organization (`--org`).
- GitHub deletes the webhook when the process ends, however it ends.
- Hermes stops its forwarders when it quits. A crash leaves them running,
  holding their targets' webhooks. Each is started with the webhook secret
  `hermes-forwarder`, and the next launch ends every process that has it.

## Testing

`HERMES_LIVE_WEBHOOKS=1 swift test --filter WebhookForwarderTests` forwards
`bojanrajkovic/hermes-playground`, comments on its pull request 53, expects the
event, and deletes the comment.

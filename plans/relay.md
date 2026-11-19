# The relay

The relay is a Cloudflare Worker in [`relay/`](../relay).

```mermaid
graph LR
    G[GitHub] -->|"POST /hook/#lt;tenant#gt;"| W[Relay Worker]
    W --> T1["Durable Object<br/>tenant A"]
    W --> T2["Durable Object<br/>tenant B"]
    T1 -->|WebSocket| M1["A member's Hermes"]
    T1 -->|WebSocket| M2["Another member's Hermes"]
    T2 -->|WebSocket| M3["A member's Hermes"]
```

The Worker takes each request and hands it to the Durable Object of the tenant
the address names. That object checks the delivery and sends it down the open
sockets of the members who can see its repository.

## Tenants

A tenant is a GitHub account whose owner registered a GitHub App of their own
with the relay. The owner's client picks the tenant's ID: 32 lowercase hex
characters.

Each tenant is one Durable Object, named by the tenant's ID. The relay keeps no
list of tenants. A tenant's Durable Object stores two things:

- Its registration: the invite code it used up and the App's ID, client ID,
  client secret, and webhook secret.
- For each open socket, the IDs of the repositories that socket's user can see.
  They are deleted when the socket closes. Each connect and each alarm also
  deletes the IDs of any session that has no open socket, because a socket that
  ends when the Durable Object shuts down may never report its close.

A person in several organizations uses one tenant per organization, each with
its own sign-in and its own socket.

## Requests

| Request | Response |
|---|---|
| `GET /version` | `200 {"commit": "<sha>"}`: the commit the running Worker was built from. A local run reports `dev`. |
| `POST /invites` | Makes an invite code, for the operator. See [Invite codes](#invite-codes). |
| `PUT /tenants/<tenant>` | Registers a tenant. See below. |
| `POST /hook/<tenant>` | Takes a webhook delivery from GitHub. See below. |
| `GET /t/<tenant>/login?state=<s>&code_challenge=<c>` | Redirects the browser to GitHub's sign-in page for the tenant's App. |
| `GET /t/<tenant>/callback` | Where GitHub sends the browser after sign-in. Redirects to a `hermes://relay.session` link. |
| `POST /t/<tenant>/session` | Trades a sign-in grant for the user's refresh token. See below. |
| `GET /t/<tenant>/connect` | Opens a WebSocket for a signed-in user. See below. |

A path with a malformed tenant ID answers `404`. A request the relay fails to
handle, such as one that needs GitHub while GitHub is down, answers `500` with
no body. The relay prints nothing about it.

### Registering a tenant

The body is JSON:

```json
{
  "invite": "an invite code",
  "appID": 123456,
  "clientID": "Iv1.0123456789abcdef",
  "clientSecret": "…",
  "webhookSecret": "…"
}
```

| Status | Meaning |
|---|---|
| `201` | The registration is stored. |
| `400` | The body is not a registration. |
| `403` | The relay never issued the invite code, or it has been used. Nothing is stored. |
| `409` | The tenant is registered with different values. |

A tenant registers once, so someone who learns a tenant's ID can't replace its
credentials. Sending the stored registration again answers `201`, so a client
whose first request succeeded but whose connection dropped can retry.

A tenant's first registration uses its invite code up. A `400` or a `409`
leaves the code unused.

### Webhook deliveries

A tenant's GitHub App sends its webhooks to `POST /hook/<tenant>`. The relay
checks the `X-Hub-Signature-256` header against the tenant's webhook secret,
using [`@octokit/webhooks-methods`](https://github.com/octokit/webhooks-methods.js).

| Status | Meaning |
|---|---|
| `202` | The delivery is genuine. |
| `401` | The signature is missing or wrong. |
| `404` | No tenant with this ID is registered. |

The relay reads three things from a genuine delivery: the `X-GitHub-Event`
header, the payload's `action`, and `repository.id`. `classifyDelivery` in
`delivery.ts` turns them into one of four actions:

| Delivery | Action |
|---|---|
| `installation` with action `deleted` (the App was uninstalled) | Close every socket with code `4004` and delete everything the tenant stored. Its ID is unknown afterwards. |
| `installation_repositories`, `member`, `membership`, `organization`, `repository`, `team`, `team_add` | Someone's access may have changed. Close every socket with code `4001`, so each client reconnects and is checked again. |
| Any other event that names a repository | Send it to the sockets whose user can see that repository. |
| Anything else | Ignored. |

A forwarded delivery is one text message:

```json
{
  "type": "event",
  "event": "pull_request",
  "delivery": "<the X-GitHub-Delivery header>",
  "payload": { "…": "GitHub's payload" }
}
```

The payload is the request body, byte for byte. The relay does not re-encode
it and knows nothing of its shape beyond `action` and `repository.id`.

The relay stores nothing from a delivery. A delivery that arrives while a
user's socket is closed never reaches that user.

### Signing in

A user signs in through the tenant's own GitHub App, so the token GitHub issues
can read only what both the App and the user can.

```mermaid
sequenceDiagram
    participant H as Hermes
    participant B as Browser
    participant R as Relay
    participant GH as GitHub
    Note over H: Make a verifier. Its SHA-256 is the challenge.
    H->>B: open /t/#lt;tenant#gt;/login?state=s&code_challenge=c
    B->>R: GET /t/#lt;tenant#gt;/login?state=s&code_challenge=c
    R-->>B: 302 to GitHub's authorize page, with the challenge
    B->>GH: sign in and authorize the App
    GH-->>B: 302 /t/#lt;tenant#gt;/callback?code=g&state=s
    B->>R: GET /t/#lt;tenant#gt;/callback?code=g&state=s
    R-->>B: 302 hermes://relay.session?tenant=…&grant=g&state=s
    B->>H: open the link
    H->>R: POST /t/#lt;tenant#gt;/session with the grant and the verifier
    R->>GH: exchange the code, with the client secret and the verifier
    GH-->>R: access token, refresh token
    R-->>H: {"refreshToken": "…"}
```

The grant is GitHub's own code, passed through unchanged, so the relay holds
nothing between the browser's sign-in and the client's request. GitHub accepts
a code once, for ten minutes. The relay returns the refresh token and discards
the access token.

The sign-in uses PKCE. Hermes makes a random verifier and sends only its
SHA-256, the challenge, with the sign-in. GitHub issues a token for the code
only to a request that also carries the verifier. The code passes through the
relay's address, where Cloudflare can show it to the relay's operator. The
verifier travels only in the body of the session request, which Cloudflare
does not show, so the code alone is worth nothing.

`GET /t/<tenant>/login` answers `400` without a `code_challenge` of 43
base64url characters.

`POST /t/<tenant>/session` takes `{"grant": "<code>", "verifier": "<verifier>"}`:

| Status | Meaning |
|---|---|
| `200` | `{"refreshToken": "<token>"}` |
| `400` | The body has no grant, or no verifier of 43 to 128 characters. |
| `403` | GitHub refused the code or the verifier, or the App's user tokens don't expire. |
| `404` | No tenant with this ID is registered. |
| `500` | GitHub could not be reached. The code may still be good. |

The App must have "Expire user authorization tokens" on, which is GitHub's
default. With it off GitHub issues no refresh token. Octokit's
`exchangeWebFlowCode` takes no verifier, so the exchange is one call with
[`@octokit/request`](https://github.com/octokit/request.js).

### Connecting

The client opens a WebSocket at `GET /t/<tenant>/connect`. The request carries
no token.

| Status | Meaning |
|---|---|
| `101` | The socket is open. |
| `404` | No tenant with this ID is registered. |
| `426` | The request is not a WebSocket upgrade. |

The client's first message says who it is:

```json
{ "type": "hello", "refreshToken": "<the refresh token>" }
```

The token is in a message and not a header because Cloudflare can show a
Worker's operator each request's headers, and never what a socket carries.

```mermaid
stateDiagram-v2
    [*] --> awaitingHello: socket opens
    awaitingHello --> authorizing: hello
    awaitingHello --> [*]: 60 seconds pass, or the message is not a hello (4003)
    authorizing --> open: GitHub answers, session sent
    authorizing --> [*]: GitHub refuses the token (4003)
    authorizing --> [*]: GitHub can't be reached (1011)
    open --> [*]: 8 hours pass, or access changed (4001)
    open --> [*]: tenant gone (4004)
```

When the hello arrives, the relay:

1. Uses the refresh token. GitHub answers with an access token and a new
   refresh token, and the old one stops working.
2. Lists the repositories the user can see through the tenant's App, with
   `GET /user/installations` and
   `GET /user/installations/{id}/repositories`. It reads at most 4,000.
3. Stores those repositories' IDs under the socket's session ID and discards
   the access token.

Then it sends the session:

```json
{
  "type": "session",
  "refreshToken": "<the new refresh token>",
  "expiresAt": 1794000000,
  "repositories": ["acme/site", "acme/api"]
}
```

The relay reads one message from a socket. Anything the client sends after
its hello is ignored.

A delivery can arrive while the relay is waiting on GitHub in steps 1 and 2.
The relay leaves that socket open, because its refresh token is already spent
and the client needs the new one:

- If the delivery deleted the tenant, the socket closes with code `4004` and
  gets no session.
- If it closed every open socket because someone's access changed, the list
  just read may be out of date. The relay sends the session so the client gets
  its new refresh token, stores no repository IDs, and closes the socket with
  code `4001`.

The client must store the new refresh token at once. If the connection drops
before the session arrives, the client holds a spent token, and the user has
to sign in again.

A socket stays open for eight hours. Then the relay closes it with code `4001`,
and the client reconnects, so the user's access is checked again. An alarm on
the Durable Object fires when the oldest socket runs out.

| Close code | Meaning |
|---|---|
| `1011` | GitHub could not be reached. The refresh token was not used, so the client keeps it and tries again. |
| `4001` | Reconnect now. The eight hours ran out, or a delivery said someone's access changed. |
| `4003` | Sign in again. GitHub refused the refresh token, the first message was not a hello, or none came within 60 seconds. |
| `4004` | Stop. The App was uninstalled. |

The sockets use the WebSocket Hibernation API, so an idle tenant is not kept in
memory. That is why each socket's state and the repository IDs are in storage
and not in fields.

## Invite codes

An invite code registers one tenant. The operator makes a code and gives it to
the account's owner:

```bash
curl --fail -X POST -H "Authorization: Bearer $OPERATOR_TOKEN" \
  https://<the relay's address>/invites
```

| Status | Meaning |
|---|---|
| `201` | `{"invite": "<code>"}`: a new code of 32 hex characters. |
| `401` | The `Authorization` header is not `Bearer` and the operator token. |

```mermaid
sequenceDiagram
    participant O as Operator
    participant W as Relay Worker
    participant I as Invites object
    participant T as Tenant's object
    participant H as Owner's Hermes
    O->>W: POST /invites, with the operator token
    W->>I: issue
    Note over I: Stores the new code
    W-->>O: the code
    O-->>H: the code, by hand
    H->>W: PUT /tenants/#lt;tenant#gt;, with the code
    W->>T: register
    T->>I: redeem the code
    Note over I: Deletes the code
    Note over T: Stores the registration
```

The codes live in one more Durable Object, `Invites`, named `invites`. It
stores each code from the moment it is issued until a tenant registers with
it, and nothing else: not who a code was for, and not which tenant used it.
Using a code deletes it, so a second registration with the same code answers
`403`, and so does one sent after the tenant's App is uninstalled. A code
never runs out on its own, and the relay has no call that cancels one.

Once a tenant is registered, the relay never looks at its code again. The
relay has no call that stops a registered tenant.

`OPERATOR_TOKEN` is a Worker secret. While it is empty, `POST /invites`
answers `401` to everything. To make one:

```bash
openssl rand -hex 32
```

## Layout

```
relay/
├── src/                  everything the Worker runs, and nothing else
│   ├── index.ts          the Worker's entry: exports the routes and the Tenant class
│   ├── http/
│   │   └── app.ts        the routes: parse the request, call the tenant, map the result
│   ├── tenant.ts         the Tenant Durable Object
│   ├── registration.ts   decides whether a registration is accepted
│   ├── delivery.ts       decides what to do with a webhook delivery
│   ├── session.ts        a socket's states, how long each lasts, and the hello message
│   ├── json.ts           parses JSON text without throwing
│   └── github.ts         the calls to GitHub
├── tests/                Vitest tests, run inside the Workers runtime
│   └── lint/             the lint fixture test and its fixture, run by Node
├── wrangler.jsonc        the Worker's name, bindings, and settings
├── vitest.config.ts
├── oxlint.config.ts      the relay's own lint rules, each with a comment saying why
├── oxlint.presets.ts     the rules of ESLint's and typescript-eslint's presets
├── .oxfmtrc.json         the formatter's settings
├── tsconfig.json         the compiler settings, on top of @tsconfig/strictest
├── package.json
├── pnpm-lock.yaml
└── pnpm-workspace.yaml   pnpm's settings: which package versions it refuses, and which build scripts run
```

The repository's `mise.toml` pins the Node and pnpm versions.
[build-system.md](build-system.md#tool-versions) describes it.

The code runs in two places, so it type-checks as four projects. Each has
only the types of the place it runs, so Worker code that reaches for a Node
API fails to compile.

| Project | Covers | Types |
|---|---|---|
| `tsconfig.json` | The config files beside it, which Node runs | Node |
| `src/tsconfig.json` | The Worker | The Workers runtime, from `wrangler types` |
| `tests/tsconfig.json` | The tests | The Workers runtime and the Vitest plugin |
| `tests/lint/tsconfig.json` | The lint fixture test, which Node runs | Node |

## Packages

[pnpm](https://pnpm.io) installs the relay's packages. `package.json` names
exact versions, and `pnpm add` writes them that way. `pnpm-workspace.yaml`
makes an install fail when:

- A version is less than a day old. Most malicious releases are pulled within
  that day.
- A version was published with weaker trust evidence, such as provenance, than
  an earlier version of the same package. That is the usual sign of a stolen
  publish token.
- A package has a build script that the file doesn't name. The file turns off
  the two the relay's packages have, because pnpm already installs the binary
  each one checks for.

The check workflow also runs `pnpm audit signatures`, which fails
if a package's registry signature doesn't verify.

Routing uses [Hono](https://hono.dev). Request bodies are checked with
[Zod](https://zod.dev).

## Lint

Oxlint runs the rules, and tsgolint runs the type-aware ones with TypeScript 7,
reading each file's nearest `tsconfig.json`. The rules are in two files:

- `oxlint.presets.ts` holds the rules of ESLint's recommended preset and
  typescript-eslint's `strictTypeChecked` and `stylisticTypeChecked` presets,
  translated for Oxlint, which has no presets of its own.
- `oxlint.config.ts` holds the house rules, each with a comment saying why.

A few house rules shape how the code reads:

- Types, not interfaces, and named return types instead of inline object
  shapes.
- Conditions are real booleans: `if (stub === undefined)`, never `if (!stub)`.
- Every `if` has braces, with a blank line after each block and before each
  `return`.
- No casts that claim more than the compiler knows. Parse with Zod, or narrow
  with a type guard.
- A function that returns a promise is `async` and awaits what it returns.

One cast remains. `sessionOf` in `tenant.ts` reads the session the relay
attached to a socket, behind a disable comment that says why.

Oxlint runs some rules through JavaScript plugins it marks as alpha.
`tests/lint/lint.test.ts` lints `tests/lint/fixtures/violations.ts`, which
breaks a set of rules on purpose, including every rule that runs as an alpha
plugin, and checks the exact count per rule. An Oxlint update that stops a
rule reporting fails that test. `pnpm lint` skips the fixture. Vitest runs
this test in a `node` project and the rest in a `worker` project, inside the
Workers runtime.

## Settings

Workers Logs are off in `wrangler.jsonc`, so Cloudflare keeps no record of the
requests the relay receives.

## Checking a change

```bash
make relay-check
```

This installs the packages, then runs `pnpm check` and `pnpm build`. Nothing
is deployed. It needs [mise](https://mise.jdx.dev), which runs each step with
the pinned Node and pnpm. The `Relay check` workflow runs the same steps on a
pull request that changes `relay/` or `mise.toml`.

The relay's scripts run from `relay/`:

| Script | What it does |
|---|---|
| `pnpm check` | Generates the Worker's types with `wrangler types`, then runs `typecheck`, `lint`, `format:check`, and `test` together and reports every failure instead of stopping at the first. |
| `pnpm typecheck` | `tsc` on each of the four projects below, against the types `pnpm check` generated. |
| `pnpm test` | The tests, in a random order. A failing run prints its seed, and `pnpm test --sequence.seed=<seed>` replays that order. |
| `pnpm lint` | [Oxlint](https://oxc.rs/docs/guide/usage/linter), with type-aware rules. |
| `pnpm format` / `format:check` | [Oxfmt](https://oxc.rs/docs/guide/usage/formatter): rewrite the files, or only report. It formats TypeScript and JSON at a width of 100. |
| `pnpm build` | Bundles the Worker into `dist/index.js` with `wrangler deploy --dry-run`. |
| `pnpm dev` | Runs the Worker locally. |

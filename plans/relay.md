# The relay

The relay is a Cloudflare Worker in [`relay/`](../relay). It is not deployed,
and Hermes does not call it.

## Tenants

A tenant is a GitHub account whose owner registered a GitHub App of their own
with the relay. The owner's client picks the tenant's ID: 32 lowercase hex
characters.

Each tenant is one Durable Object, named by the tenant's ID. The relay keeps no
list of tenants. A tenant's Durable Object stores its registration: the invite
code it used and the App's ID, client ID, client secret, and webhook secret.

## Requests

| Request | Response |
|---|---|
| `GET /version` | `200 {"commit": "<sha>"}`: the commit the running Worker was built from. A local run reports `dev`. |
| `PUT /tenants/<tenant>` | Registers a tenant. See below. |

A path with a malformed tenant ID answers `404`.

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
| `403` | The invite code is not one the relay accepts. Nothing is stored. |
| `409` | The tenant is registered with different values. |

A tenant registers once, so someone who learns a tenant's ID can't replace its
credentials. Sending the stored registration again answers `201`, so a client
whose first request succeeded but whose connection dropped can retry.

## Invite codes

The `INVITE_CODES` secret holds the codes the relay accepts, separated by
commas. Any number of tenants can register with one code. To make a code and
set the list:

```bash
openssl rand -hex 8
```

```bash
cd relay && npx wrangler secret put INVITE_CODES
```

## Layout

```
relay/
├── src/
│   ├── index.ts          the routes: parse the request, call the tenant, map the result
│   ├── tenant.ts         the Tenant Durable Object
│   └── registration.ts   decides whether a registration is accepted
├── test/                 Vitest tests, run inside the Workers runtime
├── wrangler.jsonc        the Worker's name, bindings, and settings
├── vitest.config.ts
├── tsconfig.json
├── mise.toml             the Node version
└── package.json
```

Routing uses [Hono](https://hono.dev). Request bodies are checked with
[Zod](https://zod.dev).

## Settings

Workers Logs are off in `wrangler.jsonc`, so Cloudflare keeps no record of the
requests the relay receives.

## Checking a change

```bash
make relay-check
```

This installs the packages, generates the Worker's types with `wrangler types`,
type-checks with `tsc`, runs the tests, and bundles with
`wrangler deploy --dry-run`. Nothing is deployed. The `Relay check` workflow
runs the same steps on a pull request that changes `relay/`.

To run only the tests, or the Worker locally:

```bash
cd relay && npm test
```

```bash
cd relay && npm run dev
```

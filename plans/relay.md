# The relay

The relay is a Cloudflare Worker in [`relay/`](../relay). It answers one
request. It is not deployed, and Hermes does not call it.

## Requests

| Request | Response |
|---|---|
| `GET /version` | `{"commit": "<sha>"}`: the commit the running Worker was built from. A local run reports `dev`. |

## Layout

```
relay/
├── src/index.ts      the routes
├── wrangler.jsonc    the Worker's name and settings
├── tsconfig.json
├── mise.toml         the Node version
└── package.json
```

Routing uses [Hono](https://hono.dev).

## Settings

Workers Logs are off in `wrangler.jsonc`, so Cloudflare keeps no record of the
requests the relay receives.

## Checking a change

```bash
make relay-check
```

This installs the packages, generates the Worker's types with `wrangler types`,
type-checks with `tsc`, and bundles with `wrangler deploy --dry-run`. Nothing
is deployed. The `Relay check` workflow runs the same steps on a pull request
that changes `relay/`.

To run the Worker locally:

```bash
cd relay && npm run dev
```

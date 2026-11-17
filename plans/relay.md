# The relay

The relay is a Cloudflare Worker in [`relay/`](../relay).

## Requests

| Request | Response |
|---|---|
| `GET /version` | `200 {"commit": "<sha>"}`: the commit the running Worker was built from. A local run reports `dev`. |

A request the relay fails to handle answers `500` with no body. The relay
prints nothing about it.

## Layout

```
relay/
├── src/                  everything the Worker runs, and nothing else
│   ├── index.ts          the Worker's entry: exports the routes
│   ├── http/
│   │   └── app.ts        the routes
│   ├── registration.ts   decides whether a registration is accepted
│   ├── delivery.ts       decides what to do with a webhook delivery
│   ├── session.ts        a socket's states, how long each lasts, and the hello message
│   └── json.ts           parses JSON text without throwing
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

Routing uses [Hono](https://hono.dev).

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

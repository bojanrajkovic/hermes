# Hermes documentation index

Hermes is a macOS app for reviewing GitHub pull requests. This file lists the
documentation. Read it with [PROGRESS.md](PROGRESS.md) to get up to speed.

## Start here

- [README.md](README.md): what Hermes does, requirements, build commands, and keyboard shortcuts.
- [PROGRESS.md](PROGRESS.md): what works, and what is known not to work or is unverified.
- [PROBLEMS.md](PROBLEMS.md): build and dependency problems and how the repository handles each.

## How it works

- [plans/architecture.md](plans/architecture.md): the targets, what each owns, and how state and data flow.
- [plans/github.md](plans/github.md): authentication through `gh`, the API client, and how the lists load.
- [plans/diff-viewer.md](plans/diff-viewer.md): loading, rendering, and refreshing a diff; review comments; go to definition.
- [plans/deep-links.md](plans/deep-links.md): the `hermes://` links and what each opens.
- [plans/sessions.md](plans/sessions.md): launching Claude Code sessions, worktrees, and the embedded terminal.
- [plans/design-system.md](plans/design-system.md): the type scale, layout metrics, and shared views in `HermesUI`.
- [plans/build-system.md](plans/build-system.md): how `make` and `build.sh` turn the package into a signed app, the tool versions `mise.toml` and `.xcode-version` pin, which dependency updates Renovate opens and merges, and the test switches.
- [plans/relay.md](plans/relay.md): the relay Worker in `relay/`, the requests it answers, its packages, lint rules, and layout, and how to check a change to it.

## Decisions

- [plans/webhooks.md](plans/webhooks.md): the optional webhook forwarders that make a change show in seconds, and which repositories get one.
- [plans/relay-privacy.md](plans/relay-privacy.md): what the relay handles, who can see each piece, how to check what is running, and where the protection stops.
- [plans/attention-inbox.md](plans/attention-inbox.md): what puts a pull request in "Needs Your Attention", and how the reasons rank.
- [plans/navigation-bakeoff.md](plans/navigation-bakeoff.md): the three navigation styles that were compared and why Inbox stayed, with screenshots.

## Rules

- [CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md): instructions for agents working in this repository. The two files have the same content.
- [SWIFTUI-RULES.md](SWIFTUI-RULES.md): general SwiftUI rules with the failure each one prevents. Code comments cite its section numbers.

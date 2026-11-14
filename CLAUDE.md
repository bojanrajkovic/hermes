# Working in this repository

Hermes is a macOS app for reviewing GitHub pull requests. It is a Swift
package: Swift 6 language mode, macOS 26 or newer, no Xcode project.

Read [PLAN.md](PLAN.md) and [PROGRESS.md](PROGRESS.md) first. Read
[plans/architecture.md](plans/architecture.md) before changing code.

## Documentation

* Keep PLAN.md as the index to the documentation for this codebase.

* Store specific in-depth documentation in plans/whatever.md.

* Record progress in PROGRESS.md. I should be able to tell a future agent "read PLAN.md and
  PROGRESS.md" and trust it's up to speed with this codebase.

* Documents describe the code as it is. When a fact changes, replace the stale lines.

## Pull requests

* You may push PRs, but you MUST NOT ever merge them yourself to main.

## GitHub writes

* The only repository you may write to is `bojanrajkovic/hermes-playground`. That covers
  `gh api` with POST, PATCH, PUT, or DELETE, reviews, comments, pushes, and any test that
  submits a review.

* Every other repository is read-only, including the ones Hermes shows while you test it.

* The user ignores `hermes-playground` in Settings, so it doesn't show in their lists. To test
  against it, launch the app with `HERMES_SHOW_IGNORED=1`, which switches the ignore list off for
  that run without changing the saved setting.

## Target layout

* Logic goes in a `*Kit` target with no UI, so it is testable without a window.

* Each feature's views and models go in its own `*UI` target.

* A `*UI` target never imports another feature's `*UI` target. `MarkdownUI` and `HermesUI`
  are the exceptions: any `*UI` target may import them.

* The `Hermes` executable target is the only place features meet. Navigation, the lists, and
  the wiring between features live there.

* Models are `@Observable @MainActor` classes. `GitHubClient` and `RepoCache` are actors.
  There is no `ObservableObject`.

## Build and test

* `make check` compiles. `make test` runs the tests. Run both after every change.

* `make build` assembles and signs `build/Hermes.app`. `make run` builds the optimized
  app and opens it.

* For a UI change, also look at the result. Run the built executable with
  `HERMES_SNAPSHOT_DIR=<directory>` to write PNGs of every screen without opening the app.
  [plans/build-system.md](plans/build-system.md) lists the other test switches.

* Tests go where logic can be wrong: parsing, line math, command lines, GitHub decoding.
  Use swift-testing (`@Test`, `#expect`).

## UI

* Fonts and shared metrics come from `Theme` in `Sources/HermesUI/Theme.swift`. Add a token
  there before repeating a literal. [plans/design-system.md](plans/design-system.md) has the
  type scale. Pay attention to type weight and emphasis.

* The UI should make sense as a modern macOS app, with modern professional macOS idioms.
  Keep things simple.

* Follow [SWIFTUI-RULES.md](SWIFTUI-RULES.md). Code comments cite its section numbers.

## Dependencies

* Read [PROBLEMS.md](PROBLEMS.md) before changing a dependency version in `Package.swift`.
  Several grammar versions are tied to files in `Sources/TreeSitterScanners` and `Vendor/`.

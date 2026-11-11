# Problems

Build and dependency problems in this repository, and what handles each one.
[SWIFTUI-RULES.md](SWIFTUI-RULES.md) covers general SwiftUI problems.

## Four grammar packages do not compile their scanner as a dependency

The CSS, JavaScript, Python, and YAML tree-sitter packages only compile
`scanner.c` when built from their own directory. As a dependency they build
without it, and the app fails to link with undefined
`tree_sitter_<language>_external_scanner_*` symbols.

The `TreeSitterScanners` target holds copies of those scanner files, plus the
YAML scanner's three schema files. `SyntaxKit` depends on it, which supplies
the missing symbols.

The copies must match the grammar versions. That is why `Package.swift` pins
these four packages with `exact:`. To upgrade one, change its version and copy
the new `src/scanner.c` over the file in `Sources/TreeSitterScanners`.

## tree-sitter-swift is pinned to a revision

The release tags of `alex-pinkus/tree-sitter-swift` do not contain the
generated parser, so a tagged version does not build. `Package.swift` pins a
revision that includes the generated files.

## The Ruby grammar is vendored

Cloning `tree-sitter/tree-sitter-ruby` through SwiftPM stalls. A copy of
v0.23.1 lives in `Vendor/tree-sitter-ruby` and `Package.swift` uses it as a
local package. The copy's manifest drops the upstream test target and its
dependency.

To upgrade, replace `src/` and `queries/` from the upstream release and update
the version in the comment at the top of `Vendor/tree-sitter-ruby/Package.swift`.

## libghostty-spm is pinned to an exact version

`libghostty-spm` ships a prebuilt libghostty and tags date-stamped builds,
such as `2.2.2026110702`. `SessionsUI` depends on details of its behavior: the
`command` config key, the close callback when the process exits, and a surface
that only runs while its view is in a window. `Package.swift` pins it with
`exact:` so a package update cannot change any of that. To upgrade, change the
version and run a session to its exit.

## Test resource bundles must stay out of the app

`swift build` leaves every target's resource bundle in the build directory,
including the test fixtures (`Hermes_GitHubKitTests.bundle` and others) once
the tests have been built. `build.sh` copies `*.bundle` into
`Hermes.app/Contents/Resources` and skips names that end in `Tests.bundle`.

A new test target with resources must keep the `Tests` suffix in its name, or
its fixtures ship in the app.

## Resource bundles sit in different places per build system

SwiftPM's native build puts a bundle's files at the bundle root. The
swiftbuild backend nests them under `Contents/Resources`. Under `swift test`,
`Bundle.main` is the test runner, not the code under test.

`SyntaxKit` reads query files from its own bundle and from the grammar
packages' bundles, so it cannot use `Bundle.module`. `QueryStore` in
`Sources/SyntaxKit/Grammar.swift` searches the app's resources, the
executable's directory, and the directories above the binary that contains
`SyntaxKit`, and checks both layouts.

## SwiftPM stamps the wrong SDK version

`swift build` records the deployment target as the binary's SDK
version. macOS reads that stamp to choose an app's system appearance, so the
app ran with the previous release's toolbar and sidebar: an opaque toolbar
band, a 2-point strip between the sidebar and the list, and old segmented
controls. `build.sh` passes `-platform_version macos 26.0 <SDK version>` to
the linker so the stamp is the SDK the app was built with. Check with
`otool -l build/Hermes.app/Contents/MacOS/Hermes | grep -A4 LC_BUILD_VERSION`.
A binary from plain `swift build` or `swift run` still has the old stamp.

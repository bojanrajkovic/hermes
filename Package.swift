// swift-tools-version:6.2
import PackageDescription

// Hermes: a GitHub pull request reviewer for macOS.
//
// Logic lives in small library targets with no UI (the `*Kit` targets), so it
// is testable without a window. Each feature's views live in their own `*UI`
// target. The `Hermes` executable is the shell that wires them together.
let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

func grammar(_ repo: String, _ version: Version) -> Package.Dependency {
    .package(url: "https://github.com/\(repo)", from: version)
}

let package = Package(
    name: "Hermes",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.10.0"),
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026110702"),
        // The plain release tags omit the generated parser.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", revision: "82bb3a533e0801fd2bbaa11dc49676e10bf41948"),
        grammar("tree-sitter/tree-sitter-typescript", "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.25.0"),
        grammar("tree-sitter/tree-sitter-go", "0.25.0"),
        grammar("tree-sitter/tree-sitter-rust", "0.24.2"),
        grammar("tree-sitter/tree-sitter-c-sharp", "0.23.5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
        .package(path: "Vendor/tree-sitter-ruby"),
        grammar("tree-sitter/tree-sitter-json", "0.24.8"),
        grammar("tree-sitter/tree-sitter-bash", "0.25.1"),
        grammar("tree-sitter-grammars/tree-sitter-hcl", "1.2.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.2"),
        grammar("tree-sitter-grammars/tree-sitter-toml", "0.7.0"),
        grammar("tree-sitter/tree-sitter-html", "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.25.0"),
    ],
    targets: [
        // GitHub REST/GraphQL client, auth via `gh`, and the domain models.
        .target(name: "GitHubKit", swiftSettings: swift6),
        // Local git clones used to read files at a PR's head commit.
        .target(name: "RepoKit", swiftSettings: swift6),
        // Unified diff parsing and review comment positions.
        .target(name: "DiffKit", swiftSettings: swift6),
        // The CSS, JavaScript, Python, and YAML grammar packages only compile their
        // scanner when built from their own directory, so as dependencies they
        // fail to link. This target holds copies of those four scanner.c files.
        // Keep them in step with the `exact:` versions above.
        .target(name: "TreeSitterScanners", cSettings: [.unsafeFlags(["-w"])]),
        // Tree-sitter syntax highlighting and definition lookup.
        .target(
            name: "SyntaxKit",
            dependencies: [
                "TreeSitterScanners",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterHCL", package: "tree-sitter-hcl"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
            ],
            resources: [.copy("Queries")],
            swiftSettings: swift6
        ),

        // Shared type scale, metrics, and small reusable views.
        .target(name: "HermesUI", swiftSettings: swift6),
        // GitHub-flavored Markdown (with Mermaid) and rendered Markdown diffs, in a web view.
        .target(name: "MarkdownUI", resources: [.copy("Resources")], swiftSettings: swift6),
        // The diff viewer: review comments, go-to-definition.
        .target(
            name: "DiffUI",
            dependencies: ["HermesUI", "MarkdownUI", "GitHubKit", "RepoKit", "DiffKit", "SyntaxKit"],
            swiftSettings: swift6
        ),
        // CI check lists and the log viewer.
        .target(name: "ChecksUI", dependencies: ["HermesUI", "MarkdownUI", "GitHubKit"], swiftSettings: swift6),
        // Embedded terminal and Claude Code session launching.
        .target(
            name: "SessionsUI",
            dependencies: [
                "HermesUI", "GitHubKit", "RepoKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            swiftSettings: swift6
        ),

        .executableTarget(
            name: "Hermes",
            dependencies: ["HermesUI", "MarkdownUI", "GitHubKit", "RepoKit", "DiffKit", "SyntaxKit", "DiffUI", "ChecksUI", "SessionsUI"],
            swiftSettings: swift6
        ),

        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RepoKitTests", dependencies: ["RepoKit"]),
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SyntaxKitTests", dependencies: ["SyntaxKit"]),
        .testTarget(name: "MarkdownUITests", dependencies: ["MarkdownUI"]),
        .testTarget(name: "DiffUITests", dependencies: ["DiffUI"]),
        .testTarget(name: "ChecksUITests", dependencies: ["ChecksUI"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SessionsUITests", dependencies: ["SessionsUI"]),
        .testTarget(name: "HermesTests", dependencies: ["Hermes", "HermesUI", "GitHubKit"]),
    ]
)

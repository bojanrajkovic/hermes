// swift-tools-version:5.3
import PackageDescription

// tree-sitter-ruby v0.23.1, copied in because cloning the upstream repository
// through SwiftPM stalls. The upstream test target and its dependency are removed.
let package = Package(
    name: "TreeSitterRuby",
    products: [
        .library(name: "TreeSitterRuby", targets: ["TreeSitterRuby"]),
    ],
    targets: [
        .target(
            name: "TreeSitterRuby",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            resources: [.copy("queries")],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        ),
    ],
    cLanguageStandard: .c11
)

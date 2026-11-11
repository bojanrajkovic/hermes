/// A source language SyntaxKit can parse, or ``plainText`` for everything else.
public enum Language: String, Sendable, Hashable, CaseIterable {
    case swift, typescript, tsx, javascript, go, rust, csharp, python, ruby
    case json, bash, hcl, yaml, toml, html, css
    /// No grammar. Highlighting yields plain tokens; identifiers and definitions are empty.
    case plainText

    /// Detects the language of a file.
    ///
    /// The file name is checked first (`Dockerfile`, `.zshrc`, `Cargo.lock`), then the
    /// extension, then the shebang. Svelte and Vue files are treated as HTML, and a
    /// Dockerfile as Bash. Files with no grammar, such as `Makefile` and `go.mod`,
    /// yield ``plainText``.
    ///
    /// - Parameters:
    ///   - path: A file path or bare file name. Only the last component is used.
    ///   - firstLine: The file's first line. Used for its shebang (`#!/usr/bin/env python3`)
    ///     when the name and extension are not recognized.
    public init(path: String, firstLine: String? = nil) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let ext = name.contains(".") ? name.split(separator: ".").last.map { $0.lowercased() } ?? "" : ""
        self = Self.fileNames[name]
            ?? (name.hasPrefix("Dockerfile") || name.hasSuffix(".Dockerfile") ? .bash : nil)
            ?? Self.extensions[ext]
            ?? firstLine.flatMap(Self.language(forShebang:))
            ?? .plainText
    }

    private static let extensions: [String: Language] = [
        "swift": .swift,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "tsx": .tsx,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "go": .go,
        "rs": .rust,
        "cs": .csharp, "csx": .csharp,
        "py": .python, "pyi": .python,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby,
        "json": .json, "jsonc": .json,
        "sh": .bash, "bash": .bash, "zsh": .bash,
        "tf": .hcl, "tfvars": .hcl, "hcl": .hcl,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml,
        "html": .html, "htm": .html, "svelte": .html, "vue": .html,
        "css": .css,
    ]

    private static let fileNames: [String: Language] = [
        ".bashrc": .bash, ".bash_profile": .bash, ".zshrc": .bash, ".zprofile": .bash,
        ".profile": .bash, ".envrc": .bash,
        "Cargo.lock": .toml, "uv.lock": .toml, "poetry.lock": .toml, "Pipfile": .toml,
        "Package.resolved": .json, "composer.lock": .json, ".prettierrc": .json,
        ".eslintrc": .json, ".babelrc": .json,
        ".clang-format": .yaml,
        "Gemfile": .ruby, "Rakefile": .ruby, "Brewfile": .ruby,
    ]

    private static func language(forShebang line: String) -> Language? {
        guard line.hasPrefix("#!") else { return nil }
        var words = line.dropFirst(2).split(whereSeparator: \.isWhitespace)
            .map { $0.split(separator: "/").last.map(String.init) ?? "" }
        if words.first == "env" {
            words.removeFirst()
            words.removeAll { $0.hasPrefix("-") }
        }
        // "python3.12" -> "python"
        guard let interpreter = words.first?.prefix(while: \.isLetter) else { return nil }
        switch interpreter {
        case "sh", "bash", "zsh", "dash", "ksh": return .bash
        case "python": return .python
        case "ruby": return .ruby
        case "node": return .javascript
        case "swift": return .swift
        default: return nil
        }
    }
}

import Foundation
import Testing

@testable import SyntaxKit

/// The kind of the token covering the first occurrence of `text` in `source`.
private func kind(of text: String, in source: String, _ language: Language) -> TokenKind? {
    guard let (line, column) = position(of: text, in: source) else { return nil }
    return Syntax.highlight(source, language: language)[line].first { $0.range.contains(column) }?.kind
}

/// Zero-based line and UTF-16 column of the first occurrence of `text`.
private func position(of text: String, in source: String) -> (line: Int, column: Int)? {
    guard let range = source.range(of: text) else { return nil }
    let before = Array(source[..<range.lowerBound].utf16)
    let lineStart = before.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
    return (before.count { $0 == 0x0A }, before.count - lineStart)
}

private func definitions(_ name: String, in source: String, _ language: Language) -> [DefinitionKind] {
    Syntax.definitions(named: name, in: source, language: language).map(\.kind)
}

private let parsed = Language.allCases.filter { $0 != .plainText }

@Suite struct LanguageDetection {
    @Test(arguments: [
        ("Sources/App/Main.swift", Language.swift),
        ("src/index.ts", .typescript),
        ("src/App.tsx", .tsx),
        ("lib/util.mjs", .javascript),
        ("components/Button.jsx", .javascript),
        ("cmd/main.go", .go),
        ("src/lib.rs", .rust),
        ("Program.cs", .csharp),
        ("tools/run.py", .python),
        ("app/models/user.rb", .ruby),
        ("lib/tasks/db.rake", .ruby),
        ("hermes.gemspec", .ruby),
        ("Gemfile", .ruby),
        ("Rakefile", .ruby),
        ("Brewfile", .ruby),
        ("Gemfile.lock", .plainText),
        ("package.json", .json),
        ("scripts/deploy.sh", .bash),
        ("infra/main.tf", .hcl),
        (".github/workflows/ci.yml", .yaml),
        ("Cargo.toml", .toml),
        ("index.html", .html),
        ("App.svelte", .html),
        ("App.vue", .html),
        ("site.css", .css),
        ("README.MD", .plainText),
        ("FILE.JSON", .json),
        ("Dockerfile", .bash),
        ("docker/Dockerfile.dev", .bash),
        ("Cargo.lock", .toml),
        (".zshrc", .bash),
        ("Makefile", .plainText),
        ("go.mod", .plainText),
        ("LICENSE", .plainText),
    ])
    func fromPath(path: String, expected: Language) {
        #expect(Language(path: path) == expected)
    }

    @Test(arguments: [
        ("#!/bin/bash", Language.bash),
        ("#!/usr/bin/env python3", .python),
        ("#!/usr/bin/env -S node --harmony", .javascript),
        ("#!/usr/bin/python3.12", .python),
        ("#!/usr/bin/env ruby", .ruby),
        ("#!/usr/bin/ruby3.3 -w", .ruby),
        ("#! /bin/sh -e", .bash),
        ("#!/usr/bin/perl", .plainText),
        ("echo hello", .plainText),
    ])
    func fromShebang(firstLine: String, expected: Language) {
        #expect(Language(path: "bin/tool", firstLine: firstLine) == expected)
    }

    @Test func extensionWinsOverShebang() {
        #expect(Language(path: "tool.py", firstLine: "#!/bin/bash") == .python)
    }
}

@Suite struct Queries {
    @Test(arguments: parsed)
    func compileFromTestLayout(language: Language) {
        #expect(Grammar.highlights(for: language) != nil)
        #expect((Grammar.definitions(for: language) != nil) == !language.definitionFiles.isEmpty)
    }

    /// Copies the built bundles into `Hermes.app/Contents/Resources`, as `build.sh`
    /// does, and loads every query from there alone. `flat` rewrites each bundle to
    /// the layout of the native SwiftPM build system, with resources at its root.
    @Test(arguments: [false, true])
    func compileFromAppLayout(flat: Bool) throws {
        let files = FileManager.default
        let probe = "TreeSitterGo_TreeSitterGo.bundle"
        let products = try #require(
            QueryStore.standard.roots.first { files.fileExists(atPath: $0.appendingPathComponent(probe).path) })

        let resources = files.temporaryDirectory
            .appendingPathComponent("SyntaxKitTests-\(UUID().uuidString)/Hermes.app/Contents/Resources")
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: resources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        for bundle in try files.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
        where bundle.pathExtension == "bundle" {
            let nested = bundle.appendingPathComponent("Contents/Resources")
            let hasNested = files.fileExists(atPath: nested.path)
            try files.copyItem(
                at: flat && hasNested ? nested : bundle,
                to: resources.appendingPathComponent(bundle.lastPathComponent))
        }

        let store = QueryStore(roots: [resources])
        for language in parsed {
            #expect(Grammar.highlights(for: language, store: store) != nil, "\(language)")
            #expect(
                (Grammar.definitions(for: language, store: store) != nil) == !language.definitionFiles.isEmpty,
                "\(language)")
        }
    }

    @Test func missingBundlesYieldNoQuery() {
        let store = QueryStore(roots: [URL(fileURLWithPath: "/nonexistent")])
        #expect(Grammar.highlights(for: .swift, store: store) == nil)
    }
}

@Suite struct Highlighting {
    @Test func swift() {
        let source = """
            import Foundation
            // A greeter.
            struct Greeter {
                let name: String
                func greet(times: Int = 2) -> String {
                    return "Hello, \\(name)" + String(times)
                }
            }
            """
        #expect(kind(of: "import", in: source, .swift) == .keyword)
        #expect(kind(of: "// A greeter.", in: source, .swift) == .comment)
        #expect(kind(of: "struct", in: source, .swift) == .keyword)
        #expect(kind(of: "Greeter", in: source, .swift) == .type)
        #expect(kind(of: "greet(", in: source, .swift) == .function)
        #expect(kind(of: "Int", in: source, .swift) == .type)
        #expect(kind(of: "2", in: source, .swift) == .number)
        #expect(kind(of: "Hello", in: source, .swift) == .string)
        #expect(kind(of: "return", in: source, .swift) == .keyword)
    }

    @Test(arguments: [Language.typescript, .tsx])
    func typeScript(language: Language) {
        let source = """
            import { api } from "./api";
            interface User { id: number }
            export const load = async (id: number): Promise<User> => {
              // fetch it
              return api.get(`/users/${id}`);
            };
            class Store extends Base { count = 0 }
            """
        #expect(kind(of: "import", in: source, language) == .keyword)
        #expect(kind(of: "\"./api\"", in: source, language) == .string)
        #expect(kind(of: "interface", in: source, language) == .keyword)
        #expect(kind(of: "User", in: source, language) == .type)
        #expect(kind(of: "number", in: source, language) == .type)
        #expect(kind(of: "load", in: source, language) == .function)
        #expect(kind(of: "// fetch it", in: source, language) == .comment)
        #expect(kind(of: "get", in: source, language) == .function)
        #expect(kind(of: "/users/", in: source, language) == .string)
        #expect(kind(of: "0", in: source, language) == .number)
    }

    @Test func tsxTags() {
        let source = "const view = <div className=\"box\"><Label text={title} /></div>;"
        #expect(kind(of: "div", in: source, .tsx) == .tag)
        #expect(kind(of: "className", in: source, .tsx) == .attribute)
        #expect(kind(of: "\"box\"", in: source, .tsx) == .string)
    }

    @Test func javaScript() {
        let source = """
            const MAX = 10;
            function add(a, b) { return a + b; }
            const user = { name: 'x' };
            console.log(add(1, MAX), user.name, this);
            """
        #expect(kind(of: "const", in: source, .javascript) == .keyword)
        #expect(kind(of: "MAX", in: source, .javascript) == .constant)
        #expect(kind(of: "add", in: source, .javascript) == .function)
        #expect(kind(of: "'x'", in: source, .javascript) == .string)
        #expect(kind(of: "log", in: source, .javascript) == .function)
        #expect(kind(of: "name", in: source, .javascript) == .property)
        #expect(kind(of: "this", in: source, .javascript) == .keyword)
        #expect(kind(of: "+", in: source, .javascript) == .operator)
        #expect(kind(of: ";", in: source, .javascript) == .punctuation)
    }

    @Test func go() {
        let source = """
            package main
            // Server handles requests.
            type Server struct { port int }
            func (s *Server) Run(addr string) error {
            \treturn listen(addr, s.port, 8080, "tcp")
            }
            """
        #expect(kind(of: "package", in: source, .go) == .keyword)
        #expect(kind(of: "// Server handles requests.", in: source, .go) == .comment)
        #expect(kind(of: "Server struct", in: source, .go) == .type)
        #expect(kind(of: "Run", in: source, .go) == .function)
        #expect(kind(of: "listen", in: source, .go) == .function)
        #expect(kind(of: "addr,", in: source, .go) == .variable)
        #expect(kind(of: "port,", in: source, .go) == .property)
        #expect(kind(of: "8080", in: source, .go) == .number)
        #expect(kind(of: "\"tcp\"", in: source, .go) == .string)
    }

    @Test func rust() {
        let source = """
            use std::fmt;
            /// A point.
            #[derive(Debug)]
            pub struct Point { x: i32 }
            impl Point {
                pub fn norm(&self) -> i32 { self.x * 2 + MAX }
            }
            fn main() { println!("{}", Point { x: 1 }.norm()); }
            """
        #expect(kind(of: "use", in: source, .rust) == .keyword)
        #expect(kind(of: "/// A point.", in: source, .rust) == .comment)
        #expect(kind(of: "derive", in: source, .rust) == .attribute)
        #expect(kind(of: "Point", in: source, .rust) == .type)
        #expect(kind(of: "i32", in: source, .rust) == .type)
        #expect(kind(of: "norm", in: source, .rust) == .function)
        // The Rust grammar's query captures numbers as `@constant.builtin`.
        #expect(kind(of: "2 +", in: source, .rust) == .constant)
        #expect(kind(of: "println", in: source, .rust) == .function)
        #expect(kind(of: "\"{}\"", in: source, .rust) == .string)
    }

    @Test func cSharp() {
        let source = """
            using System;
            namespace App {
                // Entry point.
                public class Program {
                    public int Count { get; set; }
                    static void Main(string[] args) { Console.WriteLine("hi" + 42); }
                }
            }
            """
        #expect(kind(of: "using", in: source, .csharp) == .keyword)
        #expect(kind(of: "// Entry point.", in: source, .csharp) == .comment)
        #expect(kind(of: "class", in: source, .csharp) == .keyword)
        #expect(kind(of: "Program", in: source, .csharp) == .type)
        #expect(kind(of: "Main", in: source, .csharp) == .function)
        #expect(kind(of: "\"hi\"", in: source, .csharp) == .string)
        #expect(kind(of: "42", in: source, .csharp) == .number)
    }

    @Test func python() {
        let source = """
            import os
            # Greets.
            class Greeter(Base):
                @staticmethod
                def greet(name: str) -> str:
                    return f"hi {name}" + str(3) if name else None
            """
        #expect(kind(of: "import", in: source, .python) == .keyword)
        #expect(kind(of: "# Greets.", in: source, .python) == .comment)
        #expect(kind(of: "class", in: source, .python) == .keyword)
        #expect(kind(of: "Greeter", in: source, .python) == .type)
        #expect(kind(of: "greet", in: source, .python) == .function)
        #expect(kind(of: "hi ", in: source, .python) == .string)
        #expect(kind(of: "3", in: source, .python) == .number)
        #expect(kind(of: "None", in: source, .python) == .constant)
    }

    @Test func ruby() {
        let source = """
            require "json"
            # Greets.
            class Greeter < Base
              LIMIT = 3
              def greet(name)
                count = 2
                puts "hi #{name}" * count
                @last = :sent if name.nil?
              end
            end
            """
        #expect(kind(of: "require", in: source, .ruby) == .function)
        #expect(kind(of: "# Greets.", in: source, .ruby) == .comment)
        #expect(kind(of: "class", in: source, .ruby) == .keyword)
        #expect(kind(of: "Greeter", in: source, .ruby) == .type)
        #expect(kind(of: "LIMIT", in: source, .ruby) == .constant)
        #expect(kind(of: "greet", in: source, .ruby) == .function)
        #expect(kind(of: "hi ", in: source, .ruby) == .string)
        #expect(kind(of: "2", in: source, .ruby) == .number)
        #expect(kind(of: "puts", in: source, .ruby) == .function)
        #expect(kind(of: "nil?", in: source, .ruby) == .function)
        #expect(kind(of: "@last", in: source, .ruby) == .property)
        #expect(kind(of: ":sent", in: source, .ruby) == .string)
        // Locals and parameters are variables, also inside an interpolation.
        #expect(kind(of: "count", in: source, .ruby) == .variable)
        #expect(kind(of: "name}", in: source, .ruby) == .variable)
    }

    @Test func json() {
        let source = #"{ "name": "hermes", "count": 3, "ok": true, "none": null }"#
        #expect(kind(of: "\"name\"", in: source, .json) == .property)
        #expect(kind(of: "\"hermes\"", in: source, .json) == .string)
        #expect(kind(of: "3", in: source, .json) == .number)
        #expect(kind(of: "true", in: source, .json) == .constant)
    }

    @Test func bash() {
        let source = """
            #!/bin/bash
            # Deploy.
            if [ -n "$TARGET" ]; then
              echo "deploying to $TARGET" | tee log.txt
            fi
            """
        #expect(kind(of: "# Deploy.", in: source, .bash) == .comment)
        #expect(kind(of: "if", in: source, .bash) == .keyword)
        #expect(kind(of: "echo", in: source, .bash) == .function)
        #expect(kind(of: "deploying", in: source, .bash) == .string)
        #expect(kind(of: "TARGET", in: source, .bash) == .property)
    }

    @Test func hcl() {
        let source = """
            # Web server.
            resource "aws_instance" "web" {
              ami           = var.ami_id
              instance_type = "t3.${local.size}"
              count         = length(var.zones) > 2 ? 3 : 1
              enabled       = true
            }
            """
        #expect(kind(of: "# Web server.", in: source, .hcl) == .comment)
        #expect(kind(of: "resource", in: source, .hcl) == .keyword)
        #expect(kind(of: "\"aws_instance\"", in: source, .hcl) == .string)
        #expect(kind(of: "ami ", in: source, .hcl) == .property)
        #expect(kind(of: "var", in: source, .hcl) == .keyword)
        #expect(kind(of: "ami_id", in: source, .hcl) == .property)
        #expect(kind(of: "t3.", in: source, .hcl) == .string)
        #expect(kind(of: "size", in: source, .hcl) == .property)
        #expect(kind(of: "length", in: source, .hcl) == .function)
        #expect(kind(of: "3 :", in: source, .hcl) == .number)
        #expect(kind(of: "true", in: source, .hcl) == .constant)
        #expect(kind(of: "?", in: source, .hcl) == .operator)
    }

    @Test func yaml() {
        let source = """
            # CI
            name: build
            steps:
              - run: "make test"
                retries: 3
            """
        #expect(kind(of: "# CI", in: source, .yaml) == .comment)
        #expect(kind(of: "name", in: source, .yaml) == .property)
        #expect(kind(of: "\"make test\"", in: source, .yaml) == .string)
        #expect(kind(of: "3", in: source, .yaml) == .number)
    }

    @Test func toml() {
        let source = """
            # Package
            [package]
            name = "hermes"
            edition = 2024
            publish = false
            """
        #expect(kind(of: "# Package", in: source, .toml) == .comment)
        // The TOML grammar's query colors keys and table names as types.
        #expect(kind(of: "package", in: source, .toml) == .type)
        #expect(kind(of: "name", in: source, .toml) == .type)
        #expect(kind(of: "\"hermes\"", in: source, .toml) == .string)
        #expect(kind(of: "2024", in: source, .toml) == .number)
        #expect(kind(of: "false", in: source, .toml) == .constant)
    }

    @Test func html() {
        let source = "<!-- nav -->\n<a href=\"/home\" class=\"link\">Home</a>"
        #expect(kind(of: "<!-- nav -->", in: source, .html) == .comment)
        #expect(kind(of: "a href", in: source, .html) == .tag)
        #expect(kind(of: "href", in: source, .html) == .attribute)
        #expect(kind(of: "/home", in: source, .html) == .string)
        #expect(kind(of: "Home", in: source, .html) == .plain)
    }

    @Test func css() {
        let source = "/* card */\n.card > a:hover { color: #fff; margin: 4px; }"
        #expect(kind(of: "/* card */", in: source, .css) == .comment)
        #expect(kind(of: "color", in: source, .css) == .property)
        #expect(kind(of: "4px", in: source, .css) == .number)
    }

    @Test func tokensCoverEveryLineInOrder() {
        let source = "func a() {\n\n    let s = \"é😀\" // done\r\n}\n"
        let lines = source.components(separatedBy: "\n")
        let tokens = Syntax.highlight(source, language: .swift)
        #expect(tokens.count == lines.count)
        for (line, lineTokens) in zip(lines, tokens) {
            var end = 0
            for token in lineTokens {
                #expect(token.range.lowerBound == end)
                #expect(!token.range.isEmpty)
                end = token.range.upperBound
            }
            #expect(end == line.utf16.count)
        }
        // Columns after the emoji count its two UTF-16 code units.
        #expect(kind(of: "// done", in: source, .swift) == .comment)
    }

    @Test func multilineTokensAreSplitPerLine() {
        let tokens = Syntax.highlight("/* one\n   two */ let x = 1", language: .swift)
        #expect(tokens[0] == [Token(range: 0..<6, kind: .comment)])
        #expect(tokens[1].first == Token(range: 0..<9, kind: .comment))
    }

    /// A diff hunk: starts inside a function and ends inside another.
    @Test func fragmentsStillHighlight() {
        let source = """
                    count = total + 1 // sum
                }
            }

            func next(value: Int) -> String {
                if value > 3 {
                    let label = "big"
            """
        #expect(kind(of: "1", in: source, .swift) == .number)
        #expect(kind(of: "// sum", in: source, .swift) == .comment)
        #expect(kind(of: "func", in: source, .swift) == .keyword)
        #expect(kind(of: "next", in: source, .swift) == .function)
        #expect(kind(of: "\"big\"", in: source, .swift) == .string)

        let goFragment = "\t\treturn nil, fmt.Errorf(\"bad %d\", code)\n\t}\n\tdefer f.Close()"
        #expect(kind(of: "return", in: goFragment, .go) == .keyword)
        #expect(kind(of: "\"bad %d\"", in: goFragment, .go) == .string)
        #expect(kind(of: "defer", in: goFragment, .go) == .keyword)
    }

    /// Hunks that start inside a body leave unbalanced braces, so statements near
    /// the edges do not parse. Their keywords must still be keywords.
    @Test func fragmentKeywordsSurviveSyntaxErrors() {
        let body = "            self.count += 1\n        }\n        return result\n    }\n\n"
            + "    private func reset() {\n        if let x = cache[key] {"
        #expect(kind(of: "return", in: body, .swift) == .keyword)
        #expect(kind(of: "if", in: body, .swift) == .keyword)
        #expect(kind(of: "func", in: body, .swift) == .keyword)

        let switchArm = "    case .a:\n        return 1\n    default:\n        break\n    }"
        for word in ["case", "return", "break"] {
            #expect(kind(of: word, in: switchArm, .swift) == .keyword, "\(word)")
        }
        // A name that only looks like part of a keyword is untouched.
        #expect(kind(of: "returned", in: "let returned = 1\n}", .swift) == .variable)
    }

    @Test func plainTextIsOnePlainTokenPerLine() {
        #expect(
            Syntax.highlight("let x = 1\n\nend", language: .plainText) == [
                [Token(range: 0..<9, kind: .plain)], [], [Token(range: 0..<3, kind: .plain)],
            ])
        #expect(Syntax.highlight("", language: .swift) == [[]])
    }

    @Test func oversizedSourceIsPlain() {
        let line = "let value = 1 // comment\n"
        let source = String(repeating: line, count: Syntax.maximumSourceBytes / line.utf8.count + 1)
        let tokens = Syntax.highlight(source, language: .swift)
        #expect(tokens[0] == [Token(range: 0..<24, kind: .plain)])
        #expect(Syntax.identifiers(in: source, language: .swift).lines.allSatisfy { $0.isEmpty })
        #expect(Syntax.definitions(named: "value", in: source, language: .swift).isEmpty)
    }

    @Test func minifiedSourceIsPlain() {
        let source = "var a=1;" + String(repeating: "f(a);", count: Syntax.maximumLineLength / 5 + 1)
        let tokens = Syntax.highlight(source, language: .javascript)
        #expect(tokens == [[Token(range: 0..<source.utf16.count, kind: .plain)]])
        #expect(Syntax.definitions(named: "a", in: source, language: .javascript).isEmpty)
    }
}

@Suite struct Identifiers {
    @Test func swiftIdentifiersExcludeKeywordsStringsAndComments() {
        let source = "let total = count(items) // total\nprint(\"total\" + user.name)"
        let map = Syntax.identifiers(in: source, language: .swift)
        #expect(map.lines[0].map(\.name) == ["total", "count", "items"])
        #expect(map.lines[0].map(\.range) == [4..<9, 12..<17, 18..<23])
        #expect(map.lines[1].map(\.name) == ["print", "user", "name"])
    }

    @Test func identifierAtPosition() {
        let source = "let é = 1\n  greet(name: é)"
        let map = Syntax.identifiers(in: source, language: .swift)
        #expect(map.identifier(atLine: 1, utf16Column: 2)?.name == "greet")
        #expect(map.identifier(atLine: 1, utf16Column: 6) == Identifier(name: "greet", range: 2..<7))
        #expect(map.identifier(atLine: 1, utf16Column: 7) == nil)
        #expect(map.identifier(atLine: 1, utf16Column: 14)?.name == "é")
        #expect(map.identifier(atLine: 0, utf16Column: 0) == nil)
        #expect(map.identifier(atLine: 9, utf16Column: 0) == nil)
        #expect(map.identifier(atLine: -1, utf16Column: 0) == nil)
    }

    @Test(arguments: [
        (Language.typescript, "const u: User = api.load(id);", ["u", "User", "api", "load", "id"]),
        (.tsx, "const v = <Label text={title} />;", ["v", "Label", "text", "title"]),
        (.javascript, "export function run(opts) { return opts.fast; }", ["run", "opts", "opts", "fast"]),
        (.go, "func (s *Server) Run(addr string) error {", ["s", "Server", "Run", "addr", "string", "error"]),
        (.rust, "let p = Point::new(cfg.width);", ["p", "Point", "new", "cfg", "width"]),
        (.csharp, "var user = repo.Find(id);", ["user", "repo", "Find", "id"]),
        (.python, "result = self.client.fetch(url)", ["result", "self", "client", "fetch", "url"]),
        (.ruby, "@total = Cart.sum(items, tax_rate)", ["@total", "Cart", "sum", "items", "tax_rate"]),
        (.bash, "deploy \"$TARGET\" --force", ["deploy", "TARGET"]),
        (.hcl, "ami = var.ami_id", ["ami", "var", "ami_id"]),
        (.json, "{ \"a\": 1 }", []),
        (.plainText, "some words", []),
    ])
    func perLanguage(language: Language, source: String, expected: [String]) {
        #expect(Syntax.identifiers(in: source, language: language).lines[0].map(\.name) == expected)
    }
}

@Suite struct Definitions {
    @Test func locationAndLineText() {
        let source = "import Foundation\r\n\r\n    func greet() {}\r\n"
        #expect(
            Syntax.definitions(named: "greet", in: source, language: .swift) == [
                Definition(line: 2, utf16Column: 9, kind: .function, lineText: "    func greet() {}")
            ])
        #expect(Syntax.definitions(named: "gree", in: source, language: .swift).isEmpty)
        #expect(Syntax.definitions(named: "", in: source, language: .swift).isEmpty)
        #expect(Syntax.definitions(named: "greet", in: source, language: .plainText).isEmpty)
    }

    @Test func memberFormsBeyondTags() {
        let ts = "enum Color { Red, Green = 2 }\nclass A { #secret = 1; constructor(private readonly repo: Repo, plain: number) {} }"
        for language in [Language.typescript, .tsx] {
            #expect(definitions("Red", in: ts, language) == [.constant])
            #expect(definitions("Green", in: ts, language) == [.constant])
            #expect(definitions("repo", in: ts, language) == [.property])
            #expect(definitions("plain", in: ts, language) == [])
            #expect(definitions("#secret", in: ts, language) == [.property])
        }
        #expect(definitions("#secret", in: "class C { #secret = 1 }", .javascript) == [.property])

        let python = "class C:\n    def __init__(self):\n        self.inst = 1\n        other.x = 2\n    def m(self):\n        self.late = 1\n"
        #expect(definitions("inst", in: python, .python) == [.property])
        #expect(definitions("x", in: python, .python) == [])
        #expect(definitions("late", in: python, .python) == [])

        #expect(definitions("Item", in: "trait T { type Item; }", .rust) == [.type])
        #expect(definitions("Item", in: "protocol P { associatedtype Item }", .swift) == [.type])

        let record = "public record R(int X, string Y);\nclass C { void M(int Z) {} }"
        #expect(definitions("X", in: record, .csharp) == [.property])
        #expect(definitions("Z", in: record, .csharp) == [])
    }

    @Test func usesAreNotDefinitions() {
        let source = "func run() {}\nrun()\nlet x = run\n"
        #expect(Syntax.definitions(named: "run", in: source, language: .swift).map(\.line) == [0])
    }

    @Test func swift() {
        let source = """
            protocol Shape { var area: Double { get }; func scale(by: Double) }
            struct Circle: Shape {
                let radius: Double
                var area: Double { radius * radius }
                func scale(by factor: Double) {}
                init(radius: Double) { self.radius = radius }
            }
            class Canvas {}
            enum Mode { case light, dark }
            extension Circle { func grow() {} }
            typealias Radius = Double
            func draw() {}
            let shared = Canvas()
            """
        #expect(definitions("Shape", in: source, .swift) == [.type])
        #expect(definitions("Circle", in: source, .swift) == [.type, .type])
        #expect(definitions("radius", in: source, .swift) == [.property])
        #expect(definitions("area", in: source, .swift) == [.property, .property])
        #expect(definitions("scale", in: source, .swift) == [.method, .method])
        #expect(definitions("Canvas", in: source, .swift) == [.type])
        #expect(definitions("Mode", in: source, .swift) == [.type])
        #expect(definitions("dark", in: source, .swift) == [.constant])
        #expect(definitions("grow", in: source, .swift) == [.method])
        #expect(definitions("Radius", in: source, .swift) == [.type])
        #expect(definitions("draw", in: source, .swift) == [.function])
        #expect(definitions("shared", in: source, .swift) == [.property])
    }

    @Test(arguments: [Language.typescript, .tsx])
    func typeScript(language: Language) {
        let source = """
            export interface User { id: number; rename(name: string): void }
            export type Id = string;
            export enum Color { Red }
            export const load = async (id: Id) => fetch(id);
            export const LIMIT = 10;
            let counter = 0;
            export function save(user: User) {}
            export class Store {
              private items: User[] = [];
              add(user: User) {}
            }
            abstract class Base {}
            namespace Util {}
            """
        #expect(definitions("User", in: source, language) == [.type])
        #expect(definitions("id", in: source, language) == [.property])
        #expect(definitions("rename", in: source, language) == [.method])
        #expect(definitions("Id", in: source, language) == [.type])
        #expect(definitions("Color", in: source, language) == [.type])
        #expect(definitions("load", in: source, language) == [.function])
        #expect(definitions("LIMIT", in: source, language) == [.constant])
        #expect(definitions("counter", in: source, language) == [.constant])
        #expect(definitions("save", in: source, language) == [.function])
        #expect(definitions("Store", in: source, language) == [.type])
        #expect(definitions("items", in: source, language) == [.property])
        #expect(definitions("add", in: source, language) == [.method])
        #expect(definitions("Base", in: source, language) == [.type])
        #expect(definitions("Util", in: source, language) == [.module])
    }

    @Test func javaScript() {
        let source = """
            const LIMIT = 10;
            var legacy = 1;
            function run() { const inner = 1; }
            const go = () => {};
            class Queue { size = 0; push(x) {} }
            export const api = {};
            """
        #expect(definitions("LIMIT", in: source, .javascript) == [.constant])
        #expect(definitions("legacy", in: source, .javascript) == [.variable])
        #expect(definitions("run", in: source, .javascript) == [.function])
        #expect(definitions("inner", in: source, .javascript) == [])
        #expect(definitions("go", in: source, .javascript) == [.function])
        #expect(definitions("Queue", in: source, .javascript) == [.type])
        #expect(definitions("size", in: source, .javascript) == [.property])
        #expect(definitions("push", in: source, .javascript) == [.method])
        #expect(definitions("api", in: source, .javascript) == [.constant])
    }

    @Test func go() {
        let source = """
            package main
            const Max = 10
            var (
            \tlogger = newLogger()
            )
            var single int
            type Server struct { port int }
            type Handler interface { Serve(req Request) error }
            type ID = string
            func (s *Server) Run() error { local := 1; return nil }
            func main() {}
            """
        #expect(definitions("Max", in: source, .go) == [.constant])
        #expect(definitions("logger", in: source, .go) == [.variable])
        #expect(definitions("single", in: source, .go) == [.variable])
        #expect(definitions("Server", in: source, .go) == [.type])
        #expect(definitions("port", in: source, .go) == [.property])
        #expect(definitions("Handler", in: source, .go) == [.type])
        #expect(definitions("Serve", in: source, .go) == [.method])
        #expect(definitions("ID", in: source, .go) == [.type])
        #expect(definitions("Run", in: source, .go) == [.method])
        #expect(definitions("main", in: source, .go) == [.function])
        #expect(definitions("local", in: source, .go) == [])
    }

    @Test func rust() {
        let source = """
            pub const MAX: u32 = 10;
            static COUNTER: u32 = 0;
            pub struct Point { pub x: i32 }
            pub enum Shape { Circle, Square }
            pub trait Draw { fn draw(&self); }
            impl Point { pub fn norm(&self) -> i32 { self.x } }
            pub type Alias = Point;
            mod geometry {}
            macro_rules! square { () => {}; }
            fn main() {}
            """
        #expect(definitions("MAX", in: source, .rust) == [.constant])
        #expect(definitions("COUNTER", in: source, .rust) == [.variable])
        #expect(definitions("Point", in: source, .rust) == [.type])
        #expect(definitions("x", in: source, .rust) == [.property])
        #expect(definitions("Shape", in: source, .rust) == [.type])
        #expect(definitions("Circle", in: source, .rust) == [.constant])
        #expect(definitions("Draw", in: source, .rust) == [.type])
        #expect(definitions("draw", in: source, .rust) == [.method])
        #expect(definitions("norm", in: source, .rust) == [.method])
        #expect(definitions("Alias", in: source, .rust) == [.type])
        #expect(definitions("geometry", in: source, .rust) == [.module])
        #expect(definitions("square", in: source, .rust) == [.function])
        #expect(definitions("main", in: source, .rust) == [.function])
    }

    @Test func cSharp() {
        let source = """
            namespace App.Core {
                public interface IStore { void Save(); }
                public struct Point { public int X; }
                public enum Mode { Light, Dark }
                public record User(string Name);
                public class Program {
                    private readonly int count;
                    public string Title { get; set; }
                    public void Run() { int Local() => 1; }
                }
            }
            """
        #expect(definitions("IStore", in: source, .csharp) == [.type])
        #expect(definitions("Save", in: source, .csharp) == [.method])
        #expect(definitions("Point", in: source, .csharp) == [.type])
        #expect(definitions("X", in: source, .csharp) == [.property])
        #expect(definitions("Mode", in: source, .csharp) == [.type])
        #expect(definitions("Dark", in: source, .csharp) == [.constant])
        #expect(definitions("User", in: source, .csharp) == [.type])
        #expect(definitions("Program", in: source, .csharp) == [.type])
        #expect(definitions("count", in: source, .csharp) == [.property])
        #expect(definitions("Title", in: source, .csharp) == [.property])
        #expect(definitions("Run", in: source, .csharp) == [.method])
        #expect(definitions("Local", in: source, .csharp) == [.function])
    }

    @Test func python() {
        let source = """
            LIMIT = 10
            def run(): pass
            class Queue(Base):
                size = 0
                def push(self, item): local = 1
                @property
                def empty(self): return True
            """
        #expect(definitions("LIMIT", in: source, .python) == [.constant])
        #expect(definitions("run", in: source, .python) == [.function])
        #expect(definitions("Queue", in: source, .python) == [.type])
        #expect(definitions("size", in: source, .python) == [.property])
        #expect(definitions("push", in: source, .python) == [.method])
        #expect(definitions("empty", in: source, .python) == [.method])
        #expect(definitions("local", in: source, .python) == [])
    }

    @Test func ruby() {
        let source = """
            LIMIT = 10
            def run; end
            module Jobs
              class Queue < Base
                attr_reader :size, :head
                attr_accessor :name
                define_method(:drain) { }
                alias_method :add, :push
                alias enqueue push
                def initialize(items)
                  @items = items
                  local = 1
                end
                def push(item); @late = item; end
                def self.build; new([]); end
                def limit=(value); end
                def empty?; size.zero?; end
              end
            end
            Jobs::Queue.build.push(run)
            """
        #expect(definitions("LIMIT", in: source, .ruby) == [.constant])
        #expect(definitions("run", in: source, .ruby) == [.method])
        #expect(definitions("Jobs", in: source, .ruby) == [.module])
        #expect(definitions("Queue", in: source, .ruby) == [.type])
        #expect(definitions("size", in: source, .ruby) == [.property])
        #expect(definitions("head", in: source, .ruby) == [.property])
        #expect(definitions("name", in: source, .ruby) == [.property])
        #expect(definitions("drain", in: source, .ruby) == [.method])
        #expect(definitions("add", in: source, .ruby) == [.method])
        #expect(definitions("enqueue", in: source, .ruby) == [.method])
        #expect(definitions("@items", in: source, .ruby) == [.property])
        #expect(definitions("@late", in: source, .ruby) == [])
        #expect(definitions("local", in: source, .ruby) == [])
        #expect(definitions("items", in: source, .ruby) == [])
        #expect(definitions("push", in: source, .ruby) == [.method])
        #expect(definitions("build", in: source, .ruby) == [.method])
        #expect(definitions("limit", in: source, .ruby) == [.method])
        #expect(definitions("empty?", in: source, .ruby) == [.method])
        // The column of a symbol's name skips the colon.
        #expect(
            Syntax.definitions(named: "head", in: source, language: .ruby) == [
                Definition(line: 4, utf16Column: 24, kind: .property, lineText: "    attr_reader :size, :head")
            ])
    }
    @Test func bash() {
        let source = "TARGET=prod\nexport REGION=us\ndeploy() { local x=1; }\nfunction build { :; }\ndeploy"
        #expect(definitions("TARGET", in: source, .bash) == [.variable])
        #expect(definitions("REGION", in: source, .bash) == [.variable])
        #expect(definitions("deploy", in: source, .bash) == [.function])
        #expect(definitions("build", in: source, .bash) == [.function])
    }

    @Test func hcl() {
        let source = """
            variable "region" { type = string }
            locals { size = "small" }
            resource "aws_instance" "web" { ami = var.region }
            data "aws_ami" "base" {}
            module "network" { source = "./network" }
            output "address" { value = aws_instance.web.public_ip }
            """
        #expect(definitions("region", in: source, .hcl) == [.variable])
        #expect(definitions("size", in: source, .hcl) == [.variable])
        #expect(definitions("web", in: source, .hcl) == [.variable])
        #expect(definitions("aws_instance", in: source, .hcl) == [])
        #expect(definitions("base", in: source, .hcl) == [.variable])
        #expect(definitions("network", in: source, .hcl) == [.module])
        #expect(definitions("address", in: source, .hcl) == [.variable])
        #expect(definitions("ami", in: source, .hcl) == [])
    }
}

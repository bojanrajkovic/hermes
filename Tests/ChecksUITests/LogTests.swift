import Foundation
import Testing
@testable import ChecksUI

func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "log", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct LogParserTests {
    @Test func stripsTimestampsAndKeepsThem() {
        let document = LogParser.parse("\u{FEFF}2026-11-11T02:46:28.1143357Z Current runner version: '2.338.2'\r\nno timestamp here\n")
        #expect(document.lines.map(\.text) == ["Current runner version: '2.338.2'", "no timestamp here"])
        #expect(document.lines.map(\.timestamp) == ["2026-11-11T02:46:28.1143357Z", nil])
    }

    @Test func groupsBecomeSections() {
        let document = LogParser.parse("""
            before
            ##[group]Build
            compiling
            ##[error]it broke
            ##[endgroup]
            between
            ##[group]First
            a
            ##[group]Second
            b
            """)
        #expect(document.lines.map(\.text) == ["before", "Build", "compiling", "it broke", "between", "First", "a", "Second", "b"])
        #expect(document.sections == [
            LogSection(header: 1, body: 2..<4, containsError: true),
            // A group inside an open group closes it; the last group runs to the end.
            LogSection(header: 5, body: 6..<7),
            LogSection(header: 7, body: 8..<9),
        ])
        #expect(document.lines.map(\.section) == [nil, 0, 0, 0, nil, 1, 1, 2, 2])
        #expect(document.firstError == 3)
        #expect(document.sectionsWithErrors == [0])
    }

    @Test func marksAnnotationsAndCommands() {
        let document = LogParser.parse("""
            ##[error]bad
            ##[warning]careful
            ##[notice]fyi
            ##[command]git version
            [command]/usr/bin/git init
            [not a marker]
            """)
        #expect(document.lines.map(\.kind) == [.error, .warning, .notice, .command, .command, .plain])
        #expect(document.lines.map(\.text) == ["bad", "careful", "fyi", "git version", "/usr/bin/git init", "[not a marker]"])
    }

    @Test func sgrSequencesBecomeSpans() {
        let e = "\u{1B}"
        let document = LogParser.parse("  \(e)[32m✓\(e)[0m ok \(e)[2m(3 ms)\(e)[0m \(e)[1;4;38;5;196mhot\(e)[22;24;39m \(e)[38;2;1;2;3mrgb\(e)[m end")
        let line = document.lines[0]
        #expect(line.text == "  ✓ ok (3 ms) hot rgb end")
        #expect(line.spans == [
            .init(range: 2..<3, style: LogStyle(color: .palette(2))),
            .init(range: 7..<13, style: LogStyle(dim: true)),
            .init(range: 14..<17, style: LogStyle(color: .rgb(255, 0, 0), bold: true, underline: true)),
            .init(range: 18..<21, style: LogStyle(color: .rgb(1, 2, 3))),
        ])
    }

    @Test func brightAndBackgroundCodes() {
        var style = LogStyle.plain
        style.apply(sgr: [90])
        #expect(style.color == .palette(8))
        // A background color is consumed with its arguments, not mistaken for other codes.
        style.apply(sgr: [48, 5, 1, 97])
        #expect(style == LogStyle(color: .palette(15)))
        style.apply(sgr: [48, 2, 1, 4, 4])
        #expect(style.underline == false)
    }

    @Test func indexedColors() {
        #expect(LogColor(indexed: 11) == .palette(11))
        #expect(LogColor(indexed: 16) == .rgb(0, 0, 0))
        #expect(LogColor(indexed: 231) == .rgb(255, 255, 255))
        #expect(LogColor(indexed: 232) == .rgb(8, 8, 8))
    }

    @Test func dropsOtherEscapeSequences() {
        let e = "\u{1B}"
        let document = LogParser.parse("a\(e)[2Kb\(e)[1Ac\(e)]0;title\u{07}d\(e)]8;;http://x\(e)\\e\rf\(e)")
        #expect(document.lines[0].text == "abcdef")
        #expect(document.lines[0].spans.isEmpty)
    }

    @Test func failingFixture() throws {
        let document = LogParser.parse(try fixture("pg-tests-fail"))
        #expect(document.lines.allSatisfy { $0.timestamp != nil })
        #expect(!document.lines.contains { $0.text.contains("\u{1B}") || $0.text.hasPrefix("##[") })

        let firstError = try #require(document.firstError)
        #expect(document.lines[firstError].text == "Expected InvalidTransitionError, but the function did not throw")
        let section = try #require(document.lines[firstError].section)
        #expect(document.lines[document.sections[section].header].text == "tracker")
        #expect(document.sectionsWithErrors == [section])
        #expect(document.lines.filter { $0.kind == .error }.count == 2)
        #expect(document.lines.filter { $0.kind == .warning }.count == 1)
        #expect(document.lines.contains { $0.kind == .command && $0.text == "/usr/bin/git version" })

        let passed = try #require(document.lines.first { $0.text.contains("register rejects duplicate ids") })
        #expect(passed.spans.first?.style == LogStyle(color: .palette(2)))
    }

    @Test func passingFixture() throws {
        let document = LogParser.parse(try fixture("pg-build-pass"))
        #expect(document.firstError == nil)
        #expect(document.sectionsWithErrors.isEmpty)
        #expect(document.sections.contains { document.lines[$0.header].text == "go build" })
    }

    @Test func largeLogParsesQuickly() {
        let line = "2026-11-11T02:46:29.6463984Z   \u{1B}[32m✓\u{1B}[0m billableWeightKg uses actual weight for dense parcels \u{1B}[2m(3 ms)\u{1B}[0m\n"
        let raw = String(repeating: line, count: 60_000)
        let clock = ContinuousClock()
        var document = LogDocument()
        let elapsed = clock.measure { document = LogParser.parse(raw) }
        #expect(document.lines.count == 60_000)
        // A debug build takes about 2 s; this only catches a quadratic regression.
        #expect(elapsed < .seconds(20))
    }
}

@Suite struct LogRendererTests {
    let document = LogParser.parse("""
        2026-11-11T02:46:28.1143357Z start
        2026-11-11T02:46:28.2Z ##[group]Build
        2026-11-11T02:46:28.3Z compiling
        2026-11-11T02:46:28.4Z ##[error]it broke
        2026-11-11T02:46:28.5Z ##[endgroup]
        2026-11-11T02:46:28.6Z done
        """)

    @Test func collapsedGroupsHideTheirLines() {
        let collapsed = LogRenderer.render(document, expanded: [], showTimestamps: false)
        #expect(collapsed.text.string == "start\n▸ Build\ndone\n")
        #expect(collapsed.lines == [0, 1, 4])
        #expect(collapsed.row(ofLine: 2) == nil)
        #expect(collapsed.row(ofLine: 4) == 2)

        let open = LogRenderer.render(document, expanded: [0], showTimestamps: false)
        #expect(open.text.string == "start\n▾ Build\n  compiling\n  Error: it broke\ndone\n")
        #expect(open.row(atCharacter: 0) == 0)
        #expect(open.row(atCharacter: 6) == 1)
        #expect(open.row(atCharacter: open.text.length - 1) == 4)
    }

    @Test func togglingOneGroupChangesOnlyItsRows() {
        let collapsed = LogRenderer.render(document, expanded: [], showTimestamps: false)
        let open = LogRenderer.render(document, expanded: [0], showTimestamps: false)
        let section = try! #require(open.singleToggledSection(comparedTo: collapsed))
        let lines = section.header..<section.body.upperBound
        let patched = NSMutableAttributedString(attributedString: collapsed.text)
        patched.replaceCharacters(
            in: collapsed.characterRange(ofLines: lines),
            with: open.text.attributedSubstring(from: open.characterRange(ofLines: lines))
        )
        #expect(patched.isEqual(to: open.text))
        #expect(open.singleToggledSection(comparedTo: open) == nil)
        #expect(open.singleToggledSection(comparedTo: LogRenderer.render(document, expanded: [], showTimestamps: true)) == nil)
    }

    @Test func matchRangesSkipPrefixes() {
        let rendered = LogRenderer.render(document, expanded: [0], showTimestamps: true)
        let matches = LogSearch.matches(of: "BROKE", in: document)
        #expect(matches == [LogMatch(line: 3, range: NSRange(location: 3, length: 5))])
        let range = try! #require(rendered.characterRange(of: matches[0]))
        #expect((rendered.text.string as NSString).substring(with: range) == "broke")
        #expect(rendered.text.string.hasPrefix("02:46:28.114Z  start\n02:46:28.200Z  ▾ Build\n"))
    }

    @Test(arguments: [false, true]) func findsGroupTitleRows(showTimestamps: Bool) {
        let rendered = LogRenderer.render(document, expanded: [0], showTimestamps: showTimestamps)
        #expect(rendered.lines.indices.map(rendered.isGroupTitle(row:)) == [false, true, false, false, false])
    }

    @Test func searchFindsEveryOccurrence() {
        let document = LogParser.parse("aXa\nnone\nAA")
        #expect(LogSearch.matches(of: "a", in: document).map(\.line) == [0, 0, 2, 2])
        #expect(LogSearch.matches(of: "", in: document).isEmpty)
    }

    @Test func plainTextIncludesCollapsedLines() {
        #expect(LogRenderer.plainText(document, showTimestamps: false) == "start\nBuild\ncompiling\nit broke\ndone")
    }

    @Test func arbitraryColorsStayReadable() {
        let white = LogPalette.RGB(1, 1, 1), black = LogPalette.RGB(0, 0, 0)
        #expect(LogPalette.readable(white, onDark: false).luminance < 0.45)
        #expect(LogPalette.readable(black, onDark: true).luminance > 0.45)
        #expect(LogPalette.readable(white, onDark: true) == white)
        #expect(LogPalette.readable(black, onDark: false) == black)
    }
}

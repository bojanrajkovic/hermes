import Foundation
import GitHubKit
import Testing
@testable import Hermes

@Suite struct PaletteQueryTests {
    @Test(arguments: [
        ("", PaletteQuery.empty),
        ("   ", .empty),
        ("#123", .reference(repository: nil, number: 123)),
        ("airway#95", .reference(repository: "airway", number: 95)),
        ("air #95", .reference(repository: "air", number: 95)),
        ("bojan/airway#95", .reference(repository: "bojan/airway", number: 95)),
        ("example.com#7", .reference(repository: "example.com", number: 7)),
        ("airway", .text("airway")),
        ("fix #95 later", .text("fix #95 later")),
        ("airway#", .text("airway#")),
        ("#12a", .text("#12a")),
    ])
    func parses(input: String, expected: PaletteQuery) {
        #expect(PaletteQuery(input) == expected)
    }
}

@Suite struct FuzzyScoreTests {
    @Test func rejectsWhenLettersAreMissingOrOutOfOrder() {
        #expect(fuzzyScore("xyz", in: "airway") == nil)
        #expect(fuzzyScore("yawria", in: "airway") == nil)
    }

    @Test func ignoresCase() {
        #expect(fuzzyScore("AIR", in: "airway") == fuzzyScore("air", in: "Airway"))
    }

    @Test func prefersWordStartsAndRuns() throws {
        let prefix = try #require(fuzzyScore("air", in: "airway"))
        let inside = try #require(fuzzyScore("air", in: "repair-scripts"))
        let scattered = try #require(fuzzyScore("air", in: "catnip-forks"))
        #expect(prefix > inside)
        #expect(inside > scattered)
    }

    @Test func findsTheBestStartNotTheFirst() throws {
        // The first "a" is inside "repair"; the word start in "air" is the better match.
        let late = try #require(fuzzyScore("air", in: "data-air"))
        let early = try #require(fuzzyScore("air", in: "data-xir"))
        #expect(late > early)
    }

    @Test func everyWordMustMatch() {
        #expect(fuzzyScore("query spec", in: "feat(contract): define the query spec") != nil)
        #expect(fuzzyScore("query zebra", in: "feat(contract): define the query spec") == nil)
    }

    @Test func shorterCandidateWinsATie() throws {
        let short = try #require(fuzzyScore("air", in: "air"))
        let long = try #require(fuzzyScore("air", in: "airway"))
        #expect(short > long)
    }
}

@Suite struct PaletteItemsTests {
    private var context: PaletteContext {
        PaletteContext(
            repositories: [repairScripts, airway],
            pullRequests: [pullRequest(95, title: "Give a query one canonical form"), pullRequest(7, in: repairScripts, title: "Airway notes")],
            issues: [(airway, issue(40, title: "Query links expire"))],
            sessions: [.init(id: UUID(), title: "Fix query links", subtitle: "airway#40")],
            accounts: [
                Account(kind: .personal, login: "bojan", name: "Bojan", avatarURL: URL(string: "https://example.com/a.png")!),
                Account(kind: .organization, login: "Freenode-Csharp", name: "Freenode ##csharp", avatarURL: URL(string: "https://example.com/b.png")!),
            ],
            currentAccount: "bojan",
            currentRepository: nil
        )
    }

    @Test func repositoryNameRanksAboveTitlesThatMentionIt() {
        let actions = paletteItems(for: "airway", in: context).map(\.action)
        #expect(actions.first == .repository(airway))
        #expect(actions.contains(.show(.pullRequest(ItemKey(repository: repairScripts, number: 7)))))
    }

    @Test func fuzzyRepositoryNamePicksTheBestMatchFirst() {
        #expect(paletteItems(for: "air", in: context).first?.action == .repository(airway))
    }

    @Test func referenceToALoadedPullRequestShowsIt() {
        let items = paletteItems(for: "airway#95", in: context)
        #expect(items.first?.action == .show(.pullRequest(ItemKey(repository: airway, number: 95))))
    }

    @Test func referenceToALoadedIssueShowsIt() {
        let items = paletteItems(for: "air#40", in: context)
        #expect(items.first?.action == .show(.issue(ItemKey(repository: airway, number: 40))))
    }

    @Test func referenceToAnUnloadedNumberOffersToLoadIt() {
        let items = paletteItems(for: "airway#999", in: context)
        #expect(items.first?.action == .open(ItemKey(repository: airway, number: 999)))
    }

    @Test func referenceWithAnOwnerNeedsNoLoadedRepository() {
        let items = paletteItems(for: "apple/swift#1", in: context)
        #expect(items.map(\.action) == [.open(ItemKey(repository: RepositoryRef(owner: "apple", name: "swift"), number: 1))])
    }

    @Test func bareNumberUsesTheCurrentRepository() {
        var context = context
        #expect(paletteItems(for: "#95", in: context).isEmpty)

        context.currentRepository = airway
        #expect(paletteItems(for: "#95", in: context).map(\.action) == [.show(.pullRequest(ItemKey(repository: airway, number: 95)))])
    }

    @Test func findsTitlesSessionsAndCommands() {
        let actions = paletteItems(for: "query", in: context).map(\.action)
        #expect(actions.contains(.show(.pullRequest(ItemKey(repository: airway, number: 95)))))
        #expect(actions.contains(.show(.issue(ItemKey(repository: airway, number: 40)))))
        #expect(actions.contains { if case .show(.session) = $0 { true } else { false } })

        #expect(paletteItems(for: "refresh", in: context).first?.action == .refresh)
        #expect(paletteItems(for: "freenode", in: context).first?.action == .account(login: "Freenode-Csharp"))
    }

    @Test func emptyQueryListsCommandsThenRepositories() {
        let actions = paletteItems(for: "", in: context).map(\.action)
        #expect(actions.first == .refresh)
        #expect(!actions.contains(.account(login: "bojan")))
        #expect(actions.suffix(2) == [.repository(repairScripts), .repository(airway)])
    }
}

import Foundation
import Testing
@testable import Hermes

struct WindowStateTests {
    @Test func aWindowSavedBeforeTabsWereKeptRestoresWithTheDefaults() throws {
        let saved = #"{"id":"6F1E2A4C-0000-4000-8000-000000000001","login":"octo","url":"hermes://octo/app/pull/12"}"#
        let state = try JSONDecoder().decode(WindowState.self, from: Data(saved.utf8))

        #expect(state.login == "octo")
        #expect(state.url == URL(string: "hermes://octo/app/pull/12"))
        #expect(state.tab == .files)
        #expect(state.expansion.isEmpty)
    }

    @Test func theTabAndOpenGroupsSurviveARoundTrip() throws {
        let state = WindowState(login: "octo", tab: .checks, expansion: ["stack:7": true, "repo:octo/app": false])
        let restored = try JSONDecoder().decode(WindowState.self, from: JSONEncoder().encode(state))
        #expect(restored == state)
    }
}

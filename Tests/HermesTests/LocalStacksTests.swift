import RepoKit
import Testing
@testable import Hermes

struct LocalStacksTests {
    private func branch(_ name: String, on parent: String) -> LocalStack.Branch {
        LocalStack.Branch(name: name, parent: parent)
    }

    @Test func branchesAboveFollowTheChainInStackOrder() {
        let stack = LocalStack(trunk: "main", branches: [
            branch("a", on: "main"), branch("b", on: "a"), branch("c", on: "b"),
        ])

        #expect([stack].branches(above: "a").map(\.name) == ["b", "c"])
        #expect([stack].branches(above: "c").isEmpty)
    }

    @Test func branchesAboveIncludeBothSidesOfAFork() {
        let stack = LocalStack(trunk: "main", branches: [
            branch("a", on: "main"), branch("b", on: "a"), branch("x", on: "main"), branch("c", on: "a"),
        ])

        #expect([stack].branches(above: "a").map(\.name) == ["b", "c"])
    }

    @Test func aBranchInNoStackHasNothingAbove() {
        let stack = LocalStack(trunk: "main", branches: [branch("a", on: "main")])

        #expect([stack].branches(above: "elsewhere").isEmpty)
        #expect([stack].stack(containing: "elsewhere") == nil)
        #expect([stack].stack(containing: "a") == stack)
    }
}

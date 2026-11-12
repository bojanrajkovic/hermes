import Foundation
import GitHubKit
import RepoKit
import Testing
@testable import SessionsUI

let repository = RepositoryRef(owner: "bojanrajkovic", name: "airway")
let pullRequest = SessionOrigin.pullRequest(
    repository: repository, number: 94, title: "Add retries", headRefName: "feature/retries", baseRefName: "main",
    url: URL(string: "https://github.com/bojanrajkovic/airway/pull/94")!
)
let issue = SessionOrigin.issue(
    repository: repository, number: 12, title: "Crash when the config file's missing (macOS 15)!",
    url: URL(string: "https://github.com/bojanrajkovic/airway/issues/12")!
)

@Suite struct ShellQuotingTests {
    @Test(arguments: [
        ("claude", "claude"),
        ("/usr/local/bin/claude", "/usr/local/bin/claude"),
        ("", "''"),
        ("two words", "'two words'"),
        ("it's", #"'it'\''s'"#),
        (#"say "hi""#, #"'say "hi"'"#),
        ("$HOME and `pwd`", "'$HOME and `pwd`'"),
        ("line one\nline two", "'line one\nline two'"),
        ("a;b&c|d", "'a;b&c|d'"),
        ("~/x", "'~/x'"),
        ("=cmd", "'=cmd'"),
        ("naïve", "'naïve'"),
    ])
    func quotes(word: String, expected: String) {
        #expect(shellQuoted(word) == expected)
    }

    /// The real check: `sh` reads each quoted word back as the original.
    @Test func roundTripsThroughShell() throws {
        let words = ["plain", "two words", "it's", #""double""#, "$HOME `id` $(id)", "multi\nline\n\ttext", "back\\slash", "*?[a]", "#!~"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\0' " + words.map(shellQuoted).joined(separator: " ")]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(output.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) == words)
    }
}

@Suite struct LaunchConfigurationTests {
    let directory = URL(fileURLWithPath: "/Users/me/Library/Application Support/Hermes/worktrees/o/r/b")

    @Test func localWithRemoteControlNamesTheRemoteSession() {
        let configuration = LaunchConfiguration(environment: .local(remoteControl: true), name: "airway#94 Add retries", prompt: "Do it", directory: nil)
        #expect(configuration.arguments == ["--remote-control", "airway#94 Add retries", "--", "Do it"])
    }

    @Test func localWithoutRemoteControlUsesName() {
        let configuration = LaunchConfiguration(environment: .local(remoteControl: false), permissionMode: .plan, name: "n", prompt: "p", directory: nil)
        #expect(configuration.arguments == ["--name", "n", "--permission-mode", "plan", "--", "p"])
    }

    @Test func claudeAppLinkCarriesTheFolderAndThePrompt() throws {
        let local = LaunchConfiguration(
            environment: .local(remoteControl: true), name: "n", prompt: "Fix a & b + c;\nthen stop",
            directory: URL(filePath: "/tmp/work trees/x")
        )
        let url = try #require(local.claudeAppURL)
        #expect(url.absoluteString.hasPrefix("claude://code/new?folder=/tmp/work%20trees/x&q="))
        // The prompt survives a round trip through a query parser.
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "q" }?.value == "Fix a & b + c;\nthen stop")
        #expect(!url.absoluteString.contains("+"))

        // Without a folder there is nothing to open locally.
        #expect(LaunchConfiguration(environment: .local(remoteControl: false), name: "n", prompt: "p", directory: nil).claudeAppURL == nil)
    }

    @Test func claudeAppLinkNamesACloudEnvironmentOrARunnerPool() throws {
        func link(_ id: String) -> String? {
            LaunchConfiguration(environment: .cloud(CloudEnvironment(id: id, name: "x")), name: "n", prompt: "", directory: nil)
                .claudeAppURL?.absoluteString
        }
        #expect(link("env_01abc") == "claude://code/new?environment=env_01abc")
        #expect(link("ccpool_01abc") == "claude://code/new?runner_pool=ccpool_01abc")
    }

    @Test func emptyPromptIsLeftOut() {
        let configuration = LaunchConfiguration(environment: .local(remoteControl: true), permissionMode: .acceptEdits, name: "n", prompt: " \n", directory: nil)
        #expect(configuration.arguments == ["--remote-control", "n", "--permission-mode", "acceptEdits"])
    }

    /// `--remote-control` takes an optional name, and a bullet-list prompt starts with "-".
    @Test func promptIsSeparatedFromTheOptions() {
        let configuration = LaunchConfiguration(environment: .local(remoteControl: true), name: "", prompt: "- fix a\n- fix b", directory: nil)
        #expect(configuration.arguments == ["--remote-control", "--", "- fix a\n- fix b"])
    }

    @Test func cloudUsesEnvironmentIDOnly() {
        let configuration = LaunchConfiguration(
            environment: .cloud(CloudEnvironment(id: "ccpool_01Ab", name: "Big box")), permissionMode: .plan, name: "n", prompt: "p", directory: nil
        )
        #expect(configuration.arguments == ["--environment", "ccpool_01Ab", "--", "p"])
    }

    @Test func commandLineQuotesDirectoryAndPrompt() {
        let configuration = LaunchConfiguration(
            environment: .local(remoteControl: false), name: "n", prompt: "Fix \"it\"\nfor $5", directory: directory
        )
        #expect(configuration.commandLine() == """
            cd '/Users/me/Library/Application Support/Hermes/worktrees/o/r/b' && claude --name n -- 'Fix "it"
            for $5'
            """)
        #expect(configuration.commandLine(executable: "/opt/bin/claude").contains("&& /opt/bin/claude --name"))
    }

    @Test func commandLineWithoutDirectoryHasNoCd() {
        let configuration = LaunchConfiguration(environment: .local(remoteControl: false), name: "n", prompt: "", directory: nil)
        #expect(configuration.commandLine() == "claude --name n")
    }
}

@Suite struct OriginTests {
    @Test func pullRequestPromptNamesURLAndBranch() {
        #expect(pullRequest.defaultPrompt.contains("https://github.com/bojanrajkovic/airway/pull/94"))
        #expect(pullRequest.defaultPrompt.contains("`feature/retries`"))
        #expect(pullRequest.branchName == "feature/retries")
    }

    @Test func issuePromptAsksForFixesLine() {
        #expect(issue.defaultPrompt.contains("https://github.com/bojanrajkovic/airway/issues/12"))
        #expect(issue.defaultPrompt.contains(#""Fixes #12""#))
    }

    @Test(arguments: [
        ("Crash when the config file's missing (macOS 15)!", "issue-12-crash-when-the-config-file"),
        ("Fix", "issue-12-fix"),
        ("🔥🔥", "issue-12"),
        ("Internationalization: überlange Wörter", "issue-12-internationalization-berlange-w-rter"),
        ("supercalifragilisticexpialidocious-and-then-some more", "issue-12-supercalifragilisticexpialidocious-and-t"),
    ])
    func issueBranchNames(title: String, expected: String) {
        #expect(issueBranchName(number: 12, title: title) == expected)
    }

    @Test func longSessionNameIsTruncated() {
        let long = SessionOrigin.issue(repository: repository, number: 1, title: String(repeating: "word ", count: 30), url: issue.url)
        #expect(long.defaultSessionName.count <= 60)
        #expect(long.defaultSessionName.hasSuffix("…"))
        #expect(pullRequest.defaultSessionName == "airway#94 Add retries")
    }
}

@Suite struct WorkspacePlanTests {
    let checkout = Checkout(repo: RepoID(owner: "bojanrajkovic", name: "airway"), directory: URL(fileURLWithPath: "/src/airway"))
    let root = URL(fileURLWithPath: "/worktrees")

    @Test func newWorktreeGoesUnderRootWithSlashesFlattened() throws {
        let plan = try planWorkspace(origin: pullRequest, checkout: checkout, existing: nil, root: root)
        #expect(plan.directory.path == "/worktrees/bojanrajkovic/airway/feature-retries")
        #expect(!plan.exists)
        #expect(plan.branch == "feature/retries")
    }

    @Test func existingWorktreeOfTheBranchIsReused() throws {
        let linked = URL(fileURLWithPath: "/elsewhere/retries")
        let plan = try planWorkspace(origin: pullRequest, checkout: checkout, existing: (linked, false), root: root)
        #expect(plan.directory == linked)
        #expect(plan.exists)
    }

    @Test func branchInMainWorkingCopyIsRefused() {
        #expect(throws: WorkspaceError.branchInMainWorkingCopy(branch: "feature/retries", directory: checkout.directory)) {
            try planWorkspace(origin: pullRequest, checkout: checkout, existing: (checkout.directory, true), root: root)
        }
    }

    @Test func missingRemoteBranchReadsAsForkHint() {
        let failure = GitError.failed(arguments: ["fetch"], status: 128, stderr: "fatal: couldn't find remote ref refs/heads/feature/retries\n")
        #expect(worktreeError(failure, branch: "feature/retries", remote: "origin") as? WorkspaceError
            == .branchNotOnRemote(branch: "feature/retries", remote: "origin"))
        let other = GitError.failed(arguments: ["worktree"], status: 128, stderr: "fatal: something else")
        #expect(worktreeError(other, branch: "b", remote: "origin") as? GitError == other)
    }
}

@Suite struct ShellPathTests {
    @Test func pathIsReadBetweenMarkers() {
        let output = "Welcome to fish\n\(Shell.marker)\n/opt/homebrew/bin:/usr/bin\n\(Shell.marker)\nbye\n"
        #expect(parseMarkedPath(output) == "/opt/homebrew/bin:/usr/bin")
    }

    @Test(arguments: ["", "/usr/bin\n", "\(Shell.marker)\n\(Shell.marker)\n", "\(Shell.marker)\n\n\(Shell.marker)\n"])
    func outputWithoutAPathIsRejected(output: String) {
        #expect(parseMarkedPath(output) == nil)
    }

    /// A shell startup file can leave a background process holding the pipes.
    @Test func timeoutEndsTheReadWhenABackgroundProcessHoldsThePipe() async throws {
        let start = ContinuousClock.now
        let output = try await Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 6 & echo hi"], timeout: .seconds(1))
        #expect(output.stdout == "hi\n")
        #expect(ContinuousClock.now - start < .seconds(4))
    }
}

@MainActor
@Suite struct SettingsTests {
    @Test func environmentsAndRootsPersist() throws {
        let suite = "hermes-sessions-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SessionSettings(defaults: defaults)
        #expect(settings.cloudEnvironments.isEmpty)
        #expect(settings.searchRoots == CheckoutFinder.defaultRoots)

        settings.cloudEnvironments = [CloudEnvironment(id: "ccpool_1", name: "One")]
        settings.cloudEnvironments[0].name = "Renamed"
        settings.searchRoots = [URL(fileURLWithPath: "/src", isDirectory: true)]

        let reloaded = SessionSettings(defaults: defaults)
        #expect(reloaded.cloudEnvironments == [CloudEnvironment(id: "ccpool_1", name: "Renamed")])
        #expect(reloaded.searchRoots.map(\.path) == ["/src"])
    }

    @Test(arguments: [
        ("ccpool_01AbC-d_e", true), ("ccpool_", false), ("pool_abc", false), ("ccpool_ab c", false), (" ccpool_abc", false), ("", false),
    ])
    func environmentIDShape(id: String, valid: Bool) {
        #expect(CloudEnvironment.isValidID(id) == valid)
    }

    @Test func addingADuplicateOrUnnamedEnvironmentIsRefused() throws {
        let suite = "hermes-sessions-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SessionSettings(defaults: defaults)
        settings.cloudEnvironments = [CloudEnvironment(id: "ccpool_1", name: "One")]

        #expect(settings.problem(addingEnvironment: "ccpool_2", name: "Two") == nil)
        #expect(settings.problem(addingEnvironment: "ccpool_1", name: "Again") != nil)
        #expect(settings.problem(addingEnvironment: "ccpool_2", name: "  ") != nil)
        #expect(settings.problem(addingEnvironment: "nope", name: "Two") != nil)
    }
}

@MainActor
@Suite struct ClaudeAppSessionTests {
    @Test func aSessionInTheClaudeAppHasNoTerminalAndNeverCountsAsRunning() {
        let session = ClaudeSession(
            origin: pullRequest, title: "In the app", environment: .local(remoteControl: false),
            workingDirectory: nil, branch: "feature", baseRef: "origin/main",
            commandLine: "open claude://code/new", runner: .claudeApp(URL(string: "claude://code/new")!), checkout: nil
        )

        #expect(session.state == .inClaudeApp)
        #expect(session.terminal == nil)
        // Closing it ends nothing, so its state stays.
        session.terminate()
        #expect(session.state == .inClaudeApp)
    }
}

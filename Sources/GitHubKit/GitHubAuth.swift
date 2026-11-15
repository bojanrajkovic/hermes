import Foundation
import os

/// Reads the GitHub token from the `gh` command line tool.
public enum GitHubAuth {
    /// Runs `gh auth token` and returns the token for github.com.
    ///
    /// `gh` is looked up in `/opt/homebrew/bin` and `/usr/local/bin`, then by
    /// asking the user's login shell, because an app started from Finder has a
    /// minimal `PATH`.
    ///
    /// - Throws: `GitHubError.ghNotInstalled` when `gh` is not found.
    ///   `GitHubError.ghNotLoggedIn` when `gh` exits with an error or prints
    ///   no token.
    public static func token() async throws -> String {
        guard let gh = await locateGH() else { throw GitHubError.ghNotInstalled }
        guard let result = try? await run(gh, ["auth", "token"]) else { throw GitHubError.ghNotInstalled }

        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !token.isEmpty else {
            throw GitHubError.ghNotLoggedIn(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return token
    }

    /// The scopes of the token `gh` holds now, read again on each call because
    /// `gh auth refresh` changes them. Empty when they cannot be read, and for a
    /// fine-grained token, which has none.
    public static func scopes(session: URLSession = .shared) async -> Set<String> {
        guard let token = try? await token() else { return [] }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request) else { return [] }
        return scopes(inHeader: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-OAuth-Scopes"))
    }

    /// The scopes in GitHub's `X-OAuth-Scopes` header, such as `repo, admin:org`.
    static func scopes(inHeader header: String?) -> Set<String> {
        Set((header ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    static func locateGH() async -> URL? {
        let files = FileManager.default
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where files.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // Interactive as well as login: version managers such as mise set PATH in .zshrc.
        let shell = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        guard let result = try? await run(shell, ["-ilc", "command -v gh"]) else { return nil }
        // The shell's startup files may print before the answer, so take the last path.
        let path = result.stdout.split(whereSeparator: \.isNewline).last { $0.hasPrefix("/") }
        guard let path, files.isExecutableFile(atPath: String(path)) else { return nil }
        return URL(fileURLWithPath: String(path))
    }

    /// Runs a program and collects its output.
    ///
    /// The program is killed after `timeout` seconds, so a shell whose startup
    /// files wait for input cannot stall the caller forever.
    // shortcut: a background process the program leaves behind keeps the pipes
    // open and stalls the read; upgrade to non-blocking reads if that shows up.
    static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 20
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // SIGKILL, because an interactive shell ignores SIGTERM.
                let pid = process.processIdentifier
                let kill = DispatchWorkItem { Darwin.kill(pid, SIGKILL) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)

                // Both pipes are read at once: a program that fills one pipe's
                // buffer blocks until someone reads it.
                let err = OSAllocatedUnfairLock(initialState: Data())
                let stderrRead = DispatchGroup()
                let stderrHandle = stderr.fileHandleForReading
                DispatchQueue.global().async(group: stderrRead) {
                    let data = stderrHandle.readDataToEndOfFile()
                    err.withLock { $0 = data }
                }
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                stderrRead.wait()
                process.waitUntilExit()
                kill.cancel()

                continuation.resume(returning: (
                    process.terminationStatus,
                    String(decoding: out, as: UTF8.self),
                    String(decoding: err.withLock { $0 }, as: UTF8.self)
                ))
            }
        }
    }
}

import Foundation

/// Running helper processes and finding the user's tools.
///
/// A GUI app starts with a minimal `PATH`, so `claude`, `gh`, and `git` are
/// looked up on the `PATH` of the user's login shell, read once per run.
enum Shell {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// The user's `PATH`, with the standard locations appended.
    static let path: Task<String, Never> = Task.detached {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Interactive as well as login: version managers often set PATH in the rc file.
        let output = try? await run(
            URL(fileURLWithPath: shell),
            ["-l", "-i", "-c", "echo \(marker); /usr/bin/printenv PATH; echo \(marker)"],
            timeout: .seconds(10)
        )
        let captured = output.flatMap { parseMarkedPath($0.stdout) } ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        // The two home folders are where Claude Code installs itself; an
        // install reached through a shell alias is not on the PATH.
        let home = NSHomeDirectory()
        return captured + ":\(home)/.local/bin:\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    static let marker = "__HERMES_PATH__"

    /// The first executable named `name` on the user's `PATH`.
    static func find(_ name: String) async -> URL? {
        await path.value.split(separator: ":").lazy
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs a process to completion with the user's `PATH` and no stdin.
    ///
    /// - Parameter timeout: The process is terminated after this long.
    /// - Throws: If the process cannot be started.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                        if process.isRunning { process.terminate() }
                        // A background process the child started can hold the pipes open
                        // after the child exits. Closing ends the reads with what arrived.
                        try? stdout.fileHandleForReading.close()
                        try? stderr.fileHandleForReading.close()
                    }
                }
                // Both pipes are drained at once, or a full stderr pipe would block the child.
                nonisolated(unsafe) var errorData = Data()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) {
                    errorData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                }
                let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: data, as: UTF8.self),
                    stderr: String(decoding: errorData, as: UTF8.self)
                ))
            }
        }
    }
}

/// The `PATH` printed between two marker lines. Shell startup files can print
/// anything before and after, so only the line between the markers counts.
func parseMarkedPath(_ output: String) -> String? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(of: Shell.marker),
          let end = lines[(start + 1)...].firstIndex(of: Shell.marker), end == start + 2 else { return nil }
    let path = lines[start + 1].trimmingCharacters(in: .whitespaces)
    return path.isEmpty ? nil : path
}

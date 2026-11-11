import Foundation

/// A saved cloud environment that `claude --environment <id>` can run a session on.
public struct CloudEnvironment: Identifiable, Hashable, Codable, Sendable {
    /// The environment ID, such as `ccpool_01AbC`.
    public let id: String
    /// The name shown in pickers.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Whether `id` has the shape of an environment ID: `ccpool_` (a
    /// self-hosted runner pool) or `env_` (a cloud environment) followed by
    /// letters, digits, `_`, or `-`. The `claude` command line takes only
    /// `ccpool_` IDs; the Claude app takes both.
    public static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: /(ccpool|env)_[A-Za-z0-9_-]+/) != nil
    }
}

/// Where a session runs.
public enum SessionEnvironment: Hashable, Sendable {
    /// `claude` on this Mac. With `remoteControl` the session is also
    /// reachable from claude.ai and the Claude mobile app.
    case local(remoteControl: Bool)
    /// A cloud session on a saved environment.
    case cloud(CloudEnvironment)
}

/// The values `claude --permission-mode` accepts, plus `default`, which
/// passes no flag and leaves the mode to the user's Claude Code settings.
public enum PermissionMode: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case manual
    case acceptEdits
    case plan
    case auto
    case dontAsk
    case bypassPermissions

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .default: "Default"
        case .manual: "Ask for Permission"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan"
        case .auto: "Auto"
        case .dontAsk: "Don't Ask"
        case .bypassPermissions: "Bypass Permissions"
        }
    }
}

/// Everything that decides the command line of a session.
public struct LaunchConfiguration: Hashable, Sendable {
    public var environment: SessionEnvironment
    /// Applies to local sessions only.
    public var permissionMode: PermissionMode
    /// The session's display name. For a local session with Remote Control it
    /// is also the name shown on claude.ai.
    public var name: String
    /// The first message sent to Claude. Empty starts an idle session.
    public var prompt: String
    /// The directory the command runs in.
    public var directory: URL?

    public init(
        environment: SessionEnvironment,
        permissionMode: PermissionMode = .default,
        name: String,
        prompt: String,
        directory: URL?
    ) {
        self.environment = environment
        self.permissionMode = permissionMode
        self.name = name
        self.prompt = prompt
        self.directory = directory
    }

    /// The arguments after `claude`.
    public var arguments: [String] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String] = []

        switch environment {
        case let .local(remoteControl):
            if remoteControl {
                arguments += ["--remote-control"] + (name.isEmpty ? [] : [name])
            } else if !name.isEmpty {
                arguments += ["--name", name]
            }
            if permissionMode != .default {
                arguments += ["--permission-mode", permissionMode.rawValue]
            }
        case let .cloud(environment):
            arguments += ["--environment", environment.id]
        }

        // "--" ends the options. Without it a prompt that starts with "-",
        // such as a bullet list, is parsed as an option, and an unnamed
        // `--remote-control [name]` takes the prompt as its name.
        return arguments + (prompt.isEmpty ? [] : ["--", prompt])
    }

    /// A link that opens the Claude desktop app on its new-session screen with
    /// this session's folder or environment and its prompt filled in. The
    /// user picks or confirms the environment there, including a Remote
    /// Control host, which the link cannot name.
    ///
    /// The parameters are the ones the Claude app's `claude://code/new`
    /// handler reads. They are not documented.
    public var claudeAppURL: URL? {
        var items: [URLQueryItem] = []
        switch environment {
        case .local:
            guard let directory else { return nil }
            items.append(URLQueryItem(name: "folder", value: directory.path))
        case let .cloud(environment):
            // Self-hosted runner pools and cloud environments are separate parameters.
            items.append(URLQueryItem(name: environment.id.hasPrefix("ccpool_") ? "runner_pool" : "environment", value: environment.id))
        }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { items.append(URLQueryItem(name: "q", value: prompt)) }

        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = items
        // URLComponents leaves "+" and ";" in a value as they are; a query parser reads "+" as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: ";", with: "%3B")
        return components.url
    }

    /// The command as one line for a POSIX shell: `cd <directory> && claude …`,
    /// with every word quoted as needed.
    ///
    /// - Parameter executable: The `claude` binary. The embedded terminal
    ///   passes an absolute path because it does not run the user's shell.
    public func commandLine(executable: String = "claude") -> String {
        let command = ([executable] + arguments).map(shellQuoted).joined(separator: " ")
        guard let directory else { return command }
        return "cd \(shellQuoted(directory.path)) && \(command)"
    }
}

/// Quotes one word for a POSIX shell. Words made only of characters no shell
/// treats specially are returned as they are; anything else is wrapped in
/// single quotes, where spaces, `$`, `"`, and newlines are literal.
public func shellQuoted(_ word: String) -> String {
    let isPlain = !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_-./:@+,".unicodeScalars.contains(scalar))
    }
    return isPlain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

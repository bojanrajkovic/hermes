import Foundation
import GitHubKit
import HermesUI
import RepoKit
import SessionsUI

/// What every window shares: the signed-in user, each account's data, Claude
/// sessions, and settings. Each window has its own `WindowModel` on top.
@Observable
@MainActor
final class AppStore {
    enum Startup: Equatable {
        case loading
        case failed(StartupProblem)
        case ready(ViewerProfile)
    }

    let client: GitHubClient
    let repoCache: RepoCache
    let sessions: SessionStore
    let checkouts = CheckoutFinder()
    private let defaults: UserDefaults

    private(set) var startup: Startup = .loading
    // Filled in while a view reads it, so it is not observed. The entries are, and an entry is never replaced.
    @ObservationIgnored private var accounts: [String: AccountData] = [:]

    var viewer: ViewerProfile? {
        if case .ready(let viewer) = startup { viewer } else { nil }
    }

    /// The account a new window shows: the one picked last in any window.
    var lastLogin: String? {
        get { defaults.string(forKey: Keys.account) }
        set { defaults.set(newValue, forKey: Keys.account) }
    }

    var showingAllBots: Bool {
        didSet { defaults.set(showingAllBots, forKey: Keys.showingAllBots) }
    }
    /// Seconds between automatic reloads of the lists.
    var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    private enum Keys {
        static let account = "selectedAccount"
        static let showingAllBots = "showingAllBots"
        static let refreshInterval = "refreshInterval"
    }

    init(
        client: GitHubClient = GitHubClient(), repoCache: RepoCache = RepoCache(),
        sessions: SessionStore = SessionStore(), defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.repoCache = repoCache
        self.sessions = sessions
        self.defaults = defaults
        showingAllBots = defaults.bool(forKey: Keys.showingAllBots)
        let interval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = interval > 0 ? interval : 60
    }

    /// Loads the signed-in user once. Windows that open later reuse it.
    func start() async {
        startup = .loading
        do {
            let viewer = try await client.viewer()
            startup = .ready(viewer)
            for account in viewer.accounts {
                Task { _ = await AvatarCache.shared.image(for: account.avatarURL) }
            }
        } catch {
            startup = .failed(StartupProblem(error))
        }
    }

    /// The account with this login, when the viewer has it.
    func account(_ login: String?) -> Account? {
        viewer?.accounts.first { $0.login.caseInsensitiveCompare(login ?? "") == .orderedSame }
    }

    /// One account's data, made on first use. An empty login is the data of a window with no account yet.
    func data(for login: String) -> AccountData {
        if let data = accounts[login] { return data }
        let data = AccountData(login: login, client: client)
        accounts[login] = data
        return data
    }
}

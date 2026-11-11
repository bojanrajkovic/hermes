import Foundation
import Observation
import RepoKit

/// Session preferences, kept in `UserDefaults`: the saved cloud environments
/// and the folders searched for local checkouts.
@Observable
@MainActor
public final class SessionSettings {
    /// The instance the app's views share.
    public static let shared = SessionSettings()

    public var cloudEnvironments: [CloudEnvironment] {
        didSet { defaults.set(try? JSONEncoder().encode(cloudEnvironments), forKey: Keys.cloudEnvironments) }
    }

    /// Folders searched, two levels deep, for the user's clones.
    public var searchRoots: [URL] {
        didSet { defaults.set(searchRoots.map(\.path), forKey: Keys.searchRoots) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cloudEnvironments = defaults.data(forKey: Keys.cloudEnvironments)
            .flatMap { try? JSONDecoder().decode([CloudEnvironment].self, from: $0) } ?? []
        searchRoots = defaults.stringArray(forKey: Keys.searchRoots)?
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? CheckoutFinder.defaultRoots
    }

    /// Why `id` and `name` cannot be saved as a new environment, or `nil` if they can.
    public func problem(addingEnvironment id: String, name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the environment a name." }
        if !CloudEnvironment.isValidID(id) { return "An environment ID looks like ccpool_01AbCdEf." }
        if cloudEnvironments.contains(where: { $0.id == id }) { return "That environment is already saved." }
        return nil
    }

    private enum Keys {
        static let cloudEnvironments = "sessions.cloudEnvironments"
        static let searchRoots = "sessions.searchRoots"
    }
}

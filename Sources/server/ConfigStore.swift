import Foundation
import IndexerCore

/// Holds the server's current configuration and reloads it from disk on demand,
/// so config.json / config.local.json edits take effect without a restart.
/// Hot-applied: auth credentials and anything read per-request (AskService's
/// LM Studio / model settings). NOT hot-applied (need a restart): bind address,
/// target chat id, and db paths — those are bound at startup.
actor ConfigStore {
    private(set) var current: Config
    private let path: String?

    init(path: String?, initial: Config) {
        self.path = path
        self.current = initial
    }

    /// Re-read config from disk (config.json overlaid with config.local.json).
    /// Returns true if the reload succeeded.
    @discardableResult
    func reload() -> Bool {
        guard let fresh = try? Config.resolveAndLoad(path) else { return false }
        current = fresh
        return true
    }

    var credentials: (user: String, password: String) {
        (current.authUser, current.authPassword)
    }
}

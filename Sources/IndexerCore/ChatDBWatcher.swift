import Foundation

/// Watches Apple's chat.db for writes so the indexer can react within seconds
/// instead of waiting for a poll. Monitors the `-wal` file (where Messages writes
/// land first) via a DispatchSource vnode source, debounces bursts, and re-arms
/// when the WAL is checkpointed/recreated (delete/rename).
public final class ChatDBWatcher: @unchecked Sendable {
    private let walPath: String
    private let dbPath: String
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    private let queue = DispatchQueue(label: "net.phfactor.imessage.chatdb-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pending: DispatchWorkItem?

    public init(chatDBPath: String, debounce: TimeInterval = 3,
                onChange: @escaping @Sendable () -> Void) {
        let expanded = (chatDBPath as NSString).expandingTildeInPath
        self.dbPath = expanded
        self.walPath = expanded + "-wal"
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() { queue.async { [weak self] in self?.arm() } }

    public func stop() {
        queue.async { [weak self] in
            self?.pending?.cancel()
            self?.source?.cancel()
            self?.source = nil
        }
    }

    // MARK: - private (all on `queue`)

    private func arm() {
        source?.cancel()
        source = nil
        // Prefer the -wal file; fall back to the db file if the WAL isn't present.
        let target = FileManager.default.fileExists(atPath: walPath) ? walPath : dbPath
        let f = open(target, O_EVTONLY)
        guard f >= 0 else {
            // File not there yet — retry shortly.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
            return
        }
        fd = f
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: f,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .link],
            queue: queue)
        src.setEventHandler { [weak self] in self?.handle() }
        src.setCancelHandler { close(f) }
        source = src
        src.resume()
    }

    private func handle() {
        let flags = source?.data ?? []
        scheduleFire()
        // WAL was checkpointed away / rotated → reopen on the new file.
        if !flags.isDisjoint(with: [.delete, .rename, .revoke]) {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.arm() }
        }
    }

    private func scheduleFire() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}

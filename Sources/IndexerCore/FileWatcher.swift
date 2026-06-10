import Foundation

/// Watches a single file for changes via a DispatchSource vnode source, debounces
/// bursts, and re-arms when the file is replaced (editors often save by writing a
/// temp file and renaming over the original → delete/rename events).
public final class FileWatcher: @unchecked Sendable {
    private let path: String
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    private let queue = DispatchQueue(label: "net.phfactor.imessage.file-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(path: String, debounce: TimeInterval = 0.5,
                onChange: @escaping @Sendable () -> Void) {
        self.path = (path as NSString).expandingTildeInPath
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

    // MARK: - private (on `queue`)

    private func arm() {
        source?.cancel()
        source = nil
        let f = open(path, O_EVTONLY)
        guard f >= 0 else {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }  // file not there yet
            return
        }
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
        if !flags.isDisjoint(with: [.delete, .rename, .revoke]) {
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.arm() }  // reopen the replacement
        }
    }

    private func scheduleFire() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}

import Foundation

/// Watches a single config file and invokes `onChange` (debounced) whenever it is written,
/// replaced, or recreated. Handles the two common save styles: in-place writes (a `.write`
/// on the existing inode) and atomic saves (a temp file renamed over the target, which
/// deletes the watched inode). After every event the file descriptor is re-established on
/// whatever now lives at the path, so the watch survives atomic saves indefinitely.
///
/// This is UI-layer plumbing (DispatchSource + timers), so it is not unit-tested; the
/// reload it triggers (`AppModel.refresh`) is covered separately.
@MainActor
final class ConfigFileWatcher {
    private let url: URL
    private let debounce: DispatchTimeInterval
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pendingReload: DispatchWorkItem?
    /// Poll interval used only while the file does not exist yet (e.g. before the first
    /// repository is registered, which creates the config).
    private let missingFileRetry: DispatchTimeInterval = .seconds(2)
    private var isStopped = false

    init(url: URL, debounce: DispatchTimeInterval = .milliseconds(150), onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        isStopped = false
        arm()
    }

    func stop() {
        isStopped = true
        pendingReload?.cancel()
        pendingReload = nil
        source?.cancel() // the cancel handler closes the descriptor
        source = nil
    }

    /// (Re)open the file and install a vnode source. If the file is missing, retry later.
    private func arm() {
        guard !isStopped, source == nil else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRetry()
            return
        }
        fileDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.handleEvent() }
        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        self.source = source
        source.resume()
    }

    private func handleEvent() {
        // An atomic save replaces the inode, so the current descriptor is now stale: tear
        // it down and re-arm on the new file once the burst settles. Debounce coalesces a
        // flurry of writes into a single reload.
        source?.cancel()
        source = nil

        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.onChange()
            self.arm()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func scheduleRetry() {
        guard !isStopped else { return }
        let work = DispatchWorkItem { [weak self] in self?.arm() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + missingFileRetry, execute: work)
    }
}

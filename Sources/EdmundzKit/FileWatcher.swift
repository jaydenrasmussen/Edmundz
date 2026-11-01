import Foundation

/// Event-driven watcher for one file (no polling). Editors and sync tools usually replace a file atomically, which retires the
/// watched inode, so the source is re-armed on the new file after every event.
final class FileWatcher {
    private let url: URL
    private let handler: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var stopped = false

    init(url: URL, handler: @escaping () -> Void) {
        self.url = url
        self.handler = handler
        arm()
    }

    deinit { stop() }

    func stop() {
        stopped = true
        debounce?.cancel()
        source?.cancel(); source = nil
    }

    private func arm() {
        source?.cancel(); source = nil
        guard !stopped else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // the file is momentarily missing (atomic replace in flight): try again shortly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.arm() }
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main)
        s.setEventHandler { [weak self] in self?.changed() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func changed() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.arm()          // the inode may have been replaced
            self.handler()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

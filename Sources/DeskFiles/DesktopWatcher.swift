import CoreServices
import DeskCore
import Foundation

/// Watches the desktop folder with FSEvents and delivers a fresh `DesktopSnapshot` after each burst of
/// changes (DESIGN §3.1 item 4).
///
/// Stream flags: `FileEvents | UseCFTypes | UseExtendedData | WatchRoot`, latency 0.25 s, on a private
/// dispatch queue. Every relevant batch (re)arms a 250 ms debounce, capped at `maxDelay` so a long burst still
/// produces snapshots; then the folder is rescanned. `RootChanged` restarts the stream and rescans at once.
/// Changes deeper than the top level are ignored. The handler runs on the watcher's queue; hop to the main
/// actor yourself. Call `stop()` when done (a running stream keeps the watcher alive).
public final class DesktopWatcher: @unchecked Sendable {
    public enum Event: Sendable {
        case snapshot(DesktopSnapshot)
        case failed(DesktopScanner.Failure)
    }

    public let scanner: DesktopScanner
    public let latency: TimeInterval
    public let debounce: TimeInterval
    public let maxDelay: TimeInterval

    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "deskterior.desktop-watcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let watchedPath: String
    private let matchPrefix: String

    // Confined to `queue`.
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var firstPending: DispatchTime?
    private var running = false

    /// Extended-data dictionary keys (`kFSEventStreamEventExtendedDataPathKey`, `…ExtendedFileIDKey`).
    static let pathKey = "path"
    static let fileIDKey = "fileID"

    public init(
        scanner: DesktopScanner, latency: TimeInterval = 0.25, debounce: TimeInterval = 0.25, maxDelay: TimeInterval = 1,
        handler: @escaping @Sendable (Event) -> Void
    ) {
        self.scanner = scanner
        self.latency = latency
        self.debounce = debounce
        self.maxDelay = max(debounce, maxDelay)
        self.handler = handler
        watchedPath = DesktopLocator.canonicalPath(scanner.root)
        matchPrefix = Self.normalized(watchedPath)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        onQueue { teardown() }
    }

    /// Starts watching; with `initialScan`, delivers a snapshot right away.
    public func start(initialScan: Bool = true) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            createStream()
            if initialScan { runScan() }
        }
    }

    /// Stops watching. Safe from any thread, including the handler.
    public func stop() {
        onQueue {
            running = false
            teardown()
        }
    }

    /// Rescans now (wake, session active, user request), cancelling a pending debounce.
    public func rescanNow() {
        queue.async { [self] in
            guard running else { return }
            runScan()
        }
    }

    // MARK: Queue-confined

    private func createStream() {
        let box = CallbackBox(self)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagWatchRoot
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, [watchedPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return
        }
        stream = s
    }

    private func teardown() {
        pending?.cancel()
        pending = nil
        firstPending = nil
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    fileprivate func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        guard running else { return }
        let rootChanged = UInt32(kFSEventStreamEventFlagRootChanged)
        if events.contains(where: { $0.flags & rootChanged != 0 }) {
            teardown()
            createStream()
            runScan()
            return
        }
        if events.contains(where: isRelevant) { scheduleScan() }
    }

    private func isRelevant(_ event: (path: String, flags: FSEventStreamEventFlags)) -> Bool {
        Self.isRelevant(path: event.path, flags: event.flags, root: matchPrefix)
    }

    /// Top-level changes, the root itself, dropped events and paths we cannot place all count; changes inside
    /// subfolders do not. `root` is the NFC, lowercased canonical root path.
    static func isRelevant(path: String, flags: FSEventStreamEventFlags, root: String) -> Bool {
        let rescanFlags = UInt32(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        if flags & rescanFlags != 0 || path.isEmpty { return true }
        let p = normalized(path)
        if p == root { return true }
        guard p.hasPrefix(root + "/") else { return true }
        return !p.dropFirst(root.count + 1).contains("/")
    }

    private func scheduleScan() {
        let now = DispatchTime.now()
        let first = firstPending ?? now
        firstPending = first
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.runScan() }
        pending = item
        queue.asyncAfter(deadline: min(now + debounce, first + maxDelay), execute: item)
    }

    private func runScan() {
        pending?.cancel()
        pending = nil
        firstPending = nil
        do throws(DesktopScanner.Failure) {
            handler(.snapshot(try scanner.scan()))
        } catch {
            handler(.failed(error))
        }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private static func normalized(_ path: String) -> String {
        TextLayout.nfc(path).lowercased()
    }

    /// The C callback: unpacks `UseCFTypes | UseExtendedData` paths (an array of dictionaries).
    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        guard let watcher = box.watcher else { return }
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var events: [(path: String, flags: FSEventStreamEventFlags)] = []
        events.reserveCapacity(count)
        for i in 0..<min(count, array.count) {
            let item = array[i]
            let path = (item as? NSDictionary)?[DesktopWatcher.pathKey] as? String ?? (item as? String) ?? ""
            events.append((path, flags[i]))
        }
        watcher.handle(events)
    }
}

/// What the FSEvents context retains: a weak link back, so a forgotten watcher can still deallocate.
private final class CallbackBox: @unchecked Sendable {
    weak var watcher: DesktopWatcher?

    init(_ watcher: DesktopWatcher) { self.watcher = watcher }
}

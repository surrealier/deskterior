import DeskCore
import Foundation

/// Watches the desktop folder (FSEvents on macOS, `ReadDirectoryChangesW` on Windows, inotify on Linux:
/// `DesktopChangeSource`) and delivers a fresh `DesktopSnapshot` after each burst of
/// changes (DESIGN §3.1 item 4).
///
/// Stream flags: `FileEvents | UseCFTypes | UseExtendedData | WatchRoot`, latency 0.25 s, on a private
/// dispatch queue. Every relevant batch (re)arms a 250 ms debounce, capped at `maxDelay` (stretched to twice
/// the last scan's duration on big folders) so a long burst still produces snapshots; then the folder is
/// rescanned. `RootChanged` restarts the stream and rescans at once. Changes deeper than the top level are
/// ignored. Snapshots are marked `continuous` when they follow the previous one with nothing missed in between.
/// A stream that cannot start is reported as a failure and retried. The handler runs on the watcher's queue;
/// hop to the main actor yourself. Call `stop()` when done (a running stream keeps the watcher alive).
public final class DesktopWatcher: @unchecked Sendable {
    public enum Event: Sendable {
        case snapshot(DesktopSnapshot)
        case failed(DesktopScanner.Failure)
    }

    public let scanner: DesktopScanner
    public let latency: TimeInterval
    public let debounce: TimeInterval
    public let maxDelay: TimeInterval

    /// Seconds between attempts to start a stream that failed.
    public static let retryDelay: TimeInterval = 2

    private let handler: @Sendable (Event) -> Void
    /// Closed by `stop()`: nothing is delivered after it returns, without waiting for a scan in flight.
    private let gate = NSRecursiveLock()
    private var open = false
    private let queue = DispatchQueue(label: "deskterior.desktop-watcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let watchedPath: String
    let matchPrefix: String

    // Confined to `queue`.
    private var stream: (any DesktopChangeSource)?
    private var pending: DispatchWorkItem?
    private var firstPending: DispatchTime?
    private var running = false
    /// The next snapshot cannot vouch for when its changes happened (first scan, dropped events, a failure).
    private var broken = true
    private var lastScanDuration: TimeInterval = 0
    private var retry: DispatchWorkItem?

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
        gate.withLock { open = true }
        queue.async { [self] in
            guard !running else { return }
            running = true
            broken = true
            createStream()
            if initialScan { runScan() }
        }
    }

    /// Stops watching. Safe from any thread, including the handler; returns without waiting for a scan in flight,
    /// and no event is delivered after it returns.
    public func stop() {
        gate.withLock { open = false }
        queue.async { [self] in
            running = false
            teardown()
        }
    }

    /// Rescans now (wake, session active, user request), cancelling a pending debounce. The snapshot is not
    /// `continuous` unless `preservingContinuity` (a short confirmation rescan by the same session).
    public func rescanNow(preservingContinuity: Bool = false) {
        queue.async { [self] in
            guard running else { return }
            if !preservingContinuity { broken = true }
            runScan()
        }
    }

    // MARK: Queue-confined

    private func createStream() {
        guard let source = Self.makeSource(path: watchedPath, latency: latency, queue: queue, watcher: self) else {
            streamFailed()
            return
        }
        stream = source
    }

    /// Reports a stream that would not start and tries again; changes are unseen until then.
    private func streamFailed() {
        broken = true
        deliver(.failed(.unreadable(watchedPath, "could not watch the folder for changes")))
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, running, stream == nil else { return }
            createStream()
            if stream != nil { runScan() }
        }
        retry = item
        queue.asyncAfter(deadline: .now() + Self.retryDelay, execute: item)
    }

    private func teardown() {
        retry?.cancel()
        retry = nil
        pending?.cancel()
        pending = nil
        firstPending = nil
        guard let s = stream else { return }
        stream = nil
        s.stop()
    }

    // MARK: From the change source (on the queue)

    /// Something in the folder changed: `relevant` changes rescan after the debounce; `lost` means the source
    /// missed changes (an overflow), so the next snapshot cannot vouch for continuity.
    func sourceDidChange(relevant: Bool, lost: Bool) {
        guard running else { return }
        if lost { broken = true }
        if relevant { scheduleScan() }
    }

    /// The folder itself was moved, renamed or replaced: watch it afresh and rescan at once.
    func sourceRootChanged() {
        guard running else { return }
        teardown()
        broken = true
        createStream()
        runScan()
    }

    /// The source broke (its handle failed): rescan now and start a new one after `retryDelay`.
    func sourceFailed() {
        guard running else { return }
        teardown()
        broken = true
        runScan()
        streamFailed()
    }

    private func scheduleScan() {
        let now = DispatchTime.now()
        let first = firstPending ?? now
        firstPending = first
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.runScan() }
        pending = item
        let cap = max(maxDelay, 2 * lastScanDuration)
        queue.asyncAfter(deadline: min(now + debounce, first + cap), execute: item)
    }

    private func runScan() {
        pending?.cancel()
        pending = nil
        firstPending = nil
        let started = DispatchTime.now()
        let continuous = !broken
        do throws(DesktopScanner.Failure) {
            var snapshot = try scanner.scan()
            lastScanDuration = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            snapshot.continuous = continuous && stream != nil
            broken = stream == nil
            deliver(.snapshot(snapshot))
        } catch {
            broken = true
            deliver(.failed(error))
        }
    }

    private func deliver(_ event: Event) {
        gate.withLock {
            if open { handler(event) }
        }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    static func normalized(_ path: String) -> String {
        TextLayout.nfc(path).lowercased()
    }
}

/// What tells a `DesktopWatcher` that its folder changed (one per platform). Made and stopped on the watcher's
/// queue; it calls back on that queue (`sourceDidChange`, `sourceRootChanged`, `sourceFailed`).
protocol DesktopChangeSource: AnyObject {
    func stop()
}

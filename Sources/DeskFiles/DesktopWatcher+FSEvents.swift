#if canImport(CoreServices)
import CoreServices
import DeskCore
import Foundation

// The FSEvents source of `DesktopWatcher` (macOS). Stream flags: `FileEvents | UseCFTypes | UseExtendedData |
// WatchRoot`, latency 0.25 s, on the watcher's queue.

extension DesktopWatcher {
    /// Extended-data dictionary keys (`kFSEventStreamEventExtendedDataPathKey`, `…ExtendedFileIDKey`).
    static let pathKey = "path"
    static let fileIDKey = "fileID"

    static func makeSource(
        path watchedPath: String, latency: TimeInterval, queue: DispatchQueue, watcher: DesktopWatcher
    ) -> (any DesktopChangeSource)? {
        let box = CallbackBox(watcher)
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
        ) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return nil
        }
        return FSEventsSource(s)
    }

    fileprivate func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        let rootChanged = UInt32(kFSEventStreamEventFlagRootChanged)
        if events.contains(where: { $0.flags & rootChanged != 0 }) {
            sourceRootChanged()
            return
        }
        let lost = UInt32(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        )
        sourceDidChange(
            relevant: events.contains { Self.isRelevant(path: $0.path, flags: $0.flags, root: matchPrefix) },
            lost: events.contains { $0.flags & lost != 0 }
        )
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

private final class FSEventsSource: DesktopChangeSource {
    private let stream: FSEventStreamRef

    init(_ stream: FSEventStreamRef) { self.stream = stream }

    func stop() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// What the FSEvents context retains: a weak link back, so a forgotten watcher can still deallocate.
private final class CallbackBox: @unchecked Sendable {
    weak var watcher: DesktopWatcher?

    init(_ watcher: DesktopWatcher) { self.watcher = watcher }
}
#endif

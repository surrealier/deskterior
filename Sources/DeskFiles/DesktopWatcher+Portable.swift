#if !canImport(CoreServices)
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import DeskCore
import Foundation

// `DesktopWatcher`'s change source off macOS (docs/WINDOWS.md WP5). A change only says "rescan": the scan is the
// truth, so what changed is never read. Windows watches the top level with `ReadDirectoryChangesW` on a thread of
// its own; Linux (development only) uses inotify.

extension DesktopWatcher {
    static func makeSource(
        path: String, latency: TimeInterval, queue: DispatchQueue, watcher: DesktopWatcher
    ) -> (any DesktopChangeSource)? {
        DirectoryChangeSource(path: path, queue: queue, watcher: watcher)
    }
}

#if os(Windows)
/// `ReadDirectoryChangesW` (top level only: names, attributes, sizes, write and creation times) with an overlapped
/// read and a stop event, on a dedicated thread. A buffer overflow (no bytes, or `ERROR_NOTIFY_ENUM_DIR`) is a
/// lost change; any other failure (the folder deleted, access revoked) breaks the source, and the watcher rescans
/// and starts a new one.
final class DirectoryChangeSource: DesktopChangeSource, @unchecked Sendable {
    /// Bytes of change records per read (tests may lower it to force overflows).
    nonisolated(unsafe) static var bufferSize = 64 * 1024

    private let directory: HANDLE
    private let stopEvent: HANDLE
    private let finished = DispatchSemaphore(value: 0)

    init?(path: String, queue: DispatchQueue, watcher: DesktopWatcher) {
        let listDirectory: DWORD = 0x0001, overlapped: DWORD = 0x4000_0000
        let h = Win32.withWide(Win32.path(path)) {
            CreateFileW($0, listDirectory, Win32.shareAll, nil, Win32.openExisting, Win32.backupSemantics | overlapped, nil)
        }
        guard let h, h != Win32.invalidHandle else { return nil }
        guard let stop = CreateEventW(nil, true, false, nil) else {
            CloseHandle(h)
            return nil
        }
        directory = h
        stopEvent = stop
        let size = Self.bufferSize
        let thread = Thread { [directory, stopEvent, finished, weak watcher] in
            Self.run(directory, stopEvent, size) { event in
                queue.async {
                    guard let watcher else { return }
                    switch event {
                    case .changed: watcher.sourceDidChange(relevant: true, lost: false)
                    case .overflowed: watcher.sourceDidChange(relevant: true, lost: true)
                    case .failed: watcher.sourceFailed()
                    }
                }
            }
            finished.signal()
        }
        thread.name = "deskterior.directory-changes"
        thread.start()
    }

    enum Event { case changed, overflowed, failed }

    private static func run(_ directory: HANDLE, _ stopEvent: HANDLE, _ size: Int, _ report: (Event) -> Void) {
        guard let event = CreateEventW(nil, true, false, nil) else {
            report(.failed)
            return
        }
        defer { CloseHandle(event) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        let ov = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
        defer { ov.deallocate() }
        // FILE_NAME | DIR_NAME | ATTRIBUTES | SIZE | LAST_WRITE | CREATION
        let filter: DWORD = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x40
        while true {
            ov.initialize(to: OVERLAPPED())
            ov.pointee.hEvent = event
            ResetEvent(event)
            guard ReadDirectoryChangesW(directory, buffer, DWORD(size), false, filter, nil, ov, nil).boolValue else {
                report(.failed)
                return
            }
            var handles: [HANDLE?] = [event, stopEvent]
            let woke = WaitForMultipleObjects(2, &handles, false, 0xFFFF_FFFF)
            var bytes: DWORD = 0
            if woke != 0 {
                CancelIoEx(directory, ov)
                _ = GetOverlappedResult(directory, ov, &bytes, true)
                return
            }
            guard GetOverlappedResult(directory, ov, &bytes, false).boolValue else {
                if GetLastError() == 1022 {        // ERROR_NOTIFY_ENUM_DIR: too many changes to list
                    report(.overflowed)
                    continue
                }
                report(.failed)
                return
            }
            report(bytes == 0 ? .overflowed : .changed)
        }
    }

    func stop() {
        SetEvent(stopEvent)
        finished.wait()
        CloseHandle(directory)
        CloseHandle(stopEvent)
    }
}
#else
/// inotify on the folder (Linux, development only): any event at the top level rescans; the folder itself deleted
/// or moved restarts the watch; a queue overflow is a lost change.
final class DirectoryChangeSource: DesktopChangeSource, @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead

    init?(path: String, queue: DispatchQueue, watcher: DesktopWatcher) {
        let fd = inotify_init1(Int32(0o4000 | 0o2000000))          // IN_NONBLOCK | IN_CLOEXEC
        guard fd >= 0 else { return nil }
        // MODIFY ATTRIB MOVED_FROM MOVED_TO CREATE DELETE DELETE_SELF MOVE_SELF
        let mask: UInt32 = 0x2 | 0x4 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x800
        guard inotify_add_watch(fd, path, mask) >= 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak watcher, fd] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var changed = false, lost = false, rootGone = false
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { break }
                var o = 0
                while o + 16 <= n {
                    let m = UInt32(buffer[o + 4]) | UInt32(buffer[o + 5]) << 8 | UInt32(buffer[o + 6]) << 16
                        | UInt32(buffer[o + 7]) << 24
                    let len = Int(UInt32(buffer[o + 12]) | UInt32(buffer[o + 13]) << 8 | UInt32(buffer[o + 14]) << 16
                        | UInt32(buffer[o + 15]) << 24)
                    if m & 0x4000 != 0 { lost = true }                   // IN_Q_OVERFLOW
                    if m & (0x400 | 0x800 | 0x8000) != 0 { rootGone = true } // DELETE_SELF MOVE_SELF IGNORED
                    changed = true
                    o += 16 + len
                }
            }
            guard let watcher, changed else { return }
            if rootGone {
                watcher.sourceRootChanged()
            } else {
                watcher.sourceDidChange(relevant: true, lost: lost)
            }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
    }

    func stop() {
        source.cancel()
    }
}
#endif
#endif

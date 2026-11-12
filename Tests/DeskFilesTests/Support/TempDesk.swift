import DeskCore
import Foundation
#if os(Windows)
import WinSDK
#endif
@testable import DeskFiles

/// A scratch folder at `FileManager.temporaryDirectory/deskterior-tests-<uuid>`, removed on deinit. Every
/// file-system test works only in here; the real desktop is never touched.
final class TempDesk: @unchecked Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskterior-tests-\(UUID().uuidString)", isDirectory: true)
        precondition(!DesktopLocator.isInsideDesktop(root), "temporary directory inside the desktop?")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Only ever delete our own uniquely named folder.
        guard root.lastPathComponent.hasPrefix("deskterior-tests-") else { return }
        chmodTree(root)
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ name: String, isDirectory: Bool = false) -> URL {
        root.appendingPathComponent(name, isDirectory: isDirectory)
    }

    @discardableResult
    func write(_ name: String, _ text: String = "x") throws -> URL {
        let u = url(name)
        try Data(text.utf8).write(to: u)
        return u
    }

    @discardableResult
    func mkdir(_ name: String) throws -> URL {
        let u = url(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func move(_ from: String, _ to: String) throws {
        try FileManager.default.moveItem(at: url(from), to: url(to))
    }

    func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: url(name))
    }

    /// The item's own inode (file index on Windows), from `FilePrimitives.status`.
    func inode(_ name: String) -> UInt64 {
        (try? FilePrimitives.status(url(name), follow: false).get())?.inode ?? 0
    }

    private func chmodTree(_ url: URL) {
        #if !os(Windows)
        chmod(url.path, 0o755)
        #endif
        let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in items {
            let child = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue { chmodTree(child) }
        }
    }
}

/// Thread-safe list of watcher events.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [DesktopSnapshot] = []
    private var failures: [DesktopScanner.Failure] = []

    func record(_ e: DesktopWatcher.Event) {
        lock.withLock {
            switch e {
            case let .snapshot(s): snapshots.append(s)
            case let .failed(f): failures.append(f)
            }
        }
    }

    var all: [DesktopSnapshot] { lock.withLock { snapshots } }
    var latest: DesktopSnapshot? { lock.withLock { snapshots.last } }
    var count: Int { lock.withLock { snapshots.count } }
    var failureList: [DesktopScanner.Failure] { lock.withLock { failures } }

    func latestNames() -> Set<String> { Set(latest?.entries.map(\.meta.name) ?? []) }
}

/// Polls `condition` every 25 ms until it holds or `timeout` passes. Generous, as it returns as soon as the condition
/// holds: FSEvents and the watcher's utility queue can run seconds late on a starved runner.
func waitUntil(timeout: Double = 60, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

/// Renames `from` over `to`, replacing what is there (an editor's safe-save, a swap in a test): `rename(2)`, or
/// `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING` on Windows (whose `rename` refuses an existing target). 0 or -1.
func renameReplacing(_ from: String, _ to: String) -> Int32 {
    #if os(Windows)
    let ok = Win32.withWide(Win32.path(from)) { f in Win32.withWide(Win32.path(to)) { t in MoveFileExW(f, t, DWORD(0x1)) } }
    return ok ? 0 : -1
    #else
    return rename(from, to)
    #endif
}

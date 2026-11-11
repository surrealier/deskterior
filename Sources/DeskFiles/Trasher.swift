#if canImport(AppKit)
import AppKit
#elseif os(Windows)
import WinSDK
#endif
import Foundation

/// Moves items to a trash (DESIGN §3.5). Internal: only `FileOperator` calls it, after its own checks (intent,
/// confinement, identity); nothing is ever deleted. Callers pick one with `FileOperator.Trash`.
protocol Trasher: Sendable {
    /// The one folder every item goes to, when there is one (`FakeTrasher`); nil for the system Trash, which is
    /// per volume. In demo and test modes `FileOperator` requires it inside a sandbox root.
    var trashFolder: URL? { get }
    /// Moves the item at `url` (the item itself; a symlink is not followed) to the trash. Returns its URL there,
    /// or nil when the trash does not say.
    func trash(_ url: URL) async throws -> URL?
    /// True when `url` is directly inside this trash: the only places undo renames items out of.
    func contains(_ url: URL) -> Bool
}

#if canImport(AppKit)
/// The real Trash, through `NSWorkspace.recycle` (the Finder way, so Finder's Put Back works too).
struct SystemTrasher: Trasher {
    var trashFolder: URL? { nil }

    func trash(_ url: URL) async throws -> URL? {
        let moved = try await NSWorkspace.shared.recycle([url])
        return moved[url] ?? (moved.count == 1 ? moved.first?.value : nil)
    }

    /// Path arithmetic only: the Trash is never listed or inspected.
    func contains(_ url: URL) -> Bool {
        Self.isTrashChild(url, homeTrash: FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first,
                          uid: getuid())
    }

    /// A direct child of `~/.Trash` or of a volume's `.Trashes/<uid>`, by spelling.
    static func isTrashChild(_ url: URL, homeTrash: URL?, uid: uid_t) -> Bool {
        let u = url.standardizedFileURL
        let name = u.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return false }
        let parent = u.deletingLastPathComponent()
        if let homeTrash, parent.path == homeTrash.standardizedFileURL.path { return true }
        return parent.lastPathComponent == String(uid) && parent.deletingLastPathComponent().lastPathComponent == ".Trashes"
    }
}
#elseif os(Windows)
/// The Recycle Bin, through `SHFileOperationW(FO_DELETE, FOF_ALLOWUNDO)` (Explorer's way, so its Restore works too)
/// (docs/WINDOWS.md WP5). A drive with no Recycle Bin (most removable drives) would delete instead, so the bin is
/// asked for first (`SHQueryRecycleBinW`) and the item refused without one; `FOF_WANTNUKEWARNING` is a second net.
/// Where an item lands in the bin is not reported, so undo cannot rename it back: `trash` returns nil.
struct SystemTrasher: Trasher {
    var trashFolder: URL? { nil }

    func trash(_ url: URL) async throws -> URL? {
        let path = Win32.path(url)
        guard Self.hasRecycleBin(path) else { throw FileRefusal.from(errno: ENOTSUP) }
        // pFrom is a list ending in two NULs.
        var from = Array(path.utf16) + [0, 0]
        let flags = UInt16(0x0040 | 0x0010 | 0x0004 | 0x0400 | 0x4000)   // ALLOWUNDO NOCONFIRMATION SILENT NOERRORUI WANTNUKEWARNING
        let result: Int32 = from.withUnsafeMutableBufferPointer { buffer in
            var op = SHFILEOPSTRUCTW()
            op.wFunc = UINT(0x0003)                                        // FO_DELETE
            op.pFrom = UnsafePointer(buffer.baseAddress)
            op.fFlags = flags
            let r = SHFileOperationW(&op)
            return op.fAnyOperationsAborted.boolValue ? Int32(1223) : r
        }
        guard result == 0 else {
            throw FileRefusal.from(errno: result == 1223 ? ECANCELED : FilePrimitives.errno(win32: DWORD(bitPattern: result)))
        }
        return nil
    }

    /// The Recycle Bin is never listed here; undo of a trash goes through Explorer's Restore.
    func contains(_ url: URL) -> Bool { false }

    /// The drive of `path` has a Recycle Bin.
    static func hasRecycleBin(_ path: String) -> Bool {
        var info = SHQUERYRBINFO()
        info.cbSize = DWORD(MemoryLayout<SHQUERYRBINFO>.size)
        let root = String(path.hasPrefix(#"\\?\"#) ? path.dropFirst(4).prefix(3) : path.prefix(3))
        return Win32.withWide(root) { SHQueryRecycleBinW($0, &info) } == S_OK
    }
}
#else
/// Linux (development only) has no system trash here: every trash is refused; demos and tests use `FakeTrasher`.
struct SystemTrasher: Trasher {
    var trashFolder: URL? { nil }
    func trash(_ url: URL) async throws -> URL? { throw FileRefusal.from(errno: ENOTSUP) }
    func contains(_ url: URL) -> Bool { false }
}
#endif

/// A trash folder of our own for demo, headless and test modes (DESIGN §3.7 item 7). Items are renamed into it
/// with `RENAME_EXCL` under a free Finder-style name ("name 2"), so nothing in it is ever replaced. The folder
/// must stay outside the desktop folder and the mirrored folder; that is checked when it is made and before
/// every move.
struct FakeTrasher: Trasher {
    let folder: URL
    private let desktop: URL
    private let mirrored: URL?

    /// Refuses a folder inside the desktop folder or the mirrored folder; creates it otherwise.
    init(folder: URL, desktop: URL = DesktopLocator.defaultDesktopURL(), mirrored: URL? = nil) throws {
        let dir = URL(fileURLWithPath: DesktopLocator.canonicalPath(folder), isDirectory: true)
        try SafetyGuard.checkOwnFolder(dir, desktop: desktop, mirrored: mirrored)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.folder = dir
        self.desktop = desktop
        self.mirrored = mirrored
    }

    var trashFolder: URL? { folder }

    func trash(_ url: URL) async throws -> URL? {
        try SafetyGuard.checkOwnFolder(folder, desktop: desktop, mirrored: mirrored)
        let item = url.standardizedFileURL
        switch FileMoves.renameToFreeName(
            item, in: folder, name: item.lastPathComponent, splitsExtension: FileMoves.splitsExtension(item)
        ) {
        case let .success(placed): return placed.url
        case let .failure(f): throw f.refusal
        }
    }

    func contains(_ url: URL) -> Bool {
        SafetyGuard.isDirectChild(url, of: folder)
    }
}

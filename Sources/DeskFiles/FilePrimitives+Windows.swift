#if os(Windows)
import DeskCore
import Foundation
import WinSDK

// `FilePrimitives` on Windows (docs/WINDOWS.md WP5): the same contracts as `FilePrimitives+POSIX.swift`, through
// Win32. Identity is the volume serial number and the file index (`GetFileInformationByHandle` on a handle opened
// with no access, every share mode and backup semantics); reparse points that stand for another name (symbolic
// links, junctions) are not followed unless asked, while cloud placeholders (OneDrive) are read as the files they
// are. Win32 errors become errno values in `errno(win32:)`, so the shared code reads them as it does on macOS.

/// Win32 values used here, typed as `DWORD` once (the SDK's macros import with mixed integer types).
enum Win32 {
    static let shareAll: DWORD = 0x1 | 0x2 | 0x4             // FILE_SHARE_READ | WRITE | DELETE
    static let createNew: DWORD = 1
    static let openExisting: DWORD = 3
    static let openAlways: DWORD = 4
    static let backupSemantics: DWORD = 0x0200_0000
    static let openReparsePoint: DWORD = 0x0020_0000
    static let genericRead: DWORD = 0x8000_0000
    static let genericWrite: DWORD = 0x4000_0000
    static let delete: DWORD = 0x0001_0000
    static let appendData: DWORD = 0x0004
    static let readAttributes: DWORD = 0x0080

    static let readOnly: DWORD = 0x1
    static let hidden: DWORD = 0x2
    static let system: DWORD = 0x4
    static let directory: DWORD = 0x10
    static let archive: DWORD = 0x20
    static let normal: DWORD = 0x80
    static let reparsePoint: DWORD = 0x400
    static let offline: DWORD = 0x1000
    static let recallOnOpen: DWORD = 0x0004_0000
    static let recallOnDataAccess: DWORD = 0x0040_0000
    static let invalidAttributes: DWORD = 0xFFFF_FFFF

    /// `IsReparseTagNameSurrogate`: the reparse point stands for another name (a link, a junction).
    static func isNameSurrogate(_ tag: DWORD) -> Bool { tag & 0x2000_0000 != 0 }

    static let invalidHandle = HANDLE(bitPattern: -1)

    /// The path as Win32 takes it: the file-system representation, with `\\?\` before long absolute paths.
    static func path(_ url: URL) -> String {
        let native = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
        let chars = Array(native.utf16)
        if native.utf16.count >= 248, chars.count > 2, chars[1] == UInt16(UInt8(ascii: ":")) {
            return #"\\?\"# + native
        }
        return native
    }

    static func path(_ path: String) -> String { Win32.path(URL(fileURLWithPath: path)) }

    static func withWide<T>(_ s: String, _ body: (UnsafePointer<WCHAR>) -> T) -> T {
        s.withCString(encodedAs: UTF16.self) { body($0) }
    }

    /// A handle for reading facts (no access) or the access asked for; nil and `GetLastError` on failure.
    static func open(_ path: String, access: DWORD = 0, follow: Bool, extraFlags: DWORD = 0) -> HANDLE? {
        let flags = backupSemantics | (follow ? 0 : openReparsePoint) | extraFlags
        let h = withWide(path) { CreateFileW($0, access, shareAll, nil, openExisting, flags, nil) }
        guard let h, h != invalidHandle else { return nil }
        return h
    }

    static func info(_ h: HANDLE) -> BY_HANDLE_FILE_INFORMATION? {
        var info = BY_HANDLE_FILE_INFORMATION()
        return GetFileInformationByHandle(h, &info).boolValue ? info : nil
    }

    static func reparseTag(_ h: HANDLE) -> DWORD? {
        var tag = FILE_ATTRIBUTE_TAG_INFO()
        let ok = GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size))
        return ok.boolValue ? tag.ReparseTag : nil
    }

    /// 100 ns ticks since 1601 → seconds and nanoseconds since 1970.
    static func unixTime(_ t: FILETIME) -> (Int64, Int64) {
        let ticks = Int64(UInt64(t.dwHighDateTime) << 32 | UInt64(t.dwLowDateTime))
        let sinceUnix = ticks - 116_444_736_000_000_000
        let seconds = sinceUnix >= 0 ? sinceUnix / 10_000_000 : (sinceUnix - 9_999_999) / 10_000_000
        return (seconds, (sinceUnix - seconds * 10_000_000) * 100)
    }

    static func date(_ t: FILETIME) -> Date {
        let (s, ns) = unixTime(t)
        return Date(timeIntervalSince1970: Double(s) + Double(ns) / 1e9)
    }

    static var lastErrno: Errno { FilePrimitives.errno(win32: GetLastError()) }
}

extension FilePrimitives {
    /// The one Win32 → errno table (docs/WINDOWS.md WP5): what `FileRefusal.from(errno:)` then reads.
    static func errno(win32 e: DWORD) -> Errno {
        switch e {
        case 0: 0
        case 2, 3, 15, 53, 67, 161: ENOENT             // file, path, drive, network path, network name, bad path
        case 5, 1314: EACCES                            // access denied, privilege not held
        case 32, 33: EPERM                              // sharing violation, lock violation: the item is in use
        case 80, 183: EEXIST                            // file exists, already exists
        case 17: EXDEV                                  // not same device
        case 19: EROFS                                  // write protected
        case 39, 112: ENOSPC                            // handle disk full, disk full
        case 123: EINVAL                                // invalid name
        case 145: ENOTEMPTY                             // directory not empty
        case 206: ENAMETOOLONG                          // filename too long
        case 267: ENOTDIR                               // directory name invalid
        case 1223: ECANCELED                            // cancelled by the user
        case 50: ENOTSUP                                // not supported
        default: EIO
        }
    }

    static func status(_ url: URL, follow: Bool = false) -> StatusResult {
        status(native: Win32.path(url), follow: follow)
    }

    static func status(path: String, follow: Bool) -> StatusResult {
        status(native: Win32.path(path), follow: follow)
    }

    private static func status(native: String, follow: Bool) -> StatusResult {
        guard let h = Win32.open(native, access: 0, follow: follow) else { return .failure(FileErrno(Win32.lastErrno)) }
        defer { CloseHandle(h) }
        guard let info = Win32.info(h) else { return .failure(FileErrno(Win32.lastErrno)) }
        let attributes = info.dwFileAttributes
        var kind: Kind = attributes & Win32.directory != 0 ? .directory : .regular
        if !follow, attributes & Win32.reparsePoint != 0, let tag = Win32.reparseTag(h), Win32.isNameSurrogate(tag) {
            kind = .link
        }
        let (s, ns) = Win32.unixTime(info.ftLastWriteTime)
        let index = UInt64(info.nFileIndexHigh) << 32 | UInt64(info.nFileIndexLow)
        let size = kind == .regular ? Int64(UInt64(info.nFileSizeHigh) << 32 | UInt64(info.nFileSizeLow)) : 0
        return .success(Status(
            device: UInt64(info.dwVolumeSerialNumber), inode: index, kind: kind, size: size, modifiedSeconds: s,
            modifiedNanoseconds: ns, flags: attributes, created: Win32.date(info.ftCreationTime)
        ))
    }

    /// The volume serial number of the item's volume, as 16 hex digits (what the scanner records).
    static func volumeID(_ url: URL) -> String? {
        (try? status(url, follow: true).get()).map { hexVolume($0.device) }
    }

    /// A cloud placeholder (OneDrive and others) whose reading would download it.
    static func isDataless(_ s: Status) -> Bool {
        s.flags & (Win32.recallOnDataAccess | Win32.recallOnOpen | Win32.offline) != 0
    }

    /// The final path of an existing item (links resolved, case as stored), in `URL.path` form; nil when it does
    /// not exist.
    static func resolvedPath(_ path: String) -> String? {
        guard let h = Win32.open(Win32.path(path), access: 0, follow: true) else { return nil }
        defer { CloseHandle(h) }
        var buffer = [WCHAR](repeating: 0, count: 1024)
        var n = GetFinalPathNameByHandleW(h, &buffer, DWORD(buffer.count), 0)
        if n >= DWORD(buffer.count) {
            buffer = [WCHAR](repeating: 0, count: Int(n) + 1)
            n = GetFinalPathNameByHandleW(h, &buffer, DWORD(buffer.count), 0)
        }
        guard n > 0, n < DWORD(buffer.count) else { return nil }
        var final = String(decoding: buffer[0..<Int(n)], as: UTF16.self)
        if final.hasPrefix(#"\\?\UNC\"#) {
            final = #"\\"# + final.dropFirst(8)
        } else if final.hasPrefix(#"\\?\"#) {
            final = String(final.dropFirst(4))
        }
        return URL(fileURLWithPath: final).standardizedFileURL.path
    }

    // MARK: Changing files

    /// `MoveFileExW` without `MOVEFILE_REPLACE_EXISTING` or `MOVEFILE_COPY_ALLOWED`: an existing item at `to` is
    /// never replaced (`EEXIST`), another volume is `EXDEV`, an item in use is `EPERM` (and `isLocked`).
    static func renameExclusive(_ from: URL, _ to: URL) -> Errno {
        let ok = Win32.withWide(Win32.path(from)) { f in Win32.withWide(Win32.path(to)) { t in MoveFileExW(f, t, 0) } }
        return ok.boolValue ? 0 : Win32.lastErrno
    }

    /// Renames one of our own files over another of ours (the log's rotation).
    static func replaceOwnFile(_ from: URL, with to: URL) -> Errno {
        let ok = Win32.withWide(Win32.path(from)) { f in
            Win32.withWide(Win32.path(to)) { t in MoveFileExW(f, t, DWORD(0x1)) }   // MOVEFILE_REPLACE_EXISTING
        }
        return ok.boolValue ? 0 : Win32.lastErrno
    }

    /// A new folder of ours; `hidden` sets the hidden attribute on it (only on the folder just made).
    static func makeDirectory(_ url: URL, hidden: Bool) -> Errno {
        let path = Win32.path(url)
        guard Win32.withWide(path, { CreateDirectoryW($0, nil) }).boolValue else { return Win32.lastErrno }
        if hidden { _ = Win32.withWide(path) { SetFileAttributesW($0, Win32.hidden) } }
        return 0
    }

    static func removeEmptyDirectory(_ url: URL) -> Errno {
        Win32.withWide(Win32.path(url)) { RemoveDirectoryW($0) }.boolValue ? 0 : Win32.lastErrno
    }

    /// Clears the read-only attribute on everything in one of our staging folders, so it can be removed. Reparse
    /// points are not followed.
    static func unlockTree(_ path: String) {
        let native = Win32.path(path)
        let attributes = Win32.withWide(native) { GetFileAttributesW($0) }
        guard attributes != Win32.invalidAttributes else { return }
        if attributes & Win32.readOnly != 0 {
            _ = Win32.withWide(native) { SetFileAttributesW($0, attributes & ~Win32.readOnly) }
        }
        guard attributes & Win32.directory != 0, attributes & Win32.reparsePoint == 0 else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            unlockTree((path as NSString).appendingPathComponent(name))
        }
    }

    static let lockMask: UInt32 = 0

    /// Windows has no lock flags like Finder's; a file in use is what stops a rename (`isLocked`).
    static func lockFlags(_ url: URL) -> UInt32 { 0 }

    static func changeFlags(_ url: URL, adding: UInt32, removing: UInt32) {}

    /// The item at `url` is open elsewhere without delete sharing, so it cannot be renamed now.
    static func isLocked(_ url: URL) -> Bool {
        if let h = Win32.open(Win32.path(url), access: Win32.delete, follow: false) {
            CloseHandle(h)
            return false
        }
        let e = GetLastError()
        return e == 32 || e == 33
    }

    /// Writes `data` as a new file at `url` (`CREATE_NEW`: never an existing item, nor through a link there), then
    /// flushes it, so what lands on the desk is whole.
    static func writeNewFile(_ data: Data, to url: URL) throws {
        let h = Win32.withWide(Win32.path(url)) {
            CreateFileW($0, Win32.genericWrite, 0, nil, Win32.createNew, Win32.normal, nil)
        }
        guard let h, h != Win32.invalidHandle else { throw FileRefusal.from(errno: Win32.lastErrno) }
        var failure = writeAll(h, data)
        if failure == 0, !FlushFileBuffers(h).boolValue { failure = Win32.lastErrno }
        CloseHandle(h)
        if failure != 0 { throw FileRefusal.from(errno: failure) }
    }

    /// Appends to our own regular file at `url` (made if missing); a link or folder there is refused.
    static func appendToOwnFile(_ data: Data, at url: URL) -> Errno {
        let h = Win32.withWide(Win32.path(url)) {
            CreateFileW($0, Win32.appendData | Win32.readAttributes, 0x1, nil, Win32.openAlways,
                        Win32.normal | Win32.openReparsePoint, nil)
        }
        guard let h, h != Win32.invalidHandle else { return Win32.lastErrno }
        defer { CloseHandle(h) }
        guard let info = Win32.info(h) else { return Win32.lastErrno }
        guard info.dwFileAttributes & (Win32.directory | Win32.reparsePoint) == 0 else { return EINVAL }
        return writeAll(h, data)
    }

    /// Opens our own regular file at `url` for reading (a link or folder there is refused with `EINVAL`).
    static func openOwnFileForReading(_ url: URL) -> Result<(FileHandle, Int64), FileErrno> {
        guard let h = Win32.open(Win32.path(url), access: Win32.genericRead, follow: false) else {
            return .failure(FileErrno(Win32.lastErrno))
        }
        guard let info = Win32.info(h) else {
            let e = Win32.lastErrno
            CloseHandle(h)
            return .failure(FileErrno(e))
        }
        guard info.dwFileAttributes & (Win32.directory | Win32.reparsePoint) == 0 else {
            CloseHandle(h)
            return .failure(FileErrno(EINVAL))
        }
        let size = Int64(UInt64(info.nFileSizeHigh) << 32 | UInt64(info.nFileSizeLow))
        return .success((FileHandle(handle: h, closeOnDealloc: true), size))
    }

    private static func writeAll(_ h: HANDLE, _ data: Data) -> Errno {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Errno in
            var offset = 0
            while offset < raw.count {
                let chunk = DWORD(min(raw.count - offset, 1 << 30))
                var written: DWORD = 0
                guard WriteFile(h, raw.baseAddress! + offset, chunk, &written, nil).boolValue else { return Win32.lastErrno }
                guard written > 0 else { return EIO }
                offset += Int(written)
            }
            return 0
        }
    }

    /// Copies `source` to `staged` (which must not exist) item by item, asking `shouldCopy` before each (the copy
    /// gate: counting and cancelling). Links and junctions inside are skipped, never followed; files are copied
    /// with `CopyFileW` refusing an existing target.
    static func copyTree(_ source: URL, to staged: URL, shouldCopy: (URL) -> Bool) throws {
        guard shouldCopy(source) else { return }
        guard case let .success(st) = status(source, follow: false) else { throw FileRefusal.missing }
        switch st.kind {
        case .directory:
            let made = makeDirectory(staged, hidden: false)
            if made != 0 { throw FileRefusal.from(errno: made) }
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
                try copyTree(source.appendingPathComponent(name), to: staged.appendingPathComponent(name), shouldCopy: shouldCopy)
            }
        case .regular:
            let ok = Win32.withWide(Win32.path(source)) { f in
                Win32.withWide(Win32.path(staged)) { t in CopyFileW(f, t, true) }        // fail if it exists
            }
            if !ok.boolValue { throw FileRefusal.from(errno: Win32.lastErrno) }
        case .link, .other:
            break
        }
    }

    /// Writes a shortcut (`.lnk`) to `source` at `staged` (`ShellLink`), as a new file.
    static func writeLink(to source: URL, at staged: URL) throws {
        let target = Win32.path(source)
        guard case let .success(s) = status(source, follow: true) else { throw FileRefusal.missing }
        let root = String(target.prefix(3))
        let driveType = Win32.withWide(root) { GetDriveTypeW($0) }
        let data = ShellLink.data(
            targetPath: target, isDirectory: s.isDirectory, driveType: UInt32(driveType),
            volumeSerial: UInt32(truncatingIfNeeded: s.device)
        )
        try writeNewFile(data, to: staged)
    }

    /// A shortcut's file name: the target's name with `.lnk` (Explorer never shows `.lnk`).
    static func linkName(for name: String) -> String { name + ".lnk" }

    /// Locks, dismounts and ejects the volume at `volume` (a drive root such as `E:\`). `EBUSY` when it is in use.
    static func unmount(_ volume: URL) throws {
        let native = Win32.path(volume)
        guard native.count >= 2, native.dropFirst().first == ":" else { throw FileRefusal.from(errno: EINVAL) }
        let device = #"\\.\"# + native.prefix(2)
        let h = Win32.withWide(device) {
            CreateFileW($0, Win32.genericRead | Win32.genericWrite, 0x1 | 0x2, nil, Win32.openExisting, 0, nil)
        }
        guard let h, h != Win32.invalidHandle else { throw FileRefusal.from(errno: Win32.lastErrno) }
        defer { CloseHandle(h) }
        var bytes: DWORD = 0
        let lock: DWORD = 0x0009_0018, dismount: DWORD = 0x0009_0020
        let allowRemoval: DWORD = 0x002D_4804, eject: DWORD = 0x002D_4808
        guard DeviceIoControl(h, lock, nil, 0, nil, 0, &bytes, nil).boolValue,
              DeviceIoControl(h, dismount, nil, 0, nil, 0, &bytes, nil).boolValue
        else { throw FileRefusal.from(errno: EBUSY) }
        var prevent: UInt8 = 0
        _ = DeviceIoControl(h, allowRemoval, &prevent, 1, nil, 0, &bytes, nil)
        guard DeviceIoControl(h, eject, nil, 0, nil, 0, &bytes, nil).boolValue else {
            throw FileRefusal.from(errno: EBUSY)
        }
    }

    // MARK: Reading facts

    /// A program: an `.exe` file (its shortcut is what a drop with no key makes).
    static func isApplication(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "exe" else { return false }
        return (try? status(url, follow: true).get())?.kind == .regular
    }

    static func isPackage(_ url: URL) -> Bool { false }

    /// The drive's facts for `VolumeWatcher`, for a drive root (`E:\`); nil for anything else.
    static func volumeFacts(_ url: URL) -> VolumeWatcher.Facts? {
        guard isVolume(url) else { return nil }
        let root = String(Win32.path(url).prefix(2)) + #"\"#
        return driveFacts(root)
    }

    /// `GetDriveTypeW` and `GetVolumeInformationW` for `root` ("E:\").
    static func driveFacts(_ root: String) -> VolumeWatcher.Facts? {
        let type = Win32.withWide(root) { GetDriveTypeW($0) }
        guard type > 1 else { return nil }                             // unknown, no root dir
        let removable = type == 2 || type == 5                         // removable, CD-ROM
        let browsable = Win32.withWide(root) { GetVolumeInformationW($0, nil, 0, nil, nil, nil, nil, 0) }.boolValue
        var windows = [WCHAR](repeating: 0, count: 260)
        let n = GetSystemWindowsDirectoryW(&windows, UINT(windows.count))
        let systemDrive = n >= 2 ? String(decoding: windows[0..<2], as: UTF16.self).uppercased() : "C:"
        return VolumeWatcher.Facts(
            isInternal: removable ? false : nil, isLocal: type != 4, isRemovable: removable, isEjectable: removable,
            isBrowsable: browsable, isRoot: root.prefix(2).uppercased() == systemDrive
        )
    }

    /// Windows keeps no item-replacement folder per volume: copies stage in the desk's hidden partial folder.
    static func replacementDirectory(appropriateFor root: URL) -> URL? { nil }

    /// A drive root (`E:\`).
    static func isVolume(_ url: URL) -> Bool {
        let p = Win32.path(url)
        let c = Array(p.utf16)
        return (c.count == 2 || (c.count == 3 && (c[2] == 0x5C || c[2] == 0x2F))) && c[1] == 0x3A
    }
}
#endif

#if !os(Windows)
#if canImport(Darwin)
import AppKit
import Darwin
import UniformTypeIdentifiers
#elseif canImport(Glibc)
import Glibc
#endif
import DeskCore
import Foundation

// `FilePrimitives` on macOS: the bodies that were in FileOperator, FileMoves, OperationLog and StateStore, moved
// here unchanged. Linux shares them for development builds (docs/WINDOWS.md); where Linux lacks a call (no
// `renamex_np`, no file flags, no bookmarks) it does the nearest safe thing, noted at each one. Linux is never
// shipped.

extension FilePrimitives {
    static func status(_ url: URL, follow: Bool = false) -> StatusResult {
        url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return .failure(FileErrno(EINVAL)) }
            return status(cPath: p, follow: follow)
        }
    }

    static func status(path: String, follow: Bool) -> StatusResult {
        path.withCString { status(cPath: $0, follow: follow) }
    }

    private static func status(cPath p: UnsafePointer<CChar>, follow: Bool) -> StatusResult {
        var st = stat()
        guard (follow ? stat(p, &st) : lstat(p, &st)) == 0 else { return .failure(FileErrno(errno)) }
        let kind: Kind = switch st.st_mode & S_IFMT {
        case S_IFREG: .regular
        case S_IFDIR: .directory
        case S_IFLNK: .link
        default: .other
        }
        #if canImport(Darwin)
        let m = st.st_mtimespec
        let flags = st.st_flags
        #else
        let m = st.st_mtim
        let flags: UInt32 = 0
        #endif
        return .success(Status(
            device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(st.st_ino), kind: kind, size: Int64(st.st_size),
            modifiedSeconds: Int64(m.tv_sec), modifiedNanoseconds: Int64(m.tv_nsec), flags: flags
        ))
    }

    /// The volume UUID (macOS), read fresh; on Linux the device number in hex.
    static func volumeID(_ url: URL) -> String? {
        #if canImport(Darwin)
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        #else
        (try? status(url, follow: true).get()).map { hexVolume($0.device) }
        #endif
    }

    /// `SF_DATALESS`: the content lives in a file provider (iCloud and others) and reading it would download.
    static func isDataless(_ s: Status) -> Bool {
        #if canImport(Darwin)
        s.flags & UInt32(SF_DATALESS) != 0
        #else
        false
        #endif
    }

    /// `realpath(3)`, or nil when `path` does not exist.
    static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Changing files

    /// `renamex_np(from, to, RENAME_EXCL)`: 0, or the errno. An existing item at `to` is never replaced.
    /// Linux (development only) has no exclusive rename here: it refuses a taken name first, then renames.
    static func renameExclusive(_ from: URL, _ to: URL) -> Errno {
        from.withUnsafeFileSystemRepresentation { f in
            to.withUnsafeFileSystemRepresentation { t in
                guard let f, let t else { return EINVAL }
                #if canImport(Darwin)
                return renamex_np(f, t, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
                #else
                var st = stat()
                if lstat(t, &st) == 0 { return EEXIST }
                return Glibc.rename(f, t) == 0 ? 0 : errno
                #endif
            }
        }
    }

    /// Renames one of our own files over another of ours (the log's rotation): `rename(2)`.
    static func replaceOwnFile(_ from: URL, with to: URL) -> Errno {
        #if canImport(Darwin)
        Darwin.rename(from.path, to.path) == 0 ? 0 : errno
        #else
        Glibc.rename(from.path, to.path) == 0 ? 0 : errno
        #endif
    }

    /// A new folder of ours (owner-only). `hidden` is for Windows; here the name's leading dot hides it.
    static func makeDirectory(_ url: URL, hidden: Bool) -> Errno {
        mkdir(url.path, 0o700) == 0 ? 0 : errno
    }

    static func removeEmptyDirectory(_ url: URL) -> Errno {
        rmdir(url.path) == 0 ? 0 : errno
    }

    /// Unlocks and makes owner-writable everything in one of our staging folders, so it can be removed. Symlinks
    /// are never followed.
    static func unlockTree(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        #if canImport(Darwin)
        let locks = st.st_flags & lockMask
        if locks != 0 { _ = lchflags(path, st.st_flags & ~locks) }
        #endif
        guard st.st_mode & S_IFMT == S_IFDIR else { return }
        if st.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmodat(AT_FDCWD, path, (st.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW)
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            unlockTree((path as NSString).appendingPathComponent(name))
        }
    }

    #if canImport(Darwin)
    /// Finder's lock and the append-only flag (both stop a rename).
    static let lockMask = UInt32(UF_IMMUTABLE | UF_APPEND)
    #else
    static let lockMask: UInt32 = 0
    #endif

    static func lockFlags(_ url: URL) -> UInt32 {
        #if canImport(Darwin)
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_flags & lockMask : 0
        #else
        0
        #endif
    }

    static func changeFlags(_ url: URL, adding: UInt32, removing: UInt32) {
        #if canImport(Darwin)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        _ = lchflags(url.path, (st.st_flags & ~removing) | adding)
        #endif
    }

    /// The item at `url` is locked (Finder's lock, append-only, or the system's), or its folder is, so it cannot be
    /// renamed out of there.
    static func isLocked(_ url: URL) -> Bool {
        #if canImport(Darwin)
        var st = stat()
        let item = UInt32(UF_IMMUTABLE | UF_APPEND) | UInt32(SF_IMMUTABLE | SF_APPEND)
        if lstat(url.path, &st) == 0, st.st_flags & item != 0 { return true }
        let folder = url.standardizedFileURL.deletingLastPathComponent()
        return lstat(folder.path, &st) == 0 && st.st_flags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)) != 0
        #else
        false
        #endif
    }

    /// Writes `data` as a new regular file at `url`: never an existing file and never through a symlink
    /// (`O_CREAT | O_EXCL | O_NOFOLLOW`); every byte is written and flushed (`fsync`) before it returns.
    static func writeNewFile(_ data: Data, to url: URL) throws {
        var failure: Int32 = 0
        let fd: Int32 = url.withUnsafeFileSystemRepresentation { p in
            guard let p else {
                failure = EINVAL
                return -1
            }
            let fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if fd < 0 { failure = errno }
            return fd
        }
        guard fd >= 0 else { throw FileRefusal.from(errno: failure) }
        failure = writeAll(fd, data)
        if failure == 0, fsync(fd) != 0 { failure = errno }
        if close(fd) != 0, failure == 0 { failure = errno }
        if failure != 0 { throw FileRefusal.from(errno: failure) }
    }

    /// Appends to the regular file at `url` (made if missing), without following a symlink and without blocking:
    /// anything but a regular file there (a planted FIFO) is refused instead of hanging the caller.
    static func appendToOwnFile(_ data: Data, at url: URL) -> Errno {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return errno }
        #if canImport(Darwin)
        guard st.st_mode & S_IFMT == S_IFREG else { return EFTYPE }
        #else
        guard st.st_mode & S_IFMT == S_IFREG else { return EINVAL }
        #endif
        return writeAll(fd, data)
    }

    /// Reads the regular file at `url` itself: not through a symlink (`O_NOFOLLOW`), without blocking on a FIFO
    /// (`O_NONBLOCK`), and at most `maxBytes` of it. `ENOENT` when nothing is there, `EINVAL` for something that is
    /// not a regular file.
    static func readOwnFile(_ url: URL, maxBytes: Int) -> Result<OwnFileRead, FileErrno> {
        var failure: Int32 = 0
        let fd: Int32 = url.withUnsafeFileSystemRepresentation { p in
            guard let p else {
                failure = EINVAL
                return -1
            }
            let fd = open(p, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 { failure = errno }
            return fd
        }
        guard fd >= 0 else { return .failure(FileErrno(failure)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(FileErrno(errno)) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .failure(FileErrno(EINVAL)) }
        guard st.st_size <= maxBytes else { return .success(.tooLarge(Int64(st.st_size))) }
        do {
            let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            return .success(data.count <= maxBytes ? .data(data) : .tooLarge(nil))
        } catch {
            return .failure(FileErrno(EIO))
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Errno {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Errno in
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                #else
                let n = Glibc.write(fd, raw.baseAddress! + offset, raw.count - offset)
                #endif
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += n
            }
            return 0
        }
    }

    #if !canImport(Darwin)
    /// Copies `source` to `staged` (which must not exist) item by item, asking `shouldCopy` before each (the copy
    /// gate: counting and cancelling). Symbolic links are copied as links, never followed. (macOS copies with
    /// `FileManager.copyItem` and its delegate instead.)
    static func copyTree(_ source: URL, to staged: URL, shouldCopy: (URL) -> Bool) throws {
        guard shouldCopy(source) else { return }
        guard case let .success(st) = status(source, follow: false) else { throw FileRefusal.missing }
        switch st.kind {
        case .directory:
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
                try copyTree(source.appendingPathComponent(name), to: staged.appendingPathComponent(name), shouldCopy: shouldCopy)
            }
        case .link:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: target)
        case .regular:
            try FileManager.default.copyItem(at: source, to: staged)
        case .other:
            break                              // FIFOs, sockets and devices are not copied
        }
    }
    #endif

    /// Writes a link to `source` at `staged`: a Finder alias (bookmark data `suitableForBookmarkFile`) on macOS.
    /// Linux (development only) has no alias files.
    static func writeLink(to source: URL, at staged: URL) throws {
        #if canImport(Darwin)
        let bookmark = try source.bookmarkData(
            options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: staged)
        #else
        throw FileRefusal.from(errno: ENOTSUP)
        #endif
    }

    /// The file name a link to `name` gets (a macOS alias keeps the name).
    static func linkName(for name: String) -> String { name }

    /// `NSWorkspace.unmountAndEjectDevice(at:)`.
    static func unmount(_ volume: URL) throws {
        #if canImport(Darwin)
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        #else
        throw FileRefusal.from(errno: ENOTSUP)
        #endif
    }

    // MARK: Reading facts

    /// An application bundle: a folder whose type is an application (`UTType.application`), or a package named
    /// ".app", reached directly or through a symbolic link.
    static func isApplication(_ url: URL) -> Bool {
        #if canImport(Darwin)
        guard url.isFileURL else { return false }
        let item = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
        guard let v = try? item.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey]),
              v.isDirectory == true
        else { return false }
        if v.contentType?.conforms(to: .application) == true { return true }
        return v.isPackage == true && item.pathExtension.lowercased() == "app"
        #else
        false
        #endif
    }

    /// A package (a folder Finder shows as one file).
    static func isPackage(_ url: URL) -> Bool {
        #if canImport(Darwin)
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        #else
        false
        #endif
    }

    /// The facts `VolumeWatcher` classifies, for the volume mounted at `url`; nil when it is not a volume.
    static func volumeFacts(_ url: URL) -> VolumeWatcher.Facts? {
        #if canImport(Darwin)
        let keys: Set<URLResourceKey> = [
            .isVolumeKey, .volumeIsRootFileSystemKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
            .volumeIsBrowsableKey, .volumeIsInternalKey,
        ]
        guard let v = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys), v.isVolume == true else {
            return nil
        }
        return VolumeWatcher.Facts(
            isInternal: v.volumeIsInternal, isLocal: v.volumeIsLocal ?? true, isRemovable: v.volumeIsRemovable ?? false,
            isEjectable: v.volumeIsEjectable ?? false, isBrowsable: v.volumeIsBrowsable ?? false,
            isRoot: v.volumeIsRootFileSystem ?? true
        )
        #else
        nil
        #endif
    }

    /// A folder for one copy on `root`'s volume but outside it (the system's item-replacement folder), or nil.
    static func replacementDirectory(appropriateFor root: URL) -> URL? {
        #if canImport(Darwin)
        try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true)
        #else
        nil
        #endif
    }

    /// The item at `url` is a mount point (a volume's root).
    static func isVolume(_ url: URL) -> Bool {
        #if canImport(Darwin)
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
        #else
        url.standardizedFileURL.path == "/"
        #endif
    }
}
#endif

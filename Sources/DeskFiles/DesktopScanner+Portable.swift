#if !canImport(UniformTypeIdentifiers)
#if os(Windows)
import WinSDK
#endif
import DeskCore
import Foundation

// `DesktopScanner` without resource values (docs/WINDOWS.md WP5): the listing from `FileManager`, each item's
// identity and times from `FilePrimitives.status` (one handle with no access on Windows, so placeholders are not
// downloaded), its kind from `FileKindTable`. Windows has no "date added": the creation time stands in.
extension DesktopScanner {
    /// One complete listing. Throws instead of returning a partial one, so a failed scan never looks like a mass
    /// deletion.
    public func scan(now: Date = Date()) throws(Failure) -> DesktopSnapshot {
        let path = root.path
        let rootStatus: FilePrimitives.Status
        switch FilePrimitives.status(root, follow: true) {
        case let .success(s): rootStatus = s
        case .failure(ENOENT), .failure(ENOTDIR): throw .missing(path)
        case .failure(EACCES), .failure(EPERM): throw .accessDenied(path)
        case let .failure(e): throw .unreadable(path, String(cString: strerror(e.code)))
        }
        guard rootStatus.isDirectory else { throw .notADirectory(path) }

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw Self.failure(error, path: path)
        }
        let rootVolume = FilePrimitives.hexVolume(rootStatus.device)
        let hidesKnownExtensions = Self.hidesKnownExtensions()
        var entries: [DesktopEntry] = []
        entries.reserveCapacity(names.count)
        for name in names where !Self.isSkipped(name) {
            let url = root.appendingPathComponent(name, isDirectory: false)
            // An item can vanish between listing and stat; it simply is not in this snapshot.
            guard case let .success(st) = FilePrimitives.status(url, follow: false), !Self.isHidden(st) else { continue }
            entries.append(Self.entry(url: url, name: name, status: st, hidesKnownExtensions: hidesKnownExtensions))
        }
        entries.sort { $0.meta.name < $1.meta.name }
        return DesktopSnapshot(
            rootPath: DesktopLocator.canonicalPath(root), rootVolume: rootVolume, entries: entries, scannedAt: now
        )
    }

    /// Whether the item at `url` is a cloud placeholder whose reading would download it. Reads only metadata.
    public static func isDataless(_ url: URL) -> Bool {
        guard case let .success(st) = FilePrimitives.status(url, follow: false) else { return false }
        return FilePrimitives.isDataless(st)
    }

    // MARK: Private

    /// Names never shown: our staging folders, Explorer's `desktop.ini`, and (Linux) dot files.
    static func isSkipped(_ name: String) -> Bool {
        if name.hasPrefix(FileMoves.partialPrefix) { return true }
        #if os(Windows)
        return name.lowercased() == "desktop.ini"
        #else
        return name.hasPrefix(".")
        #endif
    }

    /// Hidden or system items (Windows attributes), which Explorer does not show on the desktop.
    static func isHidden(_ st: FilePrimitives.Status) -> Bool {
        #if os(Windows)
        st.flags & (Win32.hidden | Win32.system) != 0
        #else
        false
        #endif
    }

    /// Explorer's "Hide extensions for known file types" (on unless turned off).
    static func hidesKnownExtensions() -> Bool {
        #if os(Windows)
        FinderPrefs.registryDWORD(#"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"#, "HideFileExt") != 0
        #else
        false
        #endif
    }

    private static func entry(
        url: URL, name: String, status st: FilePrimitives.Status, hidesKnownExtensions: Bool
    ) -> DesktopEntry {
        let ext = (name as NSString).pathExtension.lowercased()
        let isDirectory = st.kind == .directory
        let isDataless = FilePrimitives.isDataless(st)
        let isShortcut = ext == "lnk" || ext == "url"
        let isAlias = st.kind == .link || (!isDirectory && isShortcut)
        var kind = FileKindTable.classify(name: name, isDirectory: isDirectory)
        if ext == "lnk", !isDirectory, !isDataless { kind = shortcutKind(url) }
        let hidesExtension = !isDirectory && (isShortcut || (hidesKnownExtensions && FileKindTable.kinds[ext] != nil))
        let meta = TokenMeta(
            name: name, kind: kind, added: st.created, modified: st.modified, created: st.created,
            size: isDirectory ? nil : st.size, tags: [], isPackage: false, isDataless: isDataless, isAlias: isAlias,
            hidesExtension: hidesExtension
        )
        return DesktopEntry(key: TokenKey(volume: FilePrimitives.hexVolume(st.device), inode: st.inode), meta: meta)
    }

    /// A shortcut takes its target's kind: a program is an app, a folder a folder, a file by its extension; a
    /// shortcut whose target cannot be read is unknown.
    static func shortcutKind(_ url: URL) -> FileKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), let target = ShellLink.targetPath(of: data) else {
            return .unknown
        }
        let targetURL = URL(fileURLWithPath: target)
        if case let .success(t) = FilePrimitives.status(targetURL, follow: true), t.isDirectory { return .folder }
        return FileKindTable.kind(forExtension: targetURL.pathExtension)
    }
}
#endif

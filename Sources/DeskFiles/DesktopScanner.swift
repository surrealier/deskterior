import DeskCore
import Foundation
import UniformTypeIdentifiers

/// Lists the visible top-level items of the desktop folder (DESIGN §3.1 item 3). Reading only: resource
/// values and one extended-attribute probe; file contents are never opened, so iCloud items are never
/// downloaded. `scan` is synchronous; run it off the main thread.
public struct DesktopScanner: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No permission (TCC denied): the NO SIGNAL card.
        case accessDenied(String)
        case missing(String)
        case notADirectory(String)
        case unreadable(String, String)

        public var description: String {
            switch self {
            case let .accessDenied(p): "no permission to read \(p)"
            case let .missing(p): "folder not found: \(p)"
            case let .notADirectory(p): "not a folder: \(p)"
            case let .unreadable(p, why): "could not read \(p): \(why)"
            }
        }
    }

    /// The resource keys fetched for every item.
    public static let resourceKeys: [URLResourceKey] = [
        .fileIdentifierKey, .volumeUUIDStringKey, .isDirectoryKey, .isPackageKey, .localizedNameKey,
        .hasHiddenExtensionKey, .contentTypeKey, .addedToDirectoryDateKey, .contentModificationDateKey,
        .creationDateKey, .fileSizeKey, .tagNamesKey, .isAliasFileKey, .ubiquitousItemDownloadingStatusKey,
    ]

    /// Everything but the iCloud status. Asking for `.ubiquitousItemDownloadingStatusKey` in the same
    /// `URL.resourceValues` call drops `tagNames` (macOS 26), so the status is read on its own, and only when the
    /// folder is in iCloud (elsewhere the `SF_DATALESS` flag still catches file-provider placeholders).
    static let localKeys = Set(resourceKeys).subtracting([.ubiquitousItemDownloadingStatusKey])

    /// Extended attribute Finder sets on screenshots and screen recordings.
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// One complete listing. Throws instead of returning a partial one, so a failed scan never looks like
    /// a mass deletion.
    public func scan(now: Date = Date()) throws(Failure) -> DesktopSnapshot {
        let path = root.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw .missing(path) }
        guard isDir.boolValue else { throw .notADirectory(path) }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: Self.resourceKeys, options: [.skipsHiddenFiles]
            )
        } catch {
            throw Self.failure(error, path: path)
        }
        let rootValues = try? root.resourceValues(forKeys: [.volumeUUIDStringKey, .isUbiquitousItemKey])
        let rootVolume = rootValues?.volumeUUIDString ?? ""
        let inCloud = rootValues?.isUbiquitousItem ?? false
        var entries: [DesktopEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            // An item can vanish between listing and stat; it simply is not in this snapshot.
            guard let values = try? url.resourceValues(forKeys: Self.localKeys), let inode = values.fileIdentifier else {
                continue
            }
            let status = inCloud
                ? (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                : nil
            entries.append(Self.entry(url: url, values: values, status: status, inode: inode, rootVolume: rootVolume))
        }
        entries.sort { $0.meta.name < $1.meta.name }
        return DesktopSnapshot(
            rootPath: DesktopLocator.canonicalPath(root), rootVolume: rootVolume, entries: entries, scannedAt: now
        )
    }

    /// Scans on `queue` and calls `completion` there.
    public func scan(
        on queue: DispatchQueue, now: @escaping @Sendable () -> Date = { Date() },
        completion: @escaping @Sendable (Result<DesktopSnapshot, Failure>) -> Void
    ) {
        queue.async {
            do throws(Failure) {
                completion(.success(try scan(now: now())))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: Private

    private static func entry(
        url: URL, values: URLResourceValues, status: URLUbiquitousItemDownloadingStatus?, inode: UInt64, rootVolume: String
    ) -> DesktopEntry {
        let name = url.lastPathComponent
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isDataless = (status != nil && status != .current) || hasDatalessFlag(url)
        let type = values.contentType
        let isImage = type?.conforms(to: .image) ?? false
        let isCapture = isImage && !isDataless && hasScreenCaptureAttribute(url)
        let kind = FileKindClassifier.classify(
            name: name, contentType: type, isDirectory: isDirectory, isPackage: isPackage, isScreenCapture: isCapture
        )
        let meta = TokenMeta(
            name: name, kind: kind, added: values.addedToDirectoryDate, modified: values.contentModificationDate,
            created: values.creationDate, size: values.fileSize.map(Int64.init), tags: values.tagNames ?? [], isPackage: isPackage,
            isDataless: isDataless, isAlias: values.isAliasFile ?? false, hidesExtension: values.hasHiddenExtension ?? false
        )
        let volume = values.volumeUUIDString ?? (rootVolume.isEmpty ? "unknown" : rootVolume)
        return DesktopEntry(key: TokenKey(volume: volume, inode: inode), meta: meta)
    }

    /// `SF_DATALESS`: the content lives in a file provider (iCloud and others) and reading it would download.
    private static func hasDatalessFlag(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            var st = stat()
            guard let path, lstat(path, &st) == 0 else { return false }
            return st.st_flags & UInt32(SF_DATALESS) != 0
        }
    }

    private static func hasScreenCaptureAttribute(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, screenCaptureAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    private static func failure(_ error: Error, path: String) -> Failure {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileReadNoPermission.rawValue
            || posix == Int(EPERM) || posix == Int(EACCES)
        {
            return .accessDenied(path)
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileReadNoSuchFile.rawValue { return .missing(path) }
        return .unreadable(path, ns.localizedDescription)
    }
}

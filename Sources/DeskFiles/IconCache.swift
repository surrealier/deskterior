import CryptoKit
import DeskCore
import Foundation

/// Pixelated icons as PNG bytes in `~/Library/Caches/<bundleID>/icons/<sha1>.png` (DESIGN §3.4). The key
/// covers everything that changes the picture, so stale entries are simply never asked for again.
public struct IconCache: Sendable {
    public let directory: URL
    private let desktop: URL

    /// Refuses a directory inside the desktop folder; creates it otherwise.
    public init(directory: URL, desktop: URL = DesktopLocator.defaultDesktopURL()) throws {
        let dir = directory.standardizedFileURL
        if DesktopLocator.isInsideDesktop(dir, desktop: desktop) {
            throw SafetyGuard.Refusal(reason: .insideRealDesktop, path: dir.path)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        self.desktop = desktop
    }

    /// `~/Library/Caches/<bundleID>/icons`.
    public static func defaultDirectory(bundleID: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("icons", isDirectory: true)
    }

    /// `sha1(inode, mtime, size, kind, pixels, paletteVersion)` as 40 hex digits. The mtime counts in whole
    /// milliseconds, the precision `desk.json` keeps, so keys match before and after a relaunch.
    public static func key(
        inode: UInt64, modified: Date?, size: Int64?, kind: FileKind, pixels: Int, paletteVersion: Int
    ) -> String {
        let mtime = modified.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "-"
        let text = "\(inode)|\(mtime)|\(size.map(String.init) ?? "-")|\(kind.rawValue)|\(pixels)|\(paletteVersion)"
        return Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func url(for key: String) -> URL? {
        guard Self.isValidKey(key) else { return nil }
        return directory.appendingPathComponent("\(key).png", isDirectory: false)
    }

    public func load(_ key: String) -> Data? {
        url(for: key).flatMap { try? Data(contentsOf: $0) }
    }

    public func store(_ png: Data, for key: String) throws {
        guard let url = url(for: key) else { throw SafetyGuard.Refusal(reason: .outsideOwnRoot, path: key) }
        try SafetyGuard.checkOwnWrite(url, root: directory, desktop: desktop)
        try png.write(to: url, options: .atomic)
    }

    static func isValidKey(_ key: String) -> Bool {
        key.count == 40 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

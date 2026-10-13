import CryptoKit
import DeskCore
import Foundation

/// Saves and loads `desk.json` (DESIGN §4.8) in our own state folder, never anywhere else (not inside the real
/// desktop, not inside the mirrored folder).
///
/// Saves are atomic. Backups are generations by age, not by save: `.bak1` is refreshed from `desk.json` at most
/// hourly, `.bak2` from `.bak1` daily, `.bak3` from `.bak2` weekly, so a burst of saves (or a wiped layout saved
/// over and over) cannot push a good layout out of every backup. Loading falls back from an unreadable or corrupt
/// `desk.json` to `.bak1`, `.bak2`, `.bak3`, then a fresh desk, and keeps a corrupt file as
/// `desk.corrupt-<date>.json`. Only a missing `desk.json` is a fresh desk (that is how a reset looks), and a
/// `desk.json` from a newer Deskterior is never overwritten. The layout of a folder that is no longer mirrored
/// is kept aside per folder, so it comes back with the folder.
public struct StateStore: Sendable {
    public static let fileName = "desk.json"
    /// Minimum age of each backup generation before it is refreshed.
    public static let backupIntervals: [TimeInterval] = [3600, 24 * 3600, 7 * 24 * 3600]
    public static var backupCount: Int { backupIntervals.count }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// `desk.json` was written by a newer Deskterior: it is left as it is.
        case newerSchema(Int)
        case writeFailed(String)

        public var description: String {
            switch self {
            case let .newerSchema(n): "desk.json uses schema \(n), newer than \(Migrations.currentSchema); not overwriting it"
            case let .writeFailed(path): "could not write \(path)"
            }
        }
    }

    public enum Source: Sendable, Equatable {
        case primary
        case backup(Int)
        case fresh
    }

    public struct Loaded: Sendable {
        public var document: DeskDocument?
        public var source: Source
        /// Where a corrupt `desk.json` was kept.
        public var corruptCopy: URL?
        /// Human-readable reasons files were skipped.
        public var problems: [String]
    }

    public let directory: URL
    private let desktop: URL
    private let mirrored: URL?
    /// What `desk.json` looked like after our last write or check, so most saves need not read it back.
    private let memo = Memo()

    /// Refuses a directory inside the desktop folder or the mirrored folder; creates it otherwise.
    public init(directory: URL, desktop: URL = DesktopLocator.defaultDesktopURL(), mirrored: URL? = nil) throws {
        let dir = directory.standardizedFileURL
        try SafetyGuard.checkOwnFolder(dir, desktop: desktop, mirrored: mirrored)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        self.desktop = desktop
        self.mirrored = mirrored
    }

    /// `~/Library/Application Support/<bundleID>`.
    public static func defaultDirectory(bundleID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    public func backupURL(_ n: Int) -> URL {
        directory.appendingPathComponent("\(Self.fileName).bak\(n)", isDirectory: false)
    }

    /// `desk.<sha1(rootPath)>.json`: the layout kept for a folder that is not mirrored now.
    public func asideURL(rootPath: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(rootPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("desk.\(digest).json", isDirectory: false)
    }

    // MARK: Load

    public func load(now: Date = Date()) -> Loaded {
        var problems: [String] = []
        var corruptCopy: URL?
        do {
            let data = try Data(contentsOf: fileURL)
            do {
                let doc = try DeskDocument.decode(data)
                memo.remember(fileURL, schemaOK: true)
                return Loaded(document: doc, source: .primary, corruptCopy: nil, problems: [])
            } catch let Migrations.Failure.newerSchema(n) {
                problems.append("\(Self.fileName): written by a newer Deskterior (schema \(n)); left untouched")
            } catch {
                problems.append("\(Self.fileName): \(error)")
                corruptCopy = keepCorrupt(data, now: now)
            }
        } catch {
            guard !Self.isMissing(error) else {
                return Loaded(document: nil, source: .fresh, corruptCopy: nil, problems: [])
            }
            problems.append("\(Self.fileName): unreadable (\(error.localizedDescription))")
        }
        for n in 1...Self.backupCount {
            guard let data = try? Data(contentsOf: backupURL(n)) else { continue }
            do {
                let doc = try DeskDocument.decode(data)
                return Loaded(document: doc, source: .backup(n), corruptCopy: corruptCopy, problems: problems)
            } catch {
                problems.append("\(Self.fileName).bak\(n): \(error)")
            }
        }
        return Loaded(document: nil, source: .fresh, corruptCopy: corruptCopy, problems: problems)
    }

    /// The layout kept aside for `rootPath`, if any.
    public func loadAside(rootPath: String) -> DeskDocument? {
        (try? Data(contentsOf: asideURL(rootPath: rootPath))).flatMap { try? DeskDocument.decode($0) }
    }

    // MARK: Save

    public func save(_ state: DeskState, now: Date = Date()) throws {
        try save(DeskDocument(state: state, savedAt: now), now: now)
    }

    /// Refreshes the backup generations that are due and writes atomically. Throws `.newerSchema` instead of
    /// overwriting a newer `desk.json`.
    public func save(_ document: DeskDocument, now: Date = Date()) throws {
        let data = try document.encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var current: Data?
        if !memo.matches(fileURL) {
            current = try? Data(contentsOf: fileURL)
            if let current, let n = try? Migrations.schema(of: current), n > Migrations.currentSchema {
                throw Failure.newerSchema(n)
            }
        }
        try rotateBackups(now: now) {
            let primary = current ?? (try? Data(contentsOf: fileURL))
            // Only a readable document of a schema we know becomes a backup.
            guard let primary, let n = try? Migrations.schema(of: primary), n <= Migrations.currentSchema else {
                return nil
            }
            return primary
        }
        try write(data, to: fileURL)
        memo.remember(fileURL, schemaOK: true)
    }

    /// Keeps the layout of `state.root` aside (before mirroring another folder).
    public func saveAside(_ state: DeskState, now: Date = Date()) throws {
        guard let root = state.root else { return }
        try write(DeskDocument(state: state, savedAt: now).encoded(), to: asideURL(rootPath: root.path))
    }

    /// Before mirroring a different folder: keeps the current folder's layout aside and brings back the layout
    /// last kept for `rootPath`, if any (otherwise the reconciler starts that folder fresh).
    public func switchRoot(_ state: inout DeskState, to rootPath: String, now: Date = Date()) throws {
        guard let root = state.root, root.path != rootPath else { return }
        try saveAside(state, now: now)
        if let kept = loadAside(rootPath: rootPath) { state.adoptLayout(of: kept.makeState()) }
    }

    // MARK: Private

    /// Shifts due generations down (`.bak3` ← `.bak2` ← `.bak1` ← `desk.json`), oldest first. A generation's
    /// modification date is when it was last refreshed.
    private func rotateBackups(now: Date, primary: () -> Data?) throws {
        func isDue(_ n: Int) -> Bool {
            guard let date = (try? backupURL(n).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            else { return true }
            let age = now.timeIntervalSince(date)
            return age < 0 || age >= Self.backupIntervals[n - 1]
        }
        for n in stride(from: Self.backupCount, to: 1, by: -1) where isDue(n) {
            if let older = try? Data(contentsOf: backupURL(n - 1)) { try write(older, to: backupURL(n), stamped: now) }
        }
        if isDue(1), let data = primary() { try write(data, to: backupURL(1), stamped: now) }
    }

    /// Atomic replace with fresh permissions, so a file someone made unreadable heals on the next save.
    private func write(_ data: Data, to url: URL, stamped date: Date? = nil) throws {
        try SafetyGuard.checkOwnWrite(url, root: directory, desktop: desktop, mirrored: mirrored)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
        if let date { attributes[.modificationDate] = date }
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: attributes) else {
            throw Failure.writeFailed(url.path)
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileReadNoSuchFile.rawValue { return true }
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)
    }

    /// Copies a corrupt file aside as `desk.corrupt-<UTC date>[-n].json`.
    private func keepCorrupt(_ data: Data, now: Date) -> URL? {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: now)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
            c.second ?? 0
        )
        for n in 1...100 {
            let name = n == 1 ? "desk.corrupt-\(stamp).json" : "desk.corrupt-\(stamp)-\(n).json"
            let url = directory.appendingPathComponent(name, isDirectory: false)
            if let existing = try? Data(contentsOf: url) {
                if existing == data { return url }
                continue
            }
            return (try? write(data, to: url)) != nil ? url : nil
        }
        return nil
    }

    /// The identity (inode, size, modification date) of `desk.json` as we last wrote or read it.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var stamp: [Int64]?

        func remember(_ url: URL, schemaOK: Bool) {
            let s = schemaOK ? Self.stamp(url) : nil
            lock.withLock { stamp = s }
        }

        func matches(_ url: URL) -> Bool {
            guard let now = Self.stamp(url) else { return false }
            return lock.withLock { stamp == now }
        }

        private static func stamp(_ url: URL) -> [Int64]? {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            return [Int64(st.st_ino), Int64(st.st_size), Int64(st.st_mtimespec.tv_sec), Int64(st.st_mtimespec.tv_nsec)]
        }
    }
}

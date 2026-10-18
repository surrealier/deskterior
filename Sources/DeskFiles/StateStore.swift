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
/// is kept aside per folder, so it comes back with the folder. `memos.json` (Erratum 31: notes, day pages, the
/// D-Day) is kept the same way beside it, and Reset Layout leaves it alone.
public struct StateStore: Sendable {
    public static let fileName = "desk.json"
    /// Minimum age of each backup generation before it is refreshed.
    public static let backupIntervals: [TimeInterval] = [3600, 24 * 3600, 7 * 24 * 3600]
    public static var backupCount: Int { backupIntervals.count }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// `desk.json` was written by a newer Deskterior: it is left as it is.
        case newerSchema(Int)
        case writeFailed(String)
        // MARK: memos (0.3.0)
        /// `memos.json` was written by a newer Deskterior: it is left as it is.
        case newerMemos(Int)
        /// `memos.json` is there but could not be read (or kept aside when corrupt): it is never written over.
        case memosUnreadable(String)

        public var description: String {
            switch self {
            case let .newerSchema(n): "desk.json uses schema \(n), newer than \(Migrations.currentSchema); not overwriting it"
            case let .writeFailed(path): "could not write \(path)"
            case let .newerMemos(n):
                "\(StateStore.memosFileName) uses schema \(n), newer than \(MemoDocument.currentSchema); not overwriting it"
            case let .memosUnreadable(why): "\(StateStore.memosFileName) \(why); not overwriting it"
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
    /// The same for `memos.json`.
    private let memosMemo = Memo()

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
                corruptCopy = keepCorrupt(data, now: now, stem: "desk")
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
        try rotateBackups(of: backupURL, now: now) {
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

    // MARK: system (M12)

    /// Safe Mode's Reset Layout: keeps the saved layout (the file a load finds, `desk.json` or a backup) byte for byte
    /// as `desk.reset-<UTC date>.json`, then saves a fresh desk that keeps only the mirrored folder and the lights, so
    /// every file returns to the monitor at the next scan. Only our own state files are written; nothing is deleted.
    /// Returns the kept copy, or nil when there was no saved layout.
    public func resetLayout(now: Date = Date()) throws -> URL? {
        let loaded = load(now: now)
        guard let document = loaded.document else { return nil }
        let source: URL = switch loaded.source {
        case let .backup(n): backupURL(n)
        case .primary, .fresh: fileURL
        }
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: now)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
            c.second ?? 0
        )
        var kept = directory.appendingPathComponent("desk.reset-\(stamp).json", isDirectory: false)
        var n = 2
        while FileManager.default.fileExists(atPath: kept.path) {
            kept = directory.appendingPathComponent("desk.reset-\(stamp)-\(n).json", isDirectory: false)
            n += 1
        }
        // The file as it is (unknown fields, formatting and all), not the document as this build would write it.
        try write(Data(contentsOf: source), to: kept)
        let old = document.makeState()
        var fresh = DeskState()
        fresh.root = old.root
        fresh.lights = old.lights
        try save(fresh, now: now)
        return kept
    }

    // MARK: Private

    /// Shifts due generations down (`.bak3` ← `.bak2` ← `.bak1` ← the file), oldest first. A generation's
    /// modification date is when it was last refreshed. `backupURL(n)` names generation `n` (`desk.json`'s or
    /// `memos.json`'s), and `read` reads one. Not `strict`, a generation that cannot be written (a symlink planted
    /// there, which `checkOwnWrite` refuses to follow) is skipped instead of stopping the save.
    private func rotateBackups(
        of backupURL: (Int) -> URL, now: Date, read: (URL) -> Data? = { try? Data(contentsOf: $0) },
        strict: Bool = true, primary: () -> Data?
    ) throws {
        func isDue(_ n: Int) -> Bool {
            guard let date = (try? backupURL(n).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            else { return true }
            let age = now.timeIntervalSince(date)
            return age < 0 || age >= Self.backupIntervals[n - 1]
        }
        func refresh(_ n: Int, with data: Data) throws {
            do {
                try write(data, to: backupURL(n), stamped: now)
            } catch {
                if strict { throw error }
            }
        }
        for n in stride(from: Self.backupCount, to: 1, by: -1) where isDue(n) {
            if let older = read(backupURL(n - 1)) { try refresh(n, with: older) }
        }
        if isDue(1), let data = primary() { try refresh(1, with: data) }
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

    /// Copies a corrupt file aside as `<stem>.corrupt-<UTC date>[-n].json` (`desk` or `memos`).
    private func keepCorrupt(_ data: Data, now: Date, stem: String) -> URL? {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: now)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
            c.second ?? 0
        )
        for n in 1...100 {
            let name = n == 1 ? "\(stem).corrupt-\(stamp).json" : "\(stem).corrupt-\(stamp)-\(n).json"
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

// MARK: memos (0.3.0)

extension StateStore {
    /// The sticky notes, day pages and D-Day, beside `desk.json` (Erratum 31).
    public static let memosFileName = "memos.json"
    /// The most of a memos file that is read: a runaway or planted file is not loaded whole (it is left untouched).
    public static let maxMemosBytes = 32 << 20

    /// What `loadMemos` found: the book (nil: none could be read), whether `saveMemos` may write (false when the
    /// file came from a newer Deskterior), and why files were skipped.
    public struct MemosLoaded: Sendable {
        public var book: MemoBook?
        public var writable: Bool
        public var problems: [String]
        /// Where a corrupt `memos.json` was kept.
        public var corruptCopy: URL?

        public init(book: MemoBook?, writable: Bool, problems: [String] = [], corruptCopy: URL? = nil) {
            self.book = book
            self.writable = writable
            self.problems = problems
            self.corruptCopy = corruptCopy
        }
    }

    public var memosURL: URL { directory.appendingPathComponent(Self.memosFileName, isDirectory: false) }

    public func memosBackupURL(_ n: Int) -> URL {
        directory.appendingPathComponent("\(Self.memosFileName).bak\(n)", isDirectory: false)
    }

    /// Loads `memos.json`, as `load` does `desk.json`: a missing file is a fresh book (nil, writable); an unreadable
    /// or corrupt one falls back to `.bak1`, `.bak2`, `.bak3`, and a corrupt one is kept as
    /// `memos.corrupt-<UTC date>.json` first. Never writable over what must not be lost: a file from a newer
    /// Deskterior, one that could not be read (not a regular file, no permission, past `maxMemosBytes`) or a corrupt
    /// one that could not be kept aside; then the book shown is a backup's, or none, and nothing is saved over it.
    /// Reads go through no symlink and never block on a planted FIFO.
    public func loadMemos(now: Date = Date()) -> MemosLoaded {
        var problems: [String] = []
        var corruptCopy: URL?
        var writable = true
        let name = Self.memosFileName
        switch Self.readOwnFile(memosURL) {
        case .missing:
            return MemosLoaded(book: nil, writable: true)
        case let .data(data):
            switch Self.decodeMemos(data) {
            case let .success(doc):
                memosMemo.remember(memosURL, schemaOK: true)
                return MemosLoaded(book: doc.makeBook(), writable: true)
            case let .failure(.newer(n)):
                problems.append("\(name): written by a newer Deskterior (schema \(n)); left untouched")
                writable = false
            case let .failure(.corrupt(why)):
                problems.append("\(name): \(why)")
                corruptCopy = keepCorrupt(data, now: now, stem: "memos")
                if corruptCopy == nil {
                    problems.append("\(name): could not be kept aside; left untouched")
                    writable = false
                } else {
                    memosMemo.remember(memosURL, schemaOK: true) // Kept aside: a save may replace it.
                }
            }
        case let .unreadable(why):
            problems.append("\(name): \(why); left untouched")
            writable = false
        }
        for n in 1...Self.backupCount {
            guard case let .data(data) = Self.readOwnFile(memosBackupURL(n)) else { continue }
            switch Self.decodeMemos(data) {
            case let .success(doc):
                return MemosLoaded(book: doc.makeBook(), writable: writable, problems: problems, corruptCopy: corruptCopy)
            case let .failure(f):
                problems.append("\(name).bak\(n): \(f)")
            }
        }
        return MemosLoaded(book: nil, writable: writable, problems: problems, corruptCopy: corruptCopy)
    }

    /// Saves `memos.json` atomically, refreshing its backup generations by age as `save` does `desk.json`'s, and
    /// writes nothing else (and nothing outside the state folder: `SafetyGuard.checkOwnWrite`). Throws instead of
    /// writing over a `memos.json` from a newer Deskterior (`.newerMemos`) or one it cannot read
    /// (`.memosUnreadable`); a corrupt one found here is kept aside first, as `loadMemos` does.
    public func saveMemos(_ book: MemoBook, now: Date = Date()) throws {
        let data = try MemoDocument(book: book, savedAt: now).encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var current: Data?
        if !memosMemo.matches(memosURL) {
            switch Self.readOwnFile(memosURL) {
            case .missing:
                break
            case let .data(found):
                switch Self.decodeMemos(found) {
                case .success:
                    current = found
                case let .failure(.newer(n)):
                    throw Failure.newerMemos(n)
                case .failure(.corrupt):
                    guard keepCorrupt(found, now: now, stem: "memos") != nil else {
                        throw Failure.memosUnreadable("is corrupt and could not be kept aside")
                    }
                }
            case let .unreadable(why):
                throw Failure.memosUnreadable(why)
            }
        }
        // Backups are read as `memos.json` is (never through a symlink, never blocking on a FIFO), and one that cannot
        // be refreshed never keeps the user's text from being saved.
        let readOwn = { (url: URL) -> Data? in if case let .data(d) = Self.readOwnFile(url) { d } else { nil } }
        try rotateBackups(of: memosBackupURL, now: now, read: readOwn, strict: false) {
            // Only a readable document of a schema we know becomes a backup.
            guard case let .data(primary) = current.map(OwnFile.data) ?? Self.readOwnFile(memosURL),
                  case .success = Self.decodeMemos(primary)
            else { return nil }
            return primary
        }
        try write(data, to: memosURL)
        memosMemo.remember(memosURL, schemaOK: true)
    }

    // MARK: Memos inside

    /// What reading one of our own files found.
    enum OwnFile: Equatable {
        case missing
        case data(Data)
        /// There, but not read: why.
        case unreadable(String)
    }

    /// Reads the regular file at `url` itself: not through a symlink (`O_NOFOLLOW`), without blocking on a FIFO
    /// (`O_NONBLOCK`), and at most `maxBytes` of it.
    static func readOwnFile(_ url: URL, maxBytes: Int = StateStore.maxMemosBytes) -> OwnFile {
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
        guard fd >= 0 else {
            return failure == ENOENT ? .missing : .unreadable("unreadable (\(String(cString: strerror(failure))))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable("unreadable (\(String(cString: strerror(errno))))") }
        guard st.st_mode & S_IFMT == S_IFREG else { return .unreadable("is not a regular file") }
        guard st.st_size <= maxBytes else { return .unreadable("is \(st.st_size) bytes, more than \(maxBytes)") }
        do {
            let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            return data.count <= maxBytes ? .data(data) : .unreadable("is more than \(maxBytes) bytes")
        } catch {
            return .unreadable("unreadable (\(error.localizedDescription))")
        }
    }

    /// Why a memos document was not taken.
    enum MemosProblem: Error, Equatable, CustomStringConvertible {
        /// Written by a newer Deskterior (its schema).
        case newer(Int)
        case corrupt(String)

        var description: String {
            switch self {
            case let .newer(n): "written by a newer Deskterior (schema \(n))"
            case let .corrupt(why): why
            }
        }
    }

    /// `data` as a memos document: refused when its schema is newer than this build's (checked here as well as by
    /// `MemoDocument.decode`), or when it does not decode.
    static func decodeMemos(_ data: Data) -> Result<MemoDocument, MemosProblem> {
        if let n = try? Migrations.schema(of: data), n > MemoDocument.currentSchema { return .failure(.newer(n)) }
        do {
            return .success(try MemoDocument.decode(data))
        } catch let Migrations.Failure.newerSchema(n) {
            return .failure(.newer(n))
        } catch Migrations.Failure.notAnObject {
            return .failure(.corrupt("not a JSON object")) // Migrations' own words name desk.json.
        } catch Migrations.Failure.missingSchema {
            return .failure(.corrupt("no schema number"))
        } catch {
            return .failure(.corrupt("\(error)"))
        }
    }
}

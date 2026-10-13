import DeskCore
import Foundation

/// Saves and loads `desk.json` (DESIGN §4.8) in our own state folder, never anywhere else.
///
/// Saves are atomic and rotate three backups (`desk.json.bak1` newest … `.bak3`). Loading falls back from a
/// corrupt `desk.json` to `.bak1`, `.bak2`, `.bak3`, then a fresh desk, and keeps the bad file as
/// `desk.corrupt-<date>.json`. A missing `desk.json` is a fresh desk (that is how a reset looks).
public struct StateStore: Sendable {
    public static let fileName = "desk.json"
    public static let backupCount = 3

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

    // MARK: Load

    public func load(now: Date = Date()) -> Loaded {
        var problems: [String] = []
        var corruptCopy: URL?
        if let data = try? Data(contentsOf: fileURL) {
            do {
                return Loaded(document: try DeskDocument.decode(data), source: .primary, corruptCopy: nil, problems: [])
            } catch {
                problems.append("\(Self.fileName): \(error)")
                corruptCopy = keepCorrupt(data, now: now)
            }
        } else {
            return Loaded(document: nil, source: .fresh, corruptCopy: nil, problems: [])
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

    // MARK: Save

    public func save(_ state: DeskState, now: Date = Date()) throws {
        try save(DeskDocument(state: state, savedAt: now))
    }

    /// Rotates the backups (only when the current file is a readable document) and writes atomically.
    public func save(_ document: DeskDocument) throws {
        let data = try document.encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let current = try? Data(contentsOf: fileURL), (try? Migrations.schema(of: current)) != nil {
            for n in stride(from: Self.backupCount, to: 1, by: -1) {
                if let older = try? Data(contentsOf: backupURL(n - 1)) { try write(older, to: backupURL(n)) }
            }
            try write(current, to: backupURL(1))
        }
        try write(data, to: fileURL)
    }

    // MARK: Private

    private func write(_ data: Data, to url: URL) throws {
        try SafetyGuard.checkOwnWrite(url, root: directory, desktop: desktop)
        try data.write(to: url, options: .atomic)
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
}

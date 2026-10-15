import Foundation
import os

/// The append-only record of every file action (DESIGN §3.7 item 6): one JSON object per line in
/// `<state dir>/operations.log`, mirrored to the unified log. Lines are only ever appended, never rewritten. When
/// a line would take the file past `maxBytes`, the file becomes `operations.log.1` (replacing the previous one)
/// and a new file starts, so the log stays under about twice `maxBytes`. The folder is checked to be outside the
/// desktop folder and the mirrored folder when the log is made and before every write.
public final class OperationLog: @unchecked Sendable {
    public static let fileName = "operations.log"
    public static let defaultMaxBytes = 1 << 20

    /// One line of the log.
    public struct Entry: Codable, Sendable, Equatable {
        public enum Op: String, Codable, Sendable {
            case trash
            case importMove = "import-move"
            case importCopy = "import-copy"
            /// Undo of a trash.
            case putBack = "put-back"
            /// Undo of a drop-in move.
            case moveBack = "move-back"
            /// Undo of a drop-in copy.
            case trashCopy = "trash-copy"
            // MARK: alias (Erratum 29)
            /// A drop-in that made an alias of the item (the item itself only read).
            case importAlias = "import-alias"
            /// Undo of a drop-in alias.
            case trashAlias = "trash-alias"
            case eject
        }

        public var time: Date
        public var op: Op
        public var origin: ExplicitIntent.Origin
        /// The item's name, then its new name when that differs.
        public var names: [String]
        /// The item's inode (before and after a copy).
        public var inodes: [UInt64]
        /// `ok`, `renamed`, `unchanged` or `refused: <reason>`.
        public var outcome: String

        public init(
            time: Date, op: Op, origin: ExplicitIntent.Origin, names: [String], inodes: [UInt64], outcome: String
        ) {
            self.time = time
            self.op = op
            self.origin = origin
            self.names = names
            self.inodes = inodes
            self.outcome = outcome
        }
    }

    public enum Failure: Error, Equatable {
        /// `open`/`write`/`rename` failed with this errno.
        case writeFailed(Int32)
    }

    public let directory: URL
    public let maxBytes: Int
    private let desktop: URL
    private let mirrored: URL?
    private let lock = NSLock()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "deskterior", category: "files")

    /// Refuses a directory inside the desktop folder or the mirrored folder; creates it otherwise.
    public init(
        directory: URL, desktop: URL = DesktopLocator.defaultDesktopURL(), mirrored: URL? = nil,
        maxBytes: Int = OperationLog.defaultMaxBytes
    ) throws {
        let dir = directory.standardizedFileURL
        try SafetyGuard.checkOwnFolder(dir, desktop: desktop, mirrored: mirrored)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        self.desktop = desktop
        self.mirrored = mirrored
        self.maxBytes = max(1, maxBytes)
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }
    public var rotatedURL: URL { directory.appendingPathComponent(Self.fileName + ".1", isDirectory: false) }

    /// Appends one line (rotating first when it would not fit).
    public func append(_ entry: Entry) throws {
        let line = Self.encode(entry) + "\n"
        Self.logger.notice("\(line, privacy: .private)")
        try lock.withLock {
            try SafetyGuard.checkOwnWrite(fileURL, root: directory, desktop: desktop, mirrored: mirrored)
            try SafetyGuard.checkOwnWrite(rotatedURL, root: directory, desktop: desktop, mirrored: mirrored)
            var st = stat()
            let size = lstat(fileURL.path, &st) == 0 ? Int(st.st_size) : 0
            if size > 0, size + line.utf8.count > maxBytes, rename(fileURL.path, rotatedURL.path) != 0 {
                throw Failure.writeFailed(errno)
            }
            try appendBytes(Data(line.utf8))
        }
    }

    /// Every readable entry, oldest first (the rotated file, then the current one). Unreadable lines are skipped.
    public func entries() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lock.withLock {
            [rotatedURL, fileURL].flatMap { url -> [Entry] in
                guard let data = Self.readRegularFile(url) else { return [] }
                return data.split(separator: UInt8(ascii: "\n")).compactMap {
                    try? decoder.decode(Entry.self, from: Data($0))
                }
            }
        }
    }

    static func encode(_ entry: Entry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entry)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// `O_APPEND` without following a symlink, so a planted link cannot redirect the log, and without blocking:
    /// anything but a regular file there (a planted FIFO) is refused instead of hanging the caller.
    private func appendBytes(_ data: Data) throws {
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Failure.writeFailed(errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure.writeFailed(errno) }
        guard st.st_mode & S_IFMT == S_IFREG else { throw Failure.writeFailed(EFTYPE) }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.writeFailed(errno)
                }
                offset += n
            }
        }
    }

    /// The contents of the regular file at `url` (a symlink or FIFO there is not opened or not read), or nil.
    private static func readRegularFile(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? handle.readToEnd() ?? Data()
    }
}

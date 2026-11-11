import DeskCore
import Foundation

/// An errno value (0 = success). Win32 errors are mapped to these in `FilePrimitives+Windows.swift`, so
/// `FileRefusal.from(errno:)` and `FileMoves.Failure.errno` stay the one place that interprets them.
typealias Errno = Int32

/// An errno as a `Result` failure. Matches an errno constant in a pattern: `case .failure(ENOENT):`.
struct FileErrno: Error, Equatable, Sendable {
    var code: Int32

    init(_ code: Int32) { self.code = code }

    static func ~= (pattern: Int32, value: FileErrno) -> Bool { pattern == value.code }
}

/// What reading one of our own files found: its bytes, or that it is bigger than allowed (its size when known).
enum OwnFileRead: Equatable {
    case data(Data)
    case tooLarge(Int64?)
}

/// The low-level file calls of DeskFiles, one implementation per platform (docs/WINDOWS.md WP5):
/// `FilePrimitives+POSIX.swift` (macOS, and Linux for development) and `FilePrimitives+Windows.swift`.
/// Everything above them (intent checks, root confinement, check → act → re-check, undo, the log) is shared, so
/// the safety rules exist once. The calls that change files are used only by `FileOperator`, `FileMoves`, the
/// trashers and our own writers (state, log); the file-safety lint holds them to those files.
enum FilePrimitives {
    enum Kind: Equatable, Sendable {
        case regular, directory, link, other
    }

    /// What `lstat`/`stat` (or Windows' handle information) says about one item.
    struct Status: Equatable, Sendable {
        /// The volume: `st_dev`, or the volume serial number on Windows.
        var device: UInt64
        /// The item on its volume: `st_ino`, or the file index on Windows.
        var inode: UInt64
        var kind: Kind
        var size: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        /// `st_flags` on macOS, the file attributes on Windows, 0 on Linux.
        var flags: UInt32
        /// The creation time where the platform reports it here (Windows).
        var created: Date? = nil

        var isDirectory: Bool { kind == .directory }
        var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1e9) }
    }

    /// The result of `status`: the item's facts, or the errno.
    typealias StatusResult = Result<Status, FileErrno>

    // `status(_ url:follow:)` and `status(path:follow:)`: the item itself (`follow == false`: a symlink, junction or
    // other name-surrogate reparse point is not followed), or the errno. One per platform file.

    /// `volumeID` of the item's own volume as a 16-digit hex string when the platform has no volume UUID.
    static func hexVolume(_ device: UInt64) -> String {
        let hex = String(device, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

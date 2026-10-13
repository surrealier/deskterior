import Foundation

/// Proof that the user asked for a file change just now (DESIGN §3.7 item 2). Every mutating `FileOperator`
/// method takes one and refuses it once it is older than `maxAge`.
///
/// Minted only in `DeskteriorApp/Store/EffectRunner.swift`, from menu, confirm-sheet, drop, drag-to-Trash, Undo
/// and Inventory handlers (file-safety lint). DeskCore and DeskScene cannot import DeskFiles, so they cannot make
/// one. Deliberately not `Codable`: an intent is never read back from anywhere.
public struct ExplicitIntent: Sendable, Equatable {
    /// The user action behind the intent.
    public enum Origin: String, Sendable, Codable, CaseIterable {
        /// A menu item: a token's context menu, the basket menu, the drive menu, the status menu.
        case menuItem
        /// The confirm button of a sheet (Empty Wastebasket…).
        case sheetConfirm
        /// Files dropped onto the desk from outside.
        case drop
        /// A drag that ended on the Dock Trash (DESIGN §3.6, `.delete`).
        case dragToTrash
        /// Undo of an earlier file action.
        case undo
        /// A button in the Inventory window.
        case inventory
    }

    /// Intents older than this are stale.
    public static let maxAge: TimeInterval = 10
    /// How far in the future `issuedAt` may lie (wall-clock adjustments); beyond it the intent is refused.
    public static let futureTolerance: TimeInterval = 1

    public let origin: Origin
    public let issuedAt: Date

    public init(origin: Origin, issuedAt: Date) {
        self.origin = origin
        self.issuedAt = issuedAt
    }

    /// Seconds since the intent was issued, as of `now`.
    public func age(at now: Date) -> TimeInterval { now.timeIntervalSince(issuedAt) }

    /// Issued no more than `maxAge` before `now`, and not later than `now` (beyond `futureTolerance`).
    public func isFresh(at now: Date, maxAge: TimeInterval = ExplicitIntent.maxAge) -> Bool {
        let a = age(at: now)
        return a >= -Self.futureTolerance && a <= maxAge
    }
}

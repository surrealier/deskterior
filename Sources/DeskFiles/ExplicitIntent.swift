import Foundation

/// Proof that the user asked for a file change just now (DESIGN §3.7 item 2). Every mutating `FileOperator`
/// method takes one and spends it: it acts only while the intent is fresh (`maxAge`, on the monotonic clock), only
/// if `IntentLedger` issued it and nothing spent it yet, and only when its origin fits the method.
///
/// Minted only in `DeskteriorApp/Store/EffectRunner.swift`, from menu, confirm-sheet, drop, drag-to-Trash, Undo
/// and Inventory handlers. The initializer is SPI: only a file that says `@_spi(IntentMinting) import DeskFiles`
/// can call it, and the file-safety lint allows that import in EffectRunner alone. DeskCore and DeskScene cannot
/// import DeskFiles at all. A copied, replayed or forged value (one the ledger never issued) is refused.
/// Deliberately not `Codable`: an intent is never read back from anywhere.
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
    public static let maxAge: Duration = .seconds(10)
    /// How far in the future an intent may lie (a test clock); beyond it the intent is refused.
    public static let futureTolerance: Duration = .seconds(1)

    public let origin: Origin
    /// Wall-clock time of issue, for the operation log.
    public let issuedAt: Date
    /// Monotonic time of issue: freshness is measured on this, so changing the system clock changes nothing.
    let instant: ContinuousClock.Instant
    /// The ledger entry this intent spends.
    let id: UUID

    /// Mints an intent for a user action happening now.
    @_spi(IntentMinting) public init(origin: Origin) {
        self.init(origin: origin, issuedAt: Date(), instant: .now)
    }

    /// Issues an intent with explicit times (tests use their own clock).
    init(origin: Origin, issuedAt: Date, instant: ContinuousClock.Instant) {
        self.origin = origin
        self.issuedAt = issuedAt
        self.instant = instant
        id = UUID()
        IntentLedger.shared.issue(id)
    }

    /// Time since the intent was issued, as of `now`.
    func age(at now: ContinuousClock.Instant) -> Duration { instant.duration(to: now) }

    /// Issued no more than `maxAge` before `now`, and not later than `now` (beyond `futureTolerance`).
    func isFresh(at now: ContinuousClock.Instant, maxAge: Duration = ExplicitIntent.maxAge) -> Bool {
        let a = age(at: now)
        return a >= .zero - Self.futureTolerance && a <= maxAge
    }
}

/// The intents issued in this process and not yet spent. `FileOperator` spends each one with its first request;
/// an id the ledger never issued (a forged value) or already spent (a copy) is refused. Entries older than
/// `horizon` are dropped: their intents are long stale.
final class IntentLedger: @unchecked Sendable {
    static let shared = IntentLedger()
    static let horizon: Duration = .seconds(60)

    private let lock = NSLock()
    private var open: [UUID: ContinuousClock.Instant] = [:]

    func issue(_ id: UUID) {
        let now = ContinuousClock.now
        lock.withLock {
            open = open.filter { $0.value.duration(to: now) <= Self.horizon }
            open[id] = now
        }
    }

    /// True the first time an issued id is spent; false for any other id.
    func spend(_ id: UUID) -> Bool {
        lock.withLock { open.removeValue(forKey: id) != nil }
    }
}

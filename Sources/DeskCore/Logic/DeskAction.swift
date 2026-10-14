import Foundation

/// Everything that can change the desk model (DESIGN §4.2). Continuous motion never dispatches per frame;
/// only settles and user intents arrive here.
public enum DeskAction: Sendable {
    // Mirror
    /// A fresh listing of the desktop folder.
    case snapshot(DesktopSnapshot, now: Date)
    case volumes([VolumeEntry])
    /// The folder could not be read (TCC denied): NO SIGNAL.
    case accessDenied
    /// Access was granted through user intent (Choose Folder…); a scan follows.
    case accessGranted
    /// Finder hides desktop items and the user has not chosen to show them: the DESKTOP HIDDEN card.
    case finderHidesItems

    // Layout
    case move([TokenKey], to: Location)
    /// Commits from scene motion (landings, sweeps).
    case settle(SettleReport)
    case power(Bool)
    case setPage(Int)
    /// INPUT button: HDMI 1…n, then AV, then HDMI 1.
    case cycleInput
    /// Monitor ▸ Input ▸ AV: the always-empty input.
    case selectAV
    /// Monitor ▸ Clean Up By.
    case cleanUp(ScreenGrid.SortKey)
    case drawerSettled(ContainerID, Float)
    case phoneFlip
    case cupState(PenCupState)
    case basketState(BasketState)
    case matSettled(MatState)
    case pilesSettled([PileID: SIMD2<Float>])
    /// Chair x and facing frame.
    case chair(Float, Int)
    case lights(LightsState)
    /// Container ▸ Take All Out; nil takes out the loose desk piles and floor tokens.
    case takeAllOut(ContainerID?)
    case takeEverythingOut
    /// Clear the Desk (presentation mode; the plan arrives in M9).
    case clearDesk
    case showOnDesk(TokenKey)
    /// Undo and redo step through an `UndoJournal` (`Reducer.reduce(_:journal:_:_:)`); plain `reduce` ignores them.
    case undo
    case redo
    /// Our own operations announce where the files they create should land (name → location, 10 s TTL).
    case registerHints([String: Location])

    // Explicit requests (the only actions that may emit file effects)
    /// ⏻ on the connect prompt, or Show on the DESKTOP HIDDEN card: run the first enumeration.
    case requestConnect
    case requestOpen([TokenKey])
    case requestQuickLook([TokenKey])
    case requestReveal([TokenKey])
    case requestCopy([TokenKey])
    case requestTrash([TokenKey])
    case requestEmptyWastebasket
    /// Eject the volume with this `VolumeEntry.id`.
    case requestEject(String)
    case importDropped([URL], at: Location, op: ImportOp)
    case requestPrivacySettings
    case requestChooseFolder

    case clock(Date)

    // MARK: containers (M6)
    /// Open… / Show on Desk: a drawer opens all the way (a cabinet drawer closes the other two and rolls the chair
    /// clear), the phone turns face up (`Reducer.revealContainer`).
    case openContainer(ContainerID)
    /// Close: a drawer shuts to its rest (an overfull one stays ajar at its gap), the phone turns face down.
    case closeContainer(ContainerID)
    /// The phone face down or up: absolute, so a repeated or late commit never flips it the wrong way.
    case phoneFace(down: Bool)
    // MARK: physics
    /// Tokens set down on the bare desk (a drop, a fling's landing) join `pile` at desk-plane point `at`: a new pile
    /// is made there, and a pile the drop takes whole moves there; an existing pile keeps its place. Journaled.
    case dropOnDesk([TokenKey], pile: PileID, at: SIMD2<Float>)
    /// Tokens landing together on the floor at core x `x` (a fling's landing): they stand there as one floor stack.
    /// Journaled.
    case dropOnFloor([TokenKey], x: Int)
    /// The pen cup's or the wastebasket's Tip Over / Stand Up menu item: the scene plays it and commits the result
    /// (`cupState`/`basketState`, then `settle`).
    case tipOver(ContainerID)
    case standUp(ContainerID)

    /// Explicit user requests. Only these may produce file effects (`Effect.touchesFiles`).
    public var isRequest: Bool {
        switch self {
        case .requestConnect, .requestOpen, .requestQuickLook, .requestReveal, .requestCopy, .requestTrash,
             .requestEmptyWastebasket, .requestEject, .importDropped, .requestPrivacySettings, .requestChooseFolder:
            true
        default:
            false
        }
    }
}

/// Where scene motion left tokens and piles.
public struct SettleReport: Sendable, Equatable {
    public struct Move: Sendable, Equatable {
        public var key: TokenKey
        public var to: Location

        public init(key: TokenKey, to: Location) {
            self.key = key
            self.to = to
        }
    }

    public var moves: [Move]
    public var piles: [PileID: SIMD2<Float>]

    public init(moves: [Move] = [], piles: [PileID: SIMD2<Float>] = [:]) {
        self.moves = moves
        self.piles = piles
    }
}

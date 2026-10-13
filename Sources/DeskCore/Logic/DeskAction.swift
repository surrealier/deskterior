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
    case clearDesk
    case showOnDesk(TokenKey)
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

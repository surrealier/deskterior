import Foundation

/// What the reducer asks the outside world to do (DESIGN §4.2). Effects are data; `EffectRunner` (app) runs
/// them. File effects come only from request actions.
public enum Effect: Sendable, Equatable {
    case open([URL])
    case reveal([URL])
    case quickLook([URL])
    case copy([URL])
    /// Eject the volume mounted at this path (`VolumeEntry.path`).
    case eject(String)
    case trash([URL], expected: [TokenKey], confirm: ConfirmKind?)
    case importFiles([URL], op: ImportOp, hints: [String: Location])
    /// Start mirroring the folder (the first enumeration shows the TCC prompt).
    case connectDesktop
    case play(AnimationID, AnimTarget)
    case toast(ToastKey)
    /// Save the layout (debounced by the runner).
    case persist
    /// The scene must render (state changed).
    case wakeLoop
    case openPrivacySettings
    case chooseFolder
    // MARK: files
    /// Undo a file action: the app replays the `FileUndoRecord` this names, on the operator that issued it.
    case undoFiles(FileUndoRef)

    /// Effects that open, read, hand off or change user files.
    public var touchesFiles: Bool {
        switch self {
        case .open, .reveal, .quickLook, .copy, .eject, .trash, .importFiles, .connectDesktop: true
        case .undoFiles: true // MARK: files
        default: false
        }
    }

    /// Effects that change user files (or volumes). Run only through `FileOperator` with an `ExplicitIntent`.
    public var mutatesFiles: Bool {
        switch self {
        case .trash, .importFiles, .eject: true
        case .undoFiles: true // MARK: files
        default: false
        }
    }
}

/// Drop-in: move (same volume) or copy.
public enum ImportOp: String, Codable, Sendable {
    case move, copy
}

/// Confirmation sheets before a file effect.
public enum ConfirmKind: Sendable, Equatable {
    /// Empty Wastebasket…: up to 20 names, then "and N more".
    case emptyWastebasket(names: [String], more: Int)
}

/// One-shot scene animations requested by the model.
public enum AnimationID: String, Sendable {
    case printIn, poof, bonk, pulse, parade, crtOn, crtOff, ledAmber, staticNoise, osd, handleWiggle, peekMat
    // MARK: physics
    /// The pen cup or the wastebasket tips over / stands back up (`.container`).
    case tipOver, standUp
    // MARK: mat
    /// A mat command for the scene's cloth (`.mat`); Clear the Desk's brush pass and tucks (`.clearDesk`).
    case matCommand, clearDesk
}

public enum AnimTarget: Sendable, Equatable {
    case token(TokenKey)
    /// In order (bursts print in this order).
    case tokens([TokenKey])
    case location(Location)
    case container(ContainerID)
    case monitor
    // MARK: mat
    case mat(MatCommand)
    case clearDesk(ClearDeskPlan)
}

/// Pixel toasts. (English strings live in DeskScene's `Toast`; the L10n table takes over in M12.)
public enum ToastKey: String, Sendable, CaseIterable {
    case containerFull, accessDenied, notYetAvailable
    /// A token dropped on a drive bonks: copying to drives is Finder's job in v0.1 (E15).
    case drivesReadOnly
    // MARK: files
    /// A file action stopped for an item (`FileReport.toast`): it changed on disk, it is gone, macOS said no, undo
    /// needs Finder's Put Back, only some items went, it failed, a drop held the desk folder, an eject failed, every
    /// numbered name was taken.
    case fileChanged, fileGone, fileNotPermitted, usePutBack, someNotDone, fileFailed, dropHoldsDesk, ejectFailed
    case nameTaken
}

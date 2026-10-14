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
    /// ⌘Z on a drop-in still running: stop its copy (items not started stay where they are; what landed can be
    /// undone once its result is in). Changes no file itself.
    case cancelFiles(FileUndoRef)

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

/// Pixel toasts. (English strings live in DeskScene's `Toast`, translated through `L10n.tr`.)
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
    /// Only some items went, and why the others stayed: they changed on disk, they were gone, macOS said no.
    case someChanged, someGone, someNotPermitted
    /// A drop of a whole drive; the desk folder is not connected (Move to Trash, Empty Wastebasket, a drop).
    case dropWholeDrive, filesUnavailable
    /// ⌘Z: the step on top can no longer change anything (its items are gone), so the file action under it waits
    /// for the next ⌘Z; a file action is still running; a drop-in's copy is stopping.
    case nothingToUndo, fileBusy, stoppingCopy
    /// A file undo went through: back from the Trash; dropped items moved back out; dropped copies trashed; both.
    case undidTrash, undidMoveIn, undidCopyIn, undidDropIn
    /// An undo of a drop-in that macOS refused (the source folder is protected: SPIKES S12).
    case cantMoveBack
    // MARK: system (M12)
    /// Desktop widgets cover a critical part of the desk and no nudge clears them (one-time tip, DESIGN §1.2).
    case widgetsOverlap
    // MARK: harden
    /// A locked item dropped to move stayed where it was; a move macOS refused came in as a copy; leftovers of an
    /// interrupted copy are in the desk folder (Settings shows them) (Errata 25).
    case fileLocked, copiedInstead, leftoverCopies
    /// Only some items went: the rest were locked; some came in as copies (a move macOS refused) and the rest stayed;
    /// a copy landed but the item at its name is not provably the one written, so it has no undo step.
    case someLocked, someCopiedInstead, copiedNoUndo
}

import Foundation

/// A handle on one undoable file action (DESIGN §3.5 Undo). The app keeps the `FileUndoRecord` it stands for (only
/// the operator that issued a record can replay it); the undo journal keeps this, so the model never holds anything
/// that could change a file by itself.
public struct FileUndoRef: Sendable, Hashable, CustomStringConvertible {
    public var id: Int

    public init(_ id: Int) { self.id = id }

    public var description: String { "file#\(id)" }
}

/// Why one item of a file action did not happen: the model's view of DeskFiles' `FileRefusal`. Nothing changed
/// for that item.
public enum FileProblem: String, Sendable, Equatable, CaseIterable {
    /// The item there is not the one the token stood for (or it was swapped while acting, and put back).
    case changed
    /// Nothing is there now.
    case gone
    /// The system said no (privacy protection: SPIKES S11, S12; a locked item).
    case notPermitted
    /// Undo: the item is not in our trash, or the trash never said where it went (Finder's Put Back still can).
    case notInTrash
    /// "name", "name 2" … "name 100" are all taken.
    case noFreeName
    /// A drop of the desk folder itself, a folder holding it, or a whole volume.
    case holdsDesk
    /// Outside the desk folder or (demo and test modes) the sandbox, or not an ejectable volume.
    case outside
    /// The request came too late, twice, or was cancelled (a stale or spent intent, a cancelled copy).
    case expired
    case failed
}

/// What one file effect did, item by item, in model terms (DESIGN §3.5–§3.6). The app's `FileActions` builds it
/// from `FileOperator`'s result and dispatches `.fileResult`: trashed tokens leave at once with a poof and a
/// tombstone (so undo brings them back to the same place), dropped files' placement hints follow the names they
/// landed under, refusals become one toast, and `undo` joins the journal.
public struct FileReport: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Move to Trash from a token menu, the Inventory, or the Dock Trash (drag-out `.delete`).
        case trash
        /// Empty Wastebasket… after its sheet.
        case emptyWastebasket
        /// A drop from outside: moved or copied in.
        case importItems
        /// Undo of one of the above.
        case undo
        case eject

        /// "Undo <label>" in the menus.
        public var undoLabel: String {
            switch self {
            case .trash: "Move to Trash"
            case .emptyWastebasket: "Empty Wastebasket"
            case .importItems: "Drop In"
            case .undo: "Undo"
            case .eject: "Eject"
            }
        }
    }

    /// One dropped item now on the desk: its name where it came from, its name on the desk (" 2" after a clash),
    /// and its identity there when known.
    public struct Placed: Sendable, Equatable {
        public var source: String
        public var name: String
        public var key: TokenKey?

        public init(source: String, name: String, key: TokenKey? = nil) {
            self.source = source
            self.name = name
            self.key = key
        }
    }

    public var kind: Kind
    /// Items the request named.
    public var count: Int
    /// Trash: the tokens whose files went to the trash.
    public var trashed: [TokenKey]
    /// Import: the items that came in.
    public var placed: [Placed]
    /// Import: names (where they came from) of the items that did not.
    public var refusedNames: [String]
    /// One per item that did not happen, in request order.
    public var problems: [FileProblem]
    /// Set when something changed that undo can take back.
    public var undo: FileUndoRef?

    public init(
        kind: Kind, count: Int, trashed: [TokenKey] = [], placed: [Placed] = [], refusedNames: [String] = [],
        problems: [FileProblem] = [], undo: FileUndoRef? = nil
    ) {
        self.kind = kind
        self.count = count
        self.trashed = trashed
        self.placed = placed
        self.refusedNames = refusedNames
        self.problems = problems
        self.undo = undo
    }

    /// The toast for what did not happen, if anything did not: the first problem's, or "some items stayed" when
    /// others went through. A refused undo of a trash points at Finder's Put Back (SPIKES S11).
    public var toast: ToastKey? {
        guard let first = problems.first else { return nil }
        switch kind {
        case .eject:
            return first == .notPermitted ? .fileNotPermitted : .ejectFailed
        case .undo where first == .notPermitted || first == .notInTrash:
            return .usePutBack
        default:
            break
        }
        if problems.count < count { return .someNotDone }
        switch first {
        case .changed: return .fileChanged
        case .gone: return .fileGone
        case .notPermitted: return .fileNotPermitted
        case .notInTrash: return .usePutBack
        case .noFreeName: return .nameTaken
        case .holdsDesk: return .dropHoldsDesk
        case .outside, .expired, .failed: return .fileFailed
        }
    }
}

/// A drop of files onto the desk (DESIGN §3.6 Drop-in): what was dropped, where it should land and how. Items
/// already in the desk folder only move on the desk; the others come in through `FileOperator.importItems`.
public struct DropIn: Sendable, Equatable {
    public var urls: [URL]
    public var location: Location
    /// The desk-plane spot of a new pile the drop starts (`location` is then `.desk` with a pile id not in use).
    public var pilePos: SIMD2<Float>?
    public var op: ImportOp

    public init(urls: [URL], location: Location, pilePos: SIMD2<Float>? = nil, op: ImportOp) {
        self.urls = urls
        self.location = location
        self.pilePos = pilePos
        self.op = op
    }
}

/// What the desk does after a token's drag left the window and another app took it (DESIGN §3.6 Drag-out, SPIKES
/// S4). The receiving app does the work; we never change the file ourselves, except after the Dock Trash's
/// `.delete`, where the drag itself was the explicit gesture: if the file is still there once the wait is over, it
/// goes to the trash (undoably, `dragToTrash`). Either Dock behaviour is covered.
public enum DragOutRule {
    /// How the drag ended (`NSDragOperation`).
    public enum Outcome: String, Sendable, CaseIterable {
        case none, copy, link, move, generic, delete
    }

    public enum Plan: Sendable, Equatable {
        /// Nothing left: the tokens are back where they were.
        case returnHome
        /// The files should leave: the tokens hide for up to `seconds` while the mirror reports it; those still
        /// there afterwards come back, or with `thenTrash` go to the trash.
        case waitForRemoval(seconds: Double, thenTrash: Bool)
    }

    /// How long a `.move` waits for the mirror to see the file leave.
    public static let moveWait = 5.0
    /// How long a `.delete` waits before trashing the file itself.
    public static let deleteWait = 1.5

    public static func plan(_ outcome: Outcome) -> Plan {
        switch outcome {
        case .none, .copy, .link: .returnHome
        case .move, .generic: .waitForRemoval(seconds: moveWait, thenTrash: false)
        case .delete: .waitForRemoval(seconds: deleteWait, thenTrash: true)
        }
    }

    /// The operations a drag out of the desk offers: Finder-like (copy, move, link, generic, delete), or only copy
    /// with the "Drag-out: Always copy" setting.
    public static func offered(alwaysCopy: Bool) -> [Outcome] {
        alwaysCopy ? [.copy] : [.copy, .move, .link, .generic, .delete]
    }

    /// After the wait: the tokens to trash (with `thenTrash`, those still on the desk).
    public static func toTrash(_ plan: Plan, stillThere: [TokenKey]) -> [TokenKey] {
        if case .waitForRemoval(_, true) = plan { return stillThere }
        return []
    }
}

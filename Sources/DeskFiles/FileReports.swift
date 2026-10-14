import DeskCore
import Foundation

// The app side of `FileOperator` (M11; DESIGN §3.5–§3.7), kept here so it is testable: which intent origin each
// file effect is minted with, and what a `FileResult` means for the model (`FileReport`). Read-only.

/// Where file actions may act in a run mode (DESIGN §3.7 item 7): desk mode trashes into the real Trash, unconfined;
/// every other mode (windowed, headless, demo, test, tool) trashes into `<state dir>/FakeTrash` and is confined to the
/// mirrored folder, the state folder and any extra scratch folders (a demo's drop source), so nothing else can change
/// and nothing is ejected. Never the real Trash outside desk mode.
public struct FileActionScope: Sendable, Equatable {
    /// Our own trash folder; nil for the system Trash.
    public var trashFolder: URL?
    /// Non-nil outside desk mode: every path an operator touches must lie inside one of these.
    public var sandboxRoots: [URL]?

    public init(mode: SafetyGuard.Mode, folder: URL, stateDirectory: URL, extraRoots: [URL] = []) {
        if mode == .desk {
            trashFolder = nil
            sandboxRoots = nil
        } else {
            trashFolder = stateDirectory.appendingPathComponent("FakeTrash", isDirectory: true)
            sandboxRoots = [folder, stateDirectory] + extraRoots
        }
    }

    /// The operator's trash.
    public var trash: FileOperator.Trash { trashFolder.map { .folder($0) } ?? .system }
}

extension ExplicitIntent.Origin {
    /// The origin `EffectRunner` mints for `effect` (Errata 14), or nil when it must not mint one: a trash takes the
    /// origin it was requested from (a token menu, the Inventory, the Dock Trash), or `sheetConfirm` once its sheet
    /// was confirmed (never before); a drop-in is a `drop`, an undo an `undo`, an eject comes from a menu or the
    /// Inventory. Effects that change no file get none.
    public static func minted(for effect: Effect, requestedVia requested: Self, confirmed: Bool = false) -> Self? {
        switch effect {
        case let .trash(_, _, confirm):
            if confirm != nil { return confirmed ? .sheetConfirm : nil }
            return [.menuItem, .inventory, .dragToTrash].contains(requested) ? requested : nil
        case .importFiles:
            return .drop
        case .undoFiles:
            return .undo
        case .eject:
            return [.menuItem, .inventory].contains(requested) ? requested : nil
        default:
            return nil
        }
    }
}

extension FileProblem {
    /// The model's name for why `FileOperator` refused an item.
    public init(_ refusal: FileRefusal) {
        switch refusal {
        case .identityChanged: self = .changed
        case .missing: self = .gone
        case .notPermitted: self = .notPermitted
        case .notInTrash: self = .notInTrash
        case .noFreeName: self = .noFreeName
        case .containsDesktop, .volumeRoot: self = .holdsDesk
        case .outsideRoot, .outsideSandbox, .notEjectable: self = .outside
        case .staleIntent, .spentIntent, .cancelled, .unknownRecord: self = .expired
        case .wrongOrigin, .mismatchedRequest, .failed: self = .failed
        }
    }
}

extension FileReport {
    /// A trash (or Empty Wastebasket) result: `keys[i]` is the token the request's `i`th URL stood for.
    public init(trash result: FileResult, keys: [TokenKey], kind: Kind = .trash, undo: FileUndoRef?) {
        var trashed: [TokenKey] = []
        for (i, outcome) in result.outcomes.enumerated() {
            if case .trashed = outcome, i < keys.count { trashed.append(keys[i]) }
        }
        self.init(
            kind: kind, count: result.outcomes.count, trashed: trashed,
            problems: result.refusals.map(FileProblem.init), undo: undo
        )
    }

    /// A drop-in result. `identity` reads what each landed item is now (volume and inode), so the placement hint
    /// that follows it fits that item only; an item already on the desk (placement only) is not a file change.
    public init(
        import result: FileResult, undo: FileUndoRef?, identity: (URL) -> TokenKey? = FileReport.identity(of:)
    ) {
        var placed: [Placed] = []
        var refused: [String] = []
        for outcome in result.outcomes {
            switch outcome {
            case let .moved(source, to), let .copied(source, to), let .renamed(source, to, _):
                placed.append(Placed(source: source.lastPathComponent, name: to.lastPathComponent, key: identity(to)))
            case let .refused(source, _):
                refused.append(source.lastPathComponent)
            case .trashed, .unchanged, .ejected:
                break
            }
        }
        self.init(
            kind: .importItems, count: result.outcomes.count, placed: placed, refusedNames: refused,
            problems: result.refusals.map(FileProblem.init), undo: undo
        )
    }

    /// An undo result (whatever it renamed or trashed, the mirror brings the layout along).
    public init(undo result: FileResult) {
        self.init(kind: .undo, count: result.outcomes.count, problems: result.refusals.map(FileProblem.init))
    }

    public init(eject outcome: FileOutcome) {
        self.init(kind: .eject, count: 1, problems: outcome.refusal.map { [FileProblem($0)] } ?? [])
    }

    /// The volume and inode of the item at `url` itself (`lstat`: a symlink is not followed), as the scanner keys
    /// it; nil when it cannot be read.
    public static func identity(of url: URL) -> TokenKey? {
        var st = stat()
        let ok: Bool = url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return false }
            return lstat(p, &st) == 0
        }
        guard ok, let volume = FileOperator.volumeUUID(url) else { return nil }
        return TokenKey(volume: volume, inode: UInt64(st.st_ino))
    }
}

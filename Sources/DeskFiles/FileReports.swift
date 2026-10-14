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
    /// The origin `EffectRunner` mints for `effect` (Errata 14), or nil when it must not mint one. `requested` is the
    /// gesture the request came from (`EffectRunner.withOrigin`), nil when none was named: then nothing is minted.
    /// A trash takes the origin it was requested from (a menu, the Inventory, the Dock Trash), or `sheetConfirm` once
    /// its sheet (asked for from a menu) was confirmed, never before; a drop-in needs a `drop`; an undo comes from ⌘Z
    /// (`undo`) or a menu's Undo item; an eject from a menu or the Inventory. Effects that change no file get none.
    public static func minted(for effect: Effect, requestedVia requested: Self?, confirmed: Bool = false) -> Self? {
        guard let requested else { return nil }
        switch effect {
        case let .trash(_, _, confirm):
            if confirm != nil { return confirmed && requested == .menuItem ? .sheetConfirm : nil }
            return [.menuItem, .inventory, .dragToTrash].contains(requested) ? requested : nil
        case .importFiles:
            return requested == .drop ? .drop : nil
        case .undoFiles:
            return [.undo, .menuItem].contains(requested) ? .undo : nil
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
        case .containsDesktop: self = .holdsDesk
        case .volumeRoot: self = .wholeVolume
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

    /// A drop-in result. Each item is named by its path as the request named it (`DropIn.urls`, which the model's
    /// hints keep). `identity` reads what each landed item is now (volume and inode), so the placement hint that
    /// follows it fits that item only; an item already on the desk (placement only) is not a file change.
    public init(
        import result: FileResult, undo: FileUndoRef?, identity: (URL) -> TokenKey? = FileReport.identity(of:)
    ) {
        var placed: [Placed] = []
        var refused: [String] = []
        for outcome in result.outcomes {
            switch outcome {
            case let .moved(source, to), let .renamed(source, to, .move):
                placed.append(Placed(source: source.standardizedFileURL.path, name: to.lastPathComponent, key: identity(to)))
            case let .copied(source, to), let .renamed(source, to, .copy):
                placed.append(Placed(
                    source: source.standardizedFileURL.path, name: to.lastPathComponent, key: identity(to), copied: true
                ))
            case let .refused(source, _):
                refused.append(source.standardizedFileURL.path)
            case .trashed, .unchanged, .ejected:
                break
            }
        }
        self.init(
            kind: .importItems, count: result.outcomes.count, placed: placed, refused: refused,
            problems: result.refusals.map(FileProblem.init), undo: undo
        )
    }

    /// An undo result of an action of `kind` (whatever it renamed or trashed, the mirror brings the layout along).
    /// When everything went, its toast says what happened: back from the Trash; dropped items moved back out;
    /// dropped copies trashed. `kept`: refused before anything ran, so the app kept the record (`recordKept`).
    public init(undo result: FileResult, of kind: Kind, ticket: FileUndoRef? = nil, kept: Bool = false) {
        var done: ToastKey?
        switch kind {
        case .importItems:
            var trashed = false, moved = false
            for outcome in result.outcomes {
                switch outcome {
                case .trashed: trashed = true
                case .moved, .renamed: moved = true
                default: break
                }
            }
            done = trashed && moved ? .undidDropIn : trashed ? .undidCopyIn : .undidMoveIn
        default:
            done = .undidTrash
        }
        self.init(
            kind: .undo, count: result.outcomes.count, problems: result.refusals.map(FileProblem.init), ticket: ticket,
            undoOf: kind, kept: kept, done: done
        )
    }

    /// Whether `FileOperator.undo` refused before anything ran (its intent was stale, spent or of the wrong origin,
    /// or the folder is outside the sandbox): the operator still holds the record open, so it can be tried again.
    public static func recordKept(_ result: FileResult) -> Bool {
        !result.outcomes.isEmpty && result.outcomes.allSatisfy {
            guard case let .refused(_, r) = $0 else { return false }
            return [.staleIntent, .spentIntent, .wrongOrigin, .outsideSandbox].contains(r)
        }
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

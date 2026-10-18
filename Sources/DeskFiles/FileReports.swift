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
    /// (`undo`) or a menu's Undo item; an eject from a menu or the Inventory; Save as Text File from a menu item only
    /// (the Memos window's button goes through `AppDelegate.perform`, whose origin is a menu item; Erratum 31).
    /// Effects that change no file get none.
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
        case .createTextFile:
            return requested == .menuItem ? .menuItem : nil
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
        case .locked: self = .locked
        case .landedUnverified: self = .landedUnverified
        case .notInTrash: self = .notInTrash
        case .noFreeName: self = .noFreeName
        case .containsDesktop: self = .holdsDesk
        case .volumeRoot: self = .wholeVolume
        case .outsideRoot, .outsideSandbox, .notEjectable: self = .outside
        case .staleIntent, .spentIntent, .cancelled, .unknownRecord: self = .expired
        case .wrongOrigin, .mismatchedRequest, .failed: self = .failed
        case .invalidName, .invalidContents: self = .failed
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
    /// follows it fits that item only; an item already on the desk (placement only) is not a file change. A move
    /// (`requested`) that macOS refused and that came in as a copy says so (`copiedInstead`), so a duplicate is never
    /// silent (Errata 25).
    public init(
        import result: FileResult, undo: FileUndoRef?, requested: ImportOp? = nil,
        identity: (URL) -> TokenKey? = FileReport.identity(of:)
    ) {
        let ops = requested.map { Array(repeating: $0, count: result.outcomes.count) } ?? []
        self.init(import: result, undo: undo, ops: ops, identity: identity)
    }

    /// A drop-in result whose items asked for `ops` (one per item, in request order; Erratum 29). Aliases are placed
    /// like any item (under their own names: an app's without ".app"); when the drop made aliases, its toast says the
    /// originals stayed put, or which items became aliases beside those that came in. A move that came in as a copy
    /// still says so first; an alias that landed unverified has no undo step and says so (`aliasUnverified`).
    public init(
        import result: FileResult, undo: FileUndoRef?, ops: [ImportOp],
        identity: (URL) -> TokenKey? = FileReport.identity(of:)
    ) {
        var placed: [Placed] = []
        var refused: [String] = []
        var problems: [FileProblem] = []
        var copiedInstead = false
        var aliasedApps = 0
        for (i, outcome) in result.outcomes.enumerated() {
            let asked = ops.indices.contains(i) ? ops[i] : nil
            switch outcome {
            case let .moved(source, to), let .renamed(source, to, .move):
                placed.append(Placed(source: source.standardizedFileURL.path, name: to.lastPathComponent, key: identity(to)))
            case let .copied(source, to), let .renamed(source, to, .copy):
                placed.append(Placed(
                    source: source.standardizedFileURL.path, name: to.lastPathComponent, key: identity(to), copied: true
                ))
                if asked == .move { copiedInstead = true }
            case let .aliased(source, to), let .renamed(source, to, .alias):
                placed.append(Placed(
                    source: source.standardizedFileURL.path, name: to.lastPathComponent, key: identity(to), aliased: true
                ))
                if DropIn.isAppAlias(source: source.lastPathComponent, alias: to.lastPathComponent) { aliasedApps += 1 }
            case let .refused(source, r):
                refused.append(source.standardizedFileURL.path)
                problems.append(r == .landedUnverified && asked == .alias ? .aliasUnverified : FileProblem(r))
            case .trashed, .unchanged, .ejected, .created:
                break
            }
        }
        let aliases = placed.filter(\.aliased).count
        var done: ToastKey?
        if copiedInstead {
            done = .copiedInstead
        } else if aliases > 0 {
            if aliases < placed.count {
                done = aliases == 1 ? .appAliasedRestIn : .appsAliasedRestIn
            } else if aliasedApps == aliases {
                done = aliases == 1 ? .aliasMade : .aliasesMade
            } else {
                done = aliases == 1 ? .aliasMadeOriginal : .aliasesMadeOriginals
            }
        }
        self.init(
            kind: .importItems, count: result.outcomes.count, placed: placed, refused: refused, problems: problems,
            undo: undo, done: done
        )
    }

    /// An undo result of an action of `kind` (whatever it renamed or trashed, the mirror brings the layout along).
    /// When everything went, its toast says what happened: back from the Trash; dropped items moved back out;
    /// dropped copies trashed; dropped aliases trashed (`record`, the record undone, tells them from copies;
    /// Erratum 29). `kept`: refused before anything ran, so the app kept the record (`recordKept`).
    public init(
        undo result: FileResult, of kind: Kind, record: FileUndoRecord? = nil, ticket: FileUndoRef? = nil,
        kept: Bool = false
    ) {
        var done: ToastKey?
        switch kind {
        case .importItems:
            let aliases = record?.aliases ?? []
            var trashed = false, moved = false, trashedAliases = 0
            for outcome in result.outcomes {
                switch outcome {
                case let .trashed(url, _): if aliases.contains(url) { trashedAliases += 1 } else { trashed = true }
                case .moved, .renamed: moved = true
                default: break
                }
            }
            if trashedAliases > 0 {
                let mixed = trashed || moved
                done = trashedAliases == 1 ? (mixed ? .undidAliasMix : .undidAlias) : (mixed ? .undidAliasesMix : .undidAliases)
            } else {
                done = trashed && moved ? .undidDropIn : trashed ? .undidCopyIn : .undidMoveIn
            }
        case .createTextFile:
            // MARK: files (0.3.0): the text file went to the Trash (a refusal says why it stayed instead).
            done = result.outcomes.contains { if case .trashed = $0 { true } else { false } } ? .undidSaveTextFile : nil
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

    /// A Save as Text File on Desktop result (Erratum 31): the new file, named by the memo it came from (`source`,
    /// "memo:note:N3", as its placement hint is), so the hint follows the name it landed under (" 2" after a clash),
    /// with the identity it was written with; refused, its hint goes. Saved, it toasts `savedTextFile`; a file that
    /// landed unverified stays where it is, with no undo step, and says so.
    public init(create result: FileResult, source: String, undo: FileUndoRef?) {
        var placed: [Placed] = []
        var refused: [String] = []
        for outcome in result.outcomes {
            switch outcome {
            case let .created(url, _):
                placed.append(Placed(source: source, name: TextLayout.nfc(url.lastPathComponent),
                                     key: result.undo?.createdKey(at: url) ?? FileReport.identity(of: url)))
            case .refused:
                refused.append(source)
            default:
                break
            }
        }
        self.init(
            kind: .createTextFile, count: result.outcomes.count, placed: placed, refused: refused,
            problems: result.refusals.map(FileProblem.init), undo: undo, done: placed.isEmpty ? nil : .savedTextFile
        )
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

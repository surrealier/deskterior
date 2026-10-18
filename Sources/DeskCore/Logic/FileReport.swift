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
    /// A drop of the desk folder itself or a folder holding it.
    case holdsDesk
    /// A drop of a whole drive (a volume's root).
    case wholeVolume
    /// Outside the desk folder or (demo and test modes) the sandbox, or not an ejectable volume.
    case outside
    /// The request came too late, twice, or was cancelled (a stale or spent intent, a cancelled copy).
    case expired
    case failed
    // MARK: harden
    /// A move of a Finder-locked item (or one in a locked folder): it stayed, and was not copied instead.
    case locked
    /// A copy landed, but the item now at its name is not provably the one written: it stays there, untouched,
    /// with no undo step.
    case landedUnverified
    // MARK: alias (Erratum 29)
    /// The same for an alias: it stays there, untouched, with no undo step.
    case aliasUnverified
}

/// What one file effect did, item by item, in model terms (DESIGN §3.5–§3.6). The app's `FileActions` builds it
/// from `FileOperator`'s result and dispatches `.fileResult`: trashed tokens leave at once with a poof and a
/// tombstone (so undo brings them back to the same place), dropped files' placement hints follow the names they
/// landed under, refusals become one toast, and `undo` fills the journal entry `ticket` names (the place the action
/// took in the journal when it was asked for, `.fileStarted`).
public struct FileReport: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Move to Trash from a token menu, the Inventory, or the Dock Trash (drag-out `.delete`).
        case trash
        /// Empty Wastebasket… after its sheet.
        case emptyWastebasket
        /// A drop from outside: moved or copied in, or aliased (Erratum 29).
        case importItems
        /// Undo of one of the above.
        case undo
        case eject
        // MARK: files (0.3.0)
        /// Save as Text File on Desktop: one new text file (Erratum 31). Not named `createFile`: the file-safety
        /// lint keeps that word to the writers.
        case createTextFile

        /// "Undo <label>" in the menus while the action runs: a drop-in by what it asks for ("Copy In" for a copy,
        /// "Make Alias" for aliases, else "Move In"; its result may say "Drop In" when it did several).
        public func undoLabel(op: ImportOp? = nil) -> String {
            switch self {
            case .trash: "Move to Trash"
            case .emptyWastebasket: "Empty Wastebasket"
            case .importItems: op == .copy ? "Copy In" : op == .alias ? "Make Alias" : "Move In"
            case .undo: "Undo"
            case .eject: "Eject"
            case .createTextFile: "Save as Text File"
            }
        }
    }

    /// One dropped item now on the desk: its path where it came from (as the request named it), its name on the
    /// desk (" 2" after a clash; an app's alias without ".app"), its identity there when known, and whether it came
    /// as a copy or as an alias.
    public struct Placed: Sendable, Equatable {
        public var source: String
        public var name: String
        public var key: TokenKey?
        /// Copied in (another volume, ⌥, or a move macOS refused); else moved, or aliased.
        public var copied: Bool
        /// An alias of the item came in; the item itself stayed where it was (Erratum 29).
        public var aliased: Bool

        public init(source: String, name: String, key: TokenKey? = nil, copied: Bool = false, aliased: Bool = false) {
            self.source = source
            self.name = name
            self.key = key
            self.copied = copied
            self.aliased = aliased
        }
    }

    public var kind: Kind
    /// Items the request named.
    public var count: Int
    /// Trash: the tokens whose files went to the trash.
    public var trashed: [TokenKey]
    /// Import: the items that came in.
    public var placed: [Placed]
    /// Import: paths (as the request named them) of the items that did not.
    public var refused: [String]
    /// One per item that did not happen, in request order.
    public var problems: [FileProblem]
    /// Set when something changed that undo can take back (the same ref as `ticket`).
    public var undo: FileUndoRef?
    /// The journal entry this result fills: the ref `.fileStarted` named for an action, or the entry being undone
    /// for an undo.
    public var ticket: FileUndoRef?
    /// Undo: the kind of action it took back (its toasts differ: a drop-in has no Put Back).
    public var undoOf: Kind?
    /// Undo: refused before anything ran (a stale or spent intent, no origin): the record is kept, the journal entry
    /// is ready again, and ⌘Z can try once more.
    public var kept: Bool
    /// The toast when everything went (an undo says what it did).
    public var done: ToastKey?

    public init(
        kind: Kind, count: Int, trashed: [TokenKey] = [], placed: [Placed] = [], refused: [String] = [],
        problems: [FileProblem] = [], undo: FileUndoRef? = nil, ticket: FileUndoRef? = nil, undoOf: Kind? = nil,
        kept: Bool = false, done: ToastKey? = nil
    ) {
        self.kind = kind
        self.count = count
        self.trashed = trashed
        self.placed = placed
        self.refused = refused
        self.problems = problems
        self.undo = undo
        self.ticket = ticket ?? undo
        self.undoOf = undoOf
        self.kept = kept
        self.done = done
    }

    /// "Undo <label>" once the result is in: a drop-in by how its items came ("Move In", "Copy In", "Make Alias", or
    /// "Drop In" when it did more than one of these).
    public var undoLabel: String {
        guard kind == .importItems, !placed.isEmpty else { return kind.undoLabel() }
        if placed.allSatisfy(\.aliased) { return "Make Alias" }
        if placed.allSatisfy({ $0.copied && !$0.aliased }) { return "Copy In" }
        return placed.contains(where: { $0.copied || $0.aliased }) ? "Drop In" : "Move In"
    }

    /// The toast: what did not happen, if anything did not (the first problem's; with others through, "some
    /// stayed" and why), else `done`. A refused undo of a trash points at Finder's Put Back (SPIKES S11); one of a
    /// drop-in says it could not go back; one of a saved text file says why the file stayed (it changed, it is gone,
    /// macOS said no). A move that came in as a copy is never left unsaid (Errata 25): with refusals beside it, the
    /// toast says both; a copy that landed without an undo step says so first.
    public var toast: ToastKey? {
        guard let first = problems.first else { return done }
        // MARK: harden
        if problems.contains(.landedUnverified) { return kind == .createTextFile ? .savedNoUndo : .copiedNoUndo }
        if problems.contains(.aliasUnverified) { return .aliasNoUndo }
        if done == .copiedInstead { return .someCopiedInstead }
        switch kind {
        case .eject:
            return first == .notPermitted ? .fileNotPermitted : .ejectFailed
        case .undo where undoOf == .importItems:
            if first == .notPermitted { return .cantMoveBack }
        // MARK: files (0.3.0): a text file that did not go to the Trash is still on the desk; Put Back is no help.
        case .undo where undoOf == .createTextFile:
            break
        case .undo:
            if first == .notPermitted || first == .notInTrash { return .usePutBack }
        default:
            break
        }
        if problems.count < count {
            switch first {
            case .changed: return .someChanged
            case .gone: return .someGone
            case .notPermitted: return .someNotPermitted
            case .locked: return .someLocked  // MARK: harden
            default: return .someNotDone
            }
        }
        switch first {
        case .changed: return .fileChanged
        case .gone: return .fileGone
        case .notPermitted: return .fileNotPermitted
        case .locked: return .fileLocked
        case .landedUnverified: return kind == .createTextFile ? .savedNoUndo : .copiedNoUndo
        case .aliasUnverified: return .aliasNoUndo
        case .notInTrash: return .usePutBack
        case .noFreeName: return .nameTaken
        case .holdsDesk: return .dropHoldsDesk
        case .wholeVolume: return .dropWholeDrive
        case .outside, .expired, .failed: return .fileFailed
        }
    }
}

/// A drop of files onto the desk (DESIGN §3.6 Drop-in): what was dropped, where it should land and how. Items
/// already in the desk folder only move on the desk; the others come in through `FileOperator.importItems`, each
/// with its own op (Erratum 29: `DropIn.ops`).
public struct DropIn: Sendable, Equatable {
    public var urls: [URL]
    public var location: Location
    /// The desk-plane spot of a new pile the drop starts (`location` is then `.desk` with a pile id not in use).
    public var pilePos: SIMD2<Float>?
    /// How each item comes in, one per URL (a missing one moves).
    public var ops: [ImportOp]
    /// Whether each item is an application bundle (its alias is named without ".app"), one per URL, as the app read
    /// them from the items; a missing one goes by the name.
    public var apps: [Bool]

    public init(urls: [URL], location: Location, pilePos: SIMD2<Float>? = nil, op: ImportOp, apps: [Bool]? = nil) {
        self.init(urls: urls, location: location, pilePos: pilePos, ops: Array(repeating: op, count: urls.count),
                  apps: apps)
    }

    /// `apps`: whether each item is an application bundle (nil: by its name, an ".app" one).
    public init(urls: [URL], location: Location, pilePos: SIMD2<Float>? = nil, ops: [ImportOp], apps: [Bool]? = nil) {
        self.urls = urls
        self.location = location
        self.pilePos = pilePos
        self.ops = ops
        self.apps = apps ?? urls.map { Self.hasAppExtension($0.lastPathComponent) }
    }

    /// The drop's op as one (`ImportOp.headline`).
    public var op: ImportOp { ImportOp.headline(ops) }

    /// The op of the item at `index` (a missing one moves).
    public func op(at index: Int) -> ImportOp { ops.indices.contains(index) ? ops[index] : .move }

    /// Whether the item at `index` is an application bundle (a missing entry goes by the name).
    public func isApp(at index: Int) -> Bool {
        if apps.indices.contains(index) { return apps[index] }
        return urls.indices.contains(index) && Self.hasAppExtension(urls[index].lastPathComponent)
    }

    /// What a drag of files over the desk is told (DESIGN §3.6): nothing where the drop would bonk (a full container,
    /// a drive, the monitor off); a copy when one is forced (⌥, or a source that offers no move) or when an item lies
    /// on another volume than the desk, since we copy it and the source must keep its original; else a move.
    public static func dragOperation(bonks: Bool, forcedCopy: Bool, crossesVolumes: Bool) -> ImportOp? {
        if bonks { return nil }
        return forcedCopy || crossesVolumes ? .copy : .move
    }

    // MARK: alias (Erratum 29)

    /// What a drag of items with `ops` (`DropIn.ops`) is told: nothing where the drop would bonk; a link when every
    /// item becomes an alias; else a copy when any item stays where it is (it is copied, aliased, or would move
    /// across volumes: `crosses[i]`, item `i` lies on another volume than the desk, or its volume cannot be read; a
    /// missing entry counts as crossing), so a source that removes its own item after a move never removes one we
    /// only copied or aliased; else (every item moves) a move.
    public static func dragOperation(bonks: Bool, ops: [ImportOp], crosses: [Bool]) -> ImportOp? {
        if bonks { return nil }
        if !ops.isEmpty, ops.allSatisfy({ $0 == .alias }) { return .alias }
        for (i, op) in ops.enumerated() where op != .move || (i < crosses.count ? crosses[i] : true) {
            return .copy
        }
        return .move
    }

    /// The op each dropped item asks for (Erratum 29), one per item: ⌥ copies every item; ⌘⌥ makes an alias of
    /// every item (Finder's convention); ⌘ alone moves every item, applications too (across volumes still a copy: a
    /// source is never deleted); with no key an application becomes an alias and every other item moves (or is copied
    /// across volumes), as before. `isApp[i]`: item `i` is an application a drop with no key aliases (not one in a
    /// Trash or on a disk image or another volume that comes and goes, which comes in as before; the app's drop-in
    /// controller tells).
    /// `canMove`: the drag's source lets the item be moved (else what would move is copied, as before); `canAlias`:
    /// it allows an answer that leaves its item where it is (a link, a copy or a generic drop), else an app with no
    /// key moves as before and ⌘⌥ copies; `linkOnly`: it allows nothing but a link (as AppKit narrows the mask while
    /// ⌃ is held), so every item becomes an alias, whatever the keys.
    public static func ops(
        _ mode: DropMode, isApp: [Bool], canMove: Bool = true, canAlias: Bool = true, linkOnly: Bool = false
    ) -> [ImportOp] {
        isApp.map { op(mode, isApp: $0, canMove: canMove, canAlias: canAlias, linkOnly: linkOnly) }
    }

    /// One item's op (`ops`).
    public static func op(
        _ mode: DropMode, isApp: Bool, canMove: Bool = true, canAlias: Bool = true, linkOnly: Bool = false
    ) -> ImportOp {
        if linkOnly { return .alias }
        let move: ImportOp = canMove ? .move : .copy
        switch mode {
        case .copy: return .copy
        case .alias: return canAlias ? .alias : .copy
        case .move: return move
        case .standard: return isApp && canAlias ? .alias : move
        }
    }

    /// The name an alias of an item named `name` takes on the desk: an application bundle's without its ".app"
    /// ("Safari"), any other item's as it is (a folder or a document keeps its full name, "notes.app" too). A taken
    /// name gets " 2", " 3"… as a copy's.
    public static func aliasName(_ name: String, isApp: Bool) -> String {
        guard isApp, hasAppExtension(name) else { return name }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// The name an item named `name` lands under with `op` (`aliasName` for an alias).
    public static func landingName(_ name: String, op: ImportOp, isApp: Bool) -> String {
        op == .alias ? aliasName(name, isApp: isApp) : name
    }

    /// Whether the alias named `alias` of an item named `source` is an application's: its ".app" was left off
    /// (`aliasName` leaves it off only for an application bundle; " 2" after a clash keeps that true). The toasts
    /// then say the app stayed put.
    public static func isAppAlias(source: String, alias: String) -> Bool {
        hasAppExtension(source) && !hasAppExtension(alias)
    }

    /// The name ends in ".app" (any case) after a stem.
    static func hasAppExtension(_ name: String) -> Bool {
        let ns = name as NSString
        return ns.pathExtension.lowercased() == "app" && !ns.deletingPathExtension.isEmpty
    }
}

/// The keys held over a drop (Erratum 29): none, ⌥ (copy), ⌘ (move) or ⌘⌥ (alias).
public enum DropMode: String, Sendable, CaseIterable {
    /// No key: an application becomes an alias; every other item moves (same volume) or is copied.
    case standard
    /// ⌥: every item is copied.
    case copy
    /// ⌘: every item moves (same volume) or is copied, applications too.
    case move
    /// ⌘⌥: every item becomes an alias.
    case alias

    public init(option: Bool, command: Bool) {
        switch (option, command) {
        case (true, true): self = .alias
        case (true, false): self = .copy
        case (false, true): self = .move
        case (false, false): self = .standard
        }
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

    /// The outcome of the operation a drag ended with, as its bits: exactly `delete` over the Dock is the Dock Trash;
    /// a `delete` from anything else only waits like a move (it asks us to delete the file, which we never do);
    /// several bits at once are read as the least consequential (copy, link, generic, then move), so the tokens go
    /// home.
    public static func outcome(_ bits: Set<Outcome>, overDock: Bool) -> Outcome {
        let ops = bits.subtracting([.none])
        if ops == [.delete] { return overDock ? .delete : .move }
        return [Outcome.copy, .link, .generic, .move].first(where: ops.contains) ?? .none
    }

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

    /// After the wait: the tokens to trash (with `thenTrash`, those still on the desk), none when Finder took over
    /// meanwhile (it came to the front: a dialog of its own about these files, which the user may cancel).
    public static func toTrash(_ plan: Plan, stillThere: [TokenKey], finderTookOver: Bool = false) -> [TokenKey] {
        if case .waitForRemoval(_, true) = plan, !finderTookOver { return stillThere }
        return []
    }
}

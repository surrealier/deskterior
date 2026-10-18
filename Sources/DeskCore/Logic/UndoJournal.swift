import Foundation

/// The layout an undoable action can change: where every token rests, pile positions, and the element states a
/// global action touches (monitor, phone, drawers).
public struct LayoutSnapshot: Sendable, Equatable {
    public var locations: [TokenKey: Location]
    public var piles: [PileID: SIMD2<Float>]
    public var monitor: MonitorState
    public var phone: PhoneState
    public var drawers: [ContainerID: DrawerState]

    public init(_ s: DeskState) {
        var locations: [TokenKey: Location] = [:]
        for key in s.tokens.records.keys {
            if let loc = s.tokens.restingLocation(of: key), loc != .carried { locations[key] = loc }
        }
        self.locations = locations
        piles = s.piles
        monitor = s.monitor
        phone = s.phone
        drawers = s.drawers
    }
}

/// Undo and redo for layout changes (DESIGN §4.2, §2.2 E16: Take Everything Out and Clear the Desk are one undo
/// each). Up to `capacity` entries, each the layout before and after one action.
///
/// Undo applies the inverse of what the action changed, not the whole old layout: tokens the action moved go
/// back (following re-keys; files removed since are skipped, and a cell taken since sends its token to the
/// nearest free cell), and only the monitor, phone and drawer fields the action changed are restored. So files
/// that arrived or left in between, and settings changed in between, survive an undo. Redo replays the forward
/// change the same way. File actions (M11) join as entries that name a `FileUndoRef`: undoing one asks the app to
/// replay the file record (`Effect.undoFiles`), and the mirror brings the layout along (a trashed file returns to
/// its tombstone's place). They are not redone.
///
/// A file entry takes its place when the action is asked for (`.fileStarted`), not when it finishes, so a long copy
/// never jumps over moves made meanwhile, and its result clears no redo. ⌘Z replays a file entry only while it is
/// the entry on top, the one the menus name: it never steps past a stale layout step into one (that ⌘Z only drops
/// the stale steps and says so).
public struct UndoJournal: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// "Move", "Take Everything Out"… (menus show "Undo <label>").
        public var label: String
        public var before: LayoutSnapshot
        public var after: LayoutSnapshot
        // MARK: files
        /// A file action's entry (the snapshots are then unused).
        public var file: FileEntry? = nil
    }

    // MARK: files

    /// A file action in the journal: its ref (the app keeps the record), its kind, and how far it is.
    public struct FileEntry: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            /// Asked for and still running (a long copy): ⌘Z stops a drop-in's copy.
            case running
            /// Done, with something ⌘Z can take back.
            case ready
            /// ⌘Z asked for its undo, which is running.
            case undoing
        }

        public var ref: FileUndoRef
        public var kind: FileReport.Kind
        public var phase: Phase
    }

    public static let capacity = 20

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []

    public init() {}

    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    /// The label of an action that is journaled, or nil.
    public static func label(for action: DeskAction) -> String? {
        switch action {
        case let .move(keys, _), let .dropOnDesk(keys, _, _), let .dropOnFloor(keys, _), let .tuckUnderMat(keys, _, _):
            keys.count > 1 ? "Move \(keys.count) Items" : "Move"
        case .takeAllOut: "Take All Out"
        case .takeEverythingOut: "Take Everything Out"
        case .cleanUp: "Clean Up"
        case .clearDesk: "Clear the Desk"
        // MARK: files
        case .requestDropIn, .importDropped: "Move" // desk items dropped back move; files from outside are a file entry
        default: nil
        }
    }

    /// Records one change (clearing redo); a no-op change is not recorded.
    public mutating func record(_ label: String, before: LayoutSnapshot, after: LayoutSnapshot) {
        guard before != after else { return }
        undoStack.append(Entry(label: label, before: before, after: after))
        if undoStack.count > Self.capacity { undoStack.removeFirst(undoStack.count - Self.capacity) }
        redoStack.removeAll()
    }

    // MARK: files

    /// A file action was asked for: it takes its place on top now (a new action: redo clears), running.
    public mutating func startFile(_ ref: FileUndoRef, _ kind: FileReport.Kind, op: ImportOp?, state s: DeskState) {
        let snapshot = LayoutSnapshot(s)
        let file = FileEntry(ref: ref, kind: kind, phase: .running)
        undoStack.append(Entry(label: kind.undoLabel(op: op), before: snapshot, after: snapshot, file: file))
        if undoStack.count > Self.capacity { undoStack.removeFirst(undoStack.count - Self.capacity) }
        redoStack.removeAll()
    }

    /// A file result fills the entry its `ticket` names, where it stands: an action that changed something becomes
    /// ready (its label now says what it did), one that changed nothing goes; an undo that went (or was refused for
    /// good) spends its entry, one refused before it ran (`kept`) leaves it ready for another ⌘Z. Redo is untouched.
    public mutating func finishFile(_ report: FileReport) {
        guard let ticket = report.ticket, let i = undoStack.lastIndex(where: { $0.file?.ref == ticket }),
              let file = undoStack[i].file else { return }
        switch (report.kind, file.phase) {
        case (.undo, .undoing):
            if report.kept { undoStack[i].file?.phase = .ready } else { undoStack.remove(at: i) }
        case (.trash, .running), (.emptyWastebasket, .running), (.importItems, .running), (.createTextFile, .running):
            if report.undo != nil {
                undoStack[i].file?.phase = .ready
                undoStack[i].label = report.undoLabel
            } else {
                undoStack.remove(at: i)
            }
        default:
            break
        }
    }

    /// Undoes the latest entry that still changes something; layout entries whose tokens are all gone are dropped
    /// on the way, so one ⌘Z always does something visible or nothing at all. A file entry acts only when it is the
    /// top entry (the one the menus name): a ⌘Z that had to drop stale steps to reach it stops there and says so.
    /// A ready one asks the app to replay its record (and is not redone); a running drop-in stops its copy.
    public mutating func undo(_ s: inout DeskState, grid: ScreenGrid = .standard) -> [Effect] {
        var skipped = false
        while let entry = undoStack.last {
            // MARK: files
            if let file = entry.file {
                if skipped { return [.toast(.nothingToUndo)] }
                switch file.phase {
                case .ready:
                    undoStack[undoStack.count - 1].file?.phase = .undoing
                    return [.undoFiles(file.ref)]
                case .running where file.kind == .importItems:
                    return [.cancelFiles(file.ref), .toast(.stoppingCopy)]
                case .running, .undoing:
                    return [.toast(.fileBusy)]
                }
            }
            undoStack.removeLast()
            let before = s
            Self.apply(from: entry.after, to: entry.before, onto: &s, grid: grid)
            guard s != before else {
                skipped = true
                continue
            }
            redoStack.append(entry)
            return [.persist, .wakeLoop]
        }
        return []
    }

    /// Redoes the latest undone entry that still changes something (stale ones are dropped).
    public mutating func redo(_ s: inout DeskState, grid: ScreenGrid = .standard) -> [Effect] {
        while let entry = redoStack.popLast() {
            let before = s
            Self.apply(from: entry.before, to: entry.after, onto: &s, grid: grid)
            guard s != before else { continue }
            undoStack.append(entry)
            return [.persist, .wakeLoop]
        }
        return []
    }

    /// Re-applies the difference `from → to` onto `s`.
    static func apply(from: LayoutSnapshot, to: LayoutSnapshot, onto s: inout DeskState, grid: ScreenGrid) {
        // Tokens the change moved (present on both sides), now under their current keys.
        var targets: [(key: TokenKey, to: Location)] = []
        var seen = Set<TokenKey>()
        for (key, a) in from.locations {
            guard let b = to.locations[key], a != b else { continue }
            let live = s.currentKey(for: key)
            guard s.tokens.contains(live), seen.insert(live).inserted else { continue }
            targets.append((live, b))
        }
        targets.sort { Self.placementOrder($0.to, $1.to) ?? ($0.key < $1.key) }

        for t in targets { s.tokens.move(t.key, to: .carried) }
        var allocator = ScreenGrid.Allocator(grid: grid, occupied: s.tokens.occupiedCells)
        for t in targets {
            let pilePos = t.to.pile.map { to.piles[$0] ?? s.piles[$0] ?? Placement.defaultPilePos }
            let loc = Placement.resolve(t.to, pilePos: pilePos, in: &s, allocator: &allocator)
            if !s.tokens.move(t.key, to: loc, grid: grid) { s.tokens.move(t.key, to: allocator.next().location, grid: grid) }
        }

        for (pile, pos) in to.piles where from.piles[pile] != pos && !s.tokens.members(of: pile).isEmpty {
            s.piles[pile] = pos
        }
        if from.monitor.power != to.monitor.power { s.monitor.power = to.monitor.power }
        if from.monitor.av != to.monitor.av { s.monitor.av = to.monitor.av }
        if from.monitor.page != to.monitor.page { s.monitor.page = to.monitor.page }
        if s.monitor.power == .on { s.monitor.pendingNew = 0 }
        if from.phone != to.phone { s.phone = to.phone }
        for (id, d) in to.drawers where from.drawers[id] != d { s.drawers[id] = d }
        Placement.pruneEmptyPiles(&s)
        s.monitor.page = min(max(0, s.monitor.page), s.pageCount(grid: grid) - 1)
    }

    /// Screen cells in reading order, then containers and piles by order, so restored orders come out dense and
    /// as they were. Nil when the two locations are unrelated (ties broken by key).
    private static func placementOrder(_ a: Location, _ b: Location) -> Bool? {
        switch (a, b) {
        case (.screen, .screen): return a.cell! < b.cell!
        case let (.container(i, x), .container(j, y)): return i != j ? i < j : x < y
        case let (.desk(p, x), .desk(q, y)): return p != q ? p < q : x < y
        default:
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : nil
        }
    }

    private static func rank(_ l: Location) -> Int {
        switch l {
        case .screen: 0
        case .container: 1
        case .desk: 2
        case .floor: 3
        case .carried: 4
        }
    }
}

extension Reducer {
    /// `reduce` with an undo journal: journaled actions record the layout before and after, and `.undo` / `.redo`
    /// step through the journal. The `Store` uses this entry point; plain `reduce` ignores undo and redo.
    public static func reduce(
        _ s: inout DeskState, journal: inout UndoJournal, _ a: DeskAction, _ env: ReduceEnv
    ) -> [Effect] {
        switch a {
        case .undo:
            return journal.undo(&s, grid: env.grid)
        case .redo:
            return journal.redo(&s, grid: env.grid)
        // MARK: files
        case let .fileStarted(ref, kind, op):
            journal.startFile(ref, kind, op: op, state: s)
            return reduce(&s, a, env)
        case let .fileResult(report):
            let effects = reduce(&s, a, env)
            journal.finishFile(report)
            return effects
        default:
            guard let label = UndoJournal.label(for: a) else { return reduce(&s, a, env) }
            let before = LayoutSnapshot(s)
            let effects = reduce(&s, a, env)
            journal.record(label, before: before, after: LayoutSnapshot(s))
            return effects
        }
    }
}

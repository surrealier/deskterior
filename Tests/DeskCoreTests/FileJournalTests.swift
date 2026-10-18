import Foundation
import Testing
@testable import DeskCore

/// File actions in the undo journal and the drop hints (M11 review): a file entry takes its place when it is asked
/// for, ⌘Z replays one only while it is the entry the menus name, and a drop's hints never take someone else's file.
@Suite("File actions: journal and drop hints")
struct FileJournalTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    func cell(_ col: Int, _ row: Int) -> Location { .screen(page: 0, col: col, row: row) }

    @discardableResult
    func run(_ s: inout DeskState, _ j: inout UndoJournal, _ a: DeskAction) -> [Effect] {
        Reducer.reduce(&s, journal: &j, a, env)
    }

    func start(_ s: inout DeskState, _ j: inout UndoJournal, _ ref: Int, _ kind: FileReport.Kind, op: ImportOp? = nil) {
        run(&s, &j, .fileStarted(FileUndoRef(ref), kind, op: op))
    }

    /// A finished action `ref` that changed something (`undoable`) or nothing.
    func finish(_ s: inout DeskState, _ j: inout UndoJournal, _ ref: Int, _ kind: FileReport.Kind,
                trashed: [TokenKey] = [], placed: [FileReport.Placed] = [], undoable: Bool = true) {
        let r = FileReport(kind: kind, count: max(1, trashed.count + placed.count), trashed: trashed, placed: placed,
                           undo: undoable ? FileUndoRef(ref) : nil, ticket: FileUndoRef(ref))
        run(&s, &j, .fileResult(r))
    }

    // MARK: ⌘Z and the label

    @Test("A stale move on top spends ⌘Z on itself: the Drop In under it waits for the next ⌘Z, under its own label")
    func staleStepIsABarrier() {
        var s = F.mirrored(["a.txt", "b.txt"])
        var j = UndoJournal()
        start(&s, &j, 5, .importItems, op: .move)
        finish(&s, &j, 5, .importItems, placed: [.init(source: "/x/new.txt", name: "new.txt", key: F.key(60))])
        run(&s, &j, .move([F.key(2)], to: .container(.riserLeft, order: 0)))
        // b.txt leaves outside the journal (dragged out to Finder, which moved it).
        run(&s, &j, .snapshot(F.snapshot([F.entry("a.txt", 1), F.entry("new.txt", 60)], at: F.t0 + 1), now: F.t0 + 1))
        #expect(j.undoLabel == "Move")
        #expect(run(&s, &j, .undo) == [.toast(.nothingToUndo)], "no file changes under a label that said Move")
        #expect(j.undoLabel == "Move In")
        #expect(run(&s, &j, .undo) == [.undoFiles(FileUndoRef(5))])
    }

    @Test("The same barrier guards a Move to Trash: ⌘Z never puts files back under 'Undo Move'")
    func staleStepGuardsTrash() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt"])
        var j = UndoJournal()
        start(&s, &j, 9, .trash)
        finish(&s, &j, 9, .trash, trashed: [F.key(3)])
        run(&s, &j, .move([F.key(2)], to: .container(.phone, order: 0)))
        run(&s, &j, .snapshot(F.snapshot([F.entry("a.txt", 1)], at: F.t0 + 1), now: F.t0 + 1))
        #expect(j.undoLabel == "Move")
        #expect(!run(&s, &j, .undo).contains(.undoFiles(FileUndoRef(9))))
        #expect(j.undoLabel == "Move to Trash")
    }

    @Test("Random sessions: ⌘Z replays a file record only when the label shown before it was that entry's")
    func fileUndoOnlyUnderItsLabel() {
        var rng = SplitMix64(seed: 2024)
        var replays = 0
        for _ in 0..<80 {
            var s = F.mirrored((1...8).map { "f\($0).txt" })
            var j = UndoJournal()
            var running: [(ref: Int, kind: FileReport.Kind)] = []
            var nextRef = 1
            var present = Set((1...8).map { UInt64($0) })
            for _ in 0..<60 {
                let live = present.sorted()
                switch Int.random(in: 0..<7, using: &rng) {
                case 0, 1:
                    guard let i = live.randomElement(using: &rng) else { continue }
                    let to: Location = Bool.random(using: &rng)
                        ? .container(ContainerID.allCases.randomElement(using: &rng)!, order: 0)
                        : cell(Int.random(in: 0..<8, using: &rng), Int.random(in: 0..<4, using: &rng))
                    run(&s, &j, .move([F.key(i)], to: to))
                case 2:
                    let kind: FileReport.Kind = Bool.random(using: &rng) ? .trash : .importItems
                    start(&s, &j, nextRef, kind, op: kind == .importItems ? .copy : nil)
                    running.append((nextRef, kind))
                    nextRef += 1
                case 3:
                    guard !running.isEmpty else { continue }
                    let call = running.remove(at: Int.random(in: 0..<running.count, using: &rng))
                    finish(&s, &j, call.ref, call.kind, undoable: Bool.random(using: &rng))
                case 4:
                    // A file leaves outside the journal (Finder, another app).
                    guard live.count > 2, let gone = live.randomElement(using: &rng) else { continue }
                    present.remove(gone)
                    let entries = present.sorted().map { F.entry("f\($0).txt", $0) }
                    run(&s, &j, .snapshot(F.snapshot(entries, at: F.t0 + 1), now: F.t0 + 1))
                case 5:
                    let label = j.undoLabel
                    let top = j.undoStack.last?.file
                    for effect in run(&s, &j, .undo) {
                        guard case let .undoFiles(ref) = effect else { continue }
                        replays += 1
                        #expect(top?.ref == ref && top?.phase == .ready, "replayed \(ref) under \(String(describing: top))")
                        #expect(label == j.undoStack.last(where: { $0.file?.ref == ref })?.label)
                        // The undo comes back, done or kept.
                        let kept = Bool.random(using: &rng)
                        run(&s, &j, .fileResult(FileReport(kind: .undo, count: 1, ticket: ref, kept: kept)))
                    }
                default:
                    run(&s, &j, .redo)
                }
                #expect(s.violations().isEmpty)
            }
        }
        #expect(replays > 10, "the sessions reached file entries")
    }

    // MARK: Where an entry stands

    @Test("A long copy keeps the place it was asked in: moves made meanwhile undo first, and its result clears no redo")
    func entryTakesItsPlaceAtRequest() {
        var s = F.mirrored(["a", "b", "c"])
        var j = UndoJournal()
        start(&s, &j, 1, .importItems, op: .copy)
        #expect(j.undoLabel == "Copy In")
        run(&s, &j, .move([F.key(1)], to: cell(5, 3)))
        run(&s, &j, .move([F.key(2)], to: cell(6, 3)))
        finish(&s, &j, 1, .importItems, placed: [.init(source: "/v/x", name: "x", key: F.key(70), copied: true)])
        #expect(j.undoLabel == "Move", "the copy did not jump over the moves")
        run(&s, &j, .undo)
        run(&s, &j, .undo)
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 0) && s.tokens.location(of: F.key(2)) == cell(1, 0))
        #expect(j.undoLabel == "Copy In" && run(&s, &j, .undo) == [.undoFiles(FileUndoRef(1))])

        // A result landing later leaves redo alone.
        var t = F.mirrored(["a", "b"])
        var k = UndoJournal()
        start(&t, &k, 2, .trash)
        run(&t, &k, .move([F.key(1)], to: cell(4, 2)))
        run(&t, &k, .undo)
        #expect(k.redoLabel == "Move")
        finish(&t, &k, 2, .trash, trashed: [F.key(2)])
        #expect(k.redoLabel == "Move" && k.undoLabel == "Move to Trash")
        run(&t, &k, .redo)
        #expect(t.tokens.location(of: F.key(1)) == cell(4, 2))
    }

    @Test("⌘Z on a running drop-in stops its copy; on a running trash or an undo under way it only says so")
    func busyEntries() {
        var s = F.mirrored(["a", "b"])
        var j = UndoJournal()
        start(&s, &j, 1, .trash)
        #expect(run(&s, &j, .undo) == [.toast(.fileBusy)] && j.undoLabel == "Move to Trash")
        finish(&s, &j, 1, .trash, trashed: [F.key(1)])
        start(&s, &j, 2, .importItems, op: .copy)
        #expect(run(&s, &j, .undo) == [.cancelFiles(FileUndoRef(2)), .toast(.stoppingCopy)])
        #expect(j.undoStack.last?.file?.phase == .running, "the entry waits for what landed before the stop")
        finish(&s, &j, 2, .importItems, placed: [.init(source: "/v/x", name: "x", key: F.key(80), copied: true)])
        #expect(run(&s, &j, .undo) == [.undoFiles(FileUndoRef(2))])
        #expect(run(&s, &j, .undo) == [.toast(.fileBusy)], "its undo is still running")
    }

    @Test("A kept undo leaves the entry ready for another ⌘Z; a spent one goes; an action that changed nothing goes")
    func entryEndings() {
        var s = F.mirrored(["a", "b"])
        var j = UndoJournal()
        start(&s, &j, 1, .trash)
        finish(&s, &j, 1, .trash, trashed: [F.key(1)])
        #expect(run(&s, &j, .undo) == [.undoFiles(FileUndoRef(1))])
        run(&s, &j, .fileResult(FileReport(kind: .undo, count: 1, problems: [.expired], ticket: FileUndoRef(1), kept: true)))
        #expect(j.undoStack.last?.file?.phase == .ready && j.undoLabel == "Move to Trash")
        #expect(run(&s, &j, .undo) == [.undoFiles(FileUndoRef(1))], "⌘Z tries again")
        run(&s, &j, .fileResult(FileReport(kind: .undo, count: 1, ticket: FileUndoRef(1), undoOf: .trash, done: .undidTrash)))
        #expect(j.undoLabel == nil && j.redoLabel == nil)

        start(&s, &j, 2, .importItems, op: .move)
        finish(&s, &j, 2, .importItems, undoable: false)
        #expect(j.undoLabel == nil, "nothing came in: no entry")
    }

    // MARK: files (0.3.0)

    @Test("Save as Text File: running, then ready under its label; ⌘Z replays its record; one that made nothing goes")
    func textFileEntry() {
        var s = F.mirrored(["a"])
        var j = UndoJournal()
        start(&s, &j, 1, .createTextFile)
        #expect(j.undoStack.last?.file?.phase == .running && j.undoLabel == "Save as Text File")
        #expect(run(&s, &j, .undo) == [.toast(.fileBusy)], "still writing")
        finish(&s, &j, 1, .createTextFile, placed: [.init(source: "memo:note:N1", name: "a 2.txt")])
        #expect(j.undoStack.last?.file?.phase == .ready && j.undoLabel == "Save as Text File")
        #expect(run(&s, &j, .undo) == [.undoFiles(FileUndoRef(1))])
        start(&s, &j, 2, .createTextFile)
        finish(&s, &j, 2, .createTextFile, undoable: false)
        #expect(!j.undoStack.contains { $0.file?.ref == FileUndoRef(2) })
    }

    @Test("A drop-in's label says what it did: Move In, Copy In, or Drop In for both")
    func importLabels() {
        let moved = FileReport.Placed(source: "/s/a", name: "a")
        let copied = FileReport.Placed(source: "/v/b", name: "b", copied: true)
        func label(_ placed: [FileReport.Placed], op: ImportOp) -> String? {
            var s = F.mirrored(["z"])
            var j = UndoJournal()
            start(&s, &j, 1, .importItems, op: op)
            finish(&s, &j, 1, .importItems, placed: placed)
            return j.undoLabel
        }
        #expect(label([moved], op: .move) == "Move In")
        #expect(label([copied], op: .move) == "Copy In", "a move that crossed volumes copied")
        #expect(label([moved, copied], op: .move) == "Drop In")
        #expect(label([copied], op: .copy) == "Copy In")
    }

    // MARK: Drop hints

    @Test("A drop whose name is taken never claims a safe-saved file of that name; its result places it by identity")
    func takenNameHintWaitsForIdentity() {
        var s = F.mirrored(["notes.txt", "b.txt"])
        let src = URL(fileURLWithPath: "/Volumes/USB/notes.txt")
        _ = reduce(&s, .requestDropIn(DropIn(urls: [src], location: .container(.cabinetFile, order: 0), op: .copy)), env)
        #expect(s.hints.count == 1 && s.hints[0].matchesName == false && s.hints[0].source == src.path)
        // While it copies, an editor safe-saves the desk's own notes.txt (a new inode under the same name).
        Reconciler.reconcile(&s, F.snapshot([F.entry("notes.txt", 77), F.entry("b.txt", 2)], at: F.t0 + 30), now: F.t0 + 30)
        #expect(s.tokens.location(of: F.key(77))?.isScreen == true, "the user's document stays on the monitor")
        // The copy lands as "notes 2.txt"; its result places it by identity.
        let landed = FileReport.Placed(source: src.path, name: "notes 2.txt", key: F.key(90), copied: true)
        let report = FileReport(kind: .importItems, count: 1, placed: [landed], undo: FileUndoRef(1))
        _ = reduce(&s, .fileResult(report), ReduceEnv(now: F.t0 + 31))
        Reconciler.reconcile(&s, F.snapshot([F.entry("notes.txt", 77), F.entry("b.txt", 2), F.entry("notes 2.txt", 90)],
                                            at: F.t0 + 31), now: F.t0 + 31)
        #expect(s.tokens.location(of: F.key(90))?.container == .cabinetFile)
        #expect(s.violations().isEmpty)
    }

    @Test("When the mirror sees a dropped file before its result, the result moves it from the monitor to its spot")
    func resultMovesAnEarlyArrival() {
        var s = F.mirrored(["notes.txt"])
        let src = URL(fileURLWithPath: "/Volumes/USB/notes.txt")
        _ = reduce(&s, .requestDropIn(DropIn(urls: [src], location: .container(.riserRight, order: 0), op: .copy)), env)
        Reconciler.reconcile(&s, F.snapshot([F.entry("notes.txt", 1), F.entry("notes 2.txt", 90)], at: F.t0 + 1), now: F.t0 + 1)
        #expect(s.tokens.location(of: F.key(90))?.isScreen == true)
        let landed = FileReport.Placed(source: src.path, name: "notes 2.txt", key: F.key(90), copied: true)
        let effects = reduce(&s, .fileResult(FileReport(kind: .importItems, count: 1, placed: [landed], undo: FileUndoRef(1))), env)
        #expect(s.tokens.location(of: F.key(90))?.container == .riserRight && effects.contains(.persist))
        #expect(s.tokens.location(of: F.key(1))?.isScreen == true && s.hints.isEmpty)
        #expect(s.violations().isEmpty)
    }

    @Test("Two items of one name in one drop each follow their own hint, by source path")
    func sameNameItemsInOneDrop() {
        var s = F.mirrored(["b.txt"])
        let x = URL(fileURLWithPath: "/x/a.txt"), y = URL(fileURLWithPath: "/y/a.txt")
        let d = DropIn(urls: [x, y], location: .container(.riserRight, order: 0), op: .move)
        _ = reduce(&s, .requestDropIn(d), env)
        #expect(s.hints.map(\.source) == [x.path, y.path] && s.hints.map(\.matchesName) == [true, false])
        let r = FileReport(kind: .importItems, count: 2, placed: [
            .init(source: x.path, name: "a.txt", key: F.key(50)), .init(source: y.path, name: "a 2.txt", key: F.key(51)),
        ], undo: FileUndoRef(1))
        _ = reduce(&s, .fileResult(r), env)
        Reconciler.reconcile(&s, F.snapshot([F.entry("b.txt", 1), F.entry("a.txt", 50), F.entry("a 2.txt", 51)],
                                            at: F.t0 + 1), now: F.t0 + 1)
        #expect(s.tokens.location(of: F.key(50))?.container == .riserRight)
        #expect(s.tokens.location(of: F.key(51))?.container == .riserRight)
    }

    @Test("A taken name is found case-insensitively and across drops still waiting")
    func takenNames() {
        var s = F.mirrored(["Report.PDF"])
        _ = reduce(&s, .requestDropIn(DropIn(urls: [URL(fileURLWithPath: "/a/report.pdf"), URL(fileURLWithPath: "/a/new.txt")],
                                             location: cell(3, 3), op: .move)), env)
        _ = reduce(&s, .requestDropIn(DropIn(urls: [URL(fileURLWithPath: "/b/NEW.txt")], location: cell(4, 3), op: .move)), env)
        #expect(s.hints.map(\.matchesName) == [false, true, false])
    }

    // MARK: Not connected

    @Test("Move to Trash, Empty Wastebasket and a drop while the folder is not connected say so")
    func notConnected() {
        var s = F.mirrored(["a.txt", "b.txt"])
        _ = reduce(&s, .move([F.key(2)], to: .container(.wastebasket, order: 0)), env)
        let drop = DropIn(urls: [URL(fileURLWithPath: "/x/n.txt")], location: cell(2, 2), op: .move)
        s.access = .denied
        #expect(reduce(&s, .requestTrash([F.key(1)]), env) == [.toast(.accessDenied)])
        #expect(reduce(&s, .requestEmptyWastebasket, env) == [.toast(.accessDenied)])
        #expect(reduce(&s, .requestDropIn(drop), env) == [.toast(.accessDenied)])
        for access in [DesktopAccess.notConnected, .finderHidden, .connecting] {
            s.access = access
            #expect(reduce(&s, .requestTrash([F.key(1)]), env) == [.toast(.filesUnavailable)], "\(access)")
        }
        #expect(reduce(&s, .requestTrash([]), env).isEmpty, "nothing asked, nothing said")
    }
}

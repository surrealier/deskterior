import Foundation
import Testing
@testable import DeskCore

@Suite("File actions in the reducer (M11)")
struct FileActionReducerTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    func url(_ name: String) -> URL { URL(fileURLWithPath: F.rootPath).appendingPathComponent(name) }

    // MARK: Requests

    @Test("Move to Trash names each live token's file with the identity it must still have; nothing changes yet")
    func trashRequest() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt"])
        let before = s
        let effects = reduce(&s, .requestTrash([F.key(2), F.key(1), F.key(2), F.key(99)]), env)
        #expect(effects == [.trash([url("b.txt"), url("a.txt")], expected: [F.key(2), F.key(1)], confirm: nil)])
        #expect(s == before, "the token stays until the operator has done it")
        // A stale layout (not connected) resolves no file at all.
        s.access = .notConnected
        #expect(reduce(&s, .requestTrash([F.key(1)]), env).isEmpty)
    }

    @Test("Empty Wastebasket asks first: a sheet with the count and the first names, by name")
    func emptyRequest() {
        var s = F.mirrored((0..<23).map { "f\($0).txt" })
        #expect(reduce(&s, .requestEmptyWastebasket, env).isEmpty, "an empty basket asks nothing")
        let keys = (1...22).map { F.key(UInt64($0)) }
        _ = reduce(&s, .move(keys, to: .container(.wastebasket, order: 0)), env)
        let effects = reduce(&s, .requestEmptyWastebasket, env)
        guard case let .trash(urls, expected, confirm?)? = effects.first, effects.count == 1 else {
            Issue.record("expected one confirmed trash, got \(effects)")
            return
        }
        #expect(urls.count == 22 && Set(expected) == Set(keys))
        guard case let .emptyWastebasket(names, more) = confirm else { return }
        #expect(names.count == MenuSpec.listLimit && more == 2)
        #expect(names.prefix(3) == ["f0.txt", "f1.txt", "f2.txt"] && names.contains("f10.txt"))
        #expect(s.tokens.count(in: .wastebasket) == 22, "the basket never empties itself")
    }

    @Test("Eject only an ejectable listed volume, by its mount path; Open and Show in Finder hand it to Finder")
    func volumeRequests() {
        var s = F.mirrored(["a"])
        s.volumes = [
            VolumeEntry(id: "U1", name: "Stick", path: "/Volumes/Stick", kind: .removable, isEjectable: true),
            VolumeEntry(id: "U2", name: "Inside", path: "/Volumes/Inside", kind: .internalDisk, isEjectable: false),
        ]
        #expect(reduce(&s, .requestEject("U1"), env) == [.eject("/Volumes/Stick")])
        #expect(reduce(&s, .requestEject("U2"), env).isEmpty)
        #expect(reduce(&s, .requestEject("nope"), env).isEmpty)
        let stick = URL(fileURLWithPath: "/Volumes/Stick", isDirectory: true)
        #expect(reduce(&s, .requestOpenVolume("U1"), env) == [.open([stick])])
        #expect(reduce(&s, .requestRevealVolume("U1"), env) == [.reveal([stick])])
        #expect(reduce(&s, .requestOpenVolume("nope"), env).isEmpty)
    }

    @Test("A drop from outside registers name hints (with a new pile's spot) and asks to import; desk items only move")
    func dropIn() {
        var s = F.mirrored(["a.txt", "b.txt"])
        let pile = s.makePileID()
        let outside = [URL(fileURLWithPath: "/elsewhere/new.txt"), URL(fileURLWithPath: "/elsewhere/b.txt")]
        let d = DropIn(urls: outside + [url("a.txt")], location: .desk(pile: pile, order: 0), pilePos: [120, 40], op: .move)
        var journal = UndoJournal()
        let effects = Reducer.reduce(&s, journal: &journal, .requestDropIn(d), env)
        #expect(effects.contains(.importFiles(outside, op: .move, hints: ["new.txt": d.location, "b.txt": d.location])))
        #expect(s.tokens.location(of: F.key(1))?.pile == pile && s.piles[pile] == [120, 40], "a.txt is a desk item: it moves")
        #expect(journal.undoLabel == "Move")
        #expect(s.hints.map(\.name).sorted() == ["b.txt", "new.txt"] && s.hints.allSatisfy { $0.pilePos == [120, 40] })
        #expect(s.violations().isEmpty)
        // `importDropped` is the same request without a pile spot.
        var t = F.mirrored(["a.txt"])
        #expect(reduce(&t, .importDropped(outside, at: .floor(x: 40), op: .copy), env)
            == [.importFiles(outside, op: .copy, hints: ["new.txt": .floor(x: 40), "b.txt": .floor(x: 40)])])
        // Nothing comes in while the mirror is not current.
        t.access = .denied
        #expect(reduce(&t, .requestDropIn(d), env).isEmpty)
    }

    @Test("A dropped file lands where its hint says, a new pile at the hint's spot")
    func hintPlacesNewPile() {
        var s = F.mirrored(["a.txt"])
        let pile = s.makePileID()
        let d = DropIn(urls: [URL(fileURLWithPath: "/elsewhere/new.txt")], location: .desk(pile: pile, order: 0),
                       pilePos: [200, 30], op: .move)
        _ = reduce(&s, .requestDropIn(d), env)
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("new.txt", 7)]), now: F.t0)
        #expect(s.tokens.location(of: F.key(7)) == .desk(pile: pile, order: 0))
        #expect(s.piles[pile] == [200, 30] && s.violations().isEmpty)
    }

    // MARK: Results

    @Test("Trashed tokens leave at once with a poof and a tombstone; undo brings the same file back to the same place")
    func trashResult() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt"])
        _ = reduce(&s, .move([F.key(3)], to: .container(.riserLeft, order: 0)), env)
        let cellA = s.tokens.location(of: F.key(1))!
        var journal = UndoJournal()
        let report = FileReport(kind: .trash, count: 2, trashed: [F.key(1), F.key(3)], undo: FileUndoRef(7))
        let effects = Reducer.reduce(&s, journal: &journal, .fileResult(report), env)
        #expect(effects.contains(.play(.poof, .location(cellA))))
        #expect(effects.contains(.play(.handleWiggle, .container(.riserLeft))))
        #expect(effects.contains(.persist) && !effects.contains { $0.mutatesFiles })
        #expect(!s.tokens.contains(F.key(1)) && !s.tokens.contains(F.key(3)) && s.tokens.contains(F.key(2)))
        #expect(s.tombstones.map(\.key).sorted() == [F.key(1), F.key(3)])
        #expect(journal.undoLabel == "Move to Trash")
        #expect(s.violations().isEmpty)

        // ⌘Z asks the app to replay the record; the mirror then sees the files return under the same inodes.
        #expect(Reducer.reduce(&s, journal: &journal, .undo, env) == [.undoFiles(FileUndoRef(7))])
        #expect(journal.undoLabel == nil && journal.redoLabel == nil, "a file action is not redone")
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 2), F.entry("c.txt", 3)]), now: F.t0 + 1)
        #expect(s.tokens.location(of: F.key(1)) == cellA)
        #expect(s.tokens.location(of: F.key(3))?.container == .riserLeft)
    }

    @Test("Empty Wastebasket's undo brings the files back into the basket (by identity)")
    func emptyResultAndUndo() {
        var s = F.mirrored(["a.txt", "b.txt"])
        _ = reduce(&s, .move([F.key(1), F.key(2)], to: .container(.wastebasket, order: 0)), env)
        var journal = UndoJournal()
        let report = FileReport(kind: .emptyWastebasket, count: 2, trashed: [F.key(1), F.key(2)], undo: FileUndoRef(1))
        let effects = Reducer.reduce(&s, journal: &journal, .fileResult(report), env)
        #expect(effects.filter { $0 == .play(.handleWiggle, .container(.wastebasket)) }.count == 2)
        #expect(s.tokens.count(in: .wastebasket) == 0 && journal.undoLabel == "Empty Wastebasket")
        _ = Reducer.reduce(&s, journal: &journal, .undo, env)
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 2)]), now: F.t0 + 1)
        #expect(s.tokens.count(in: .wastebasket) == 2)
    }

    @Test("Refusals become one toast: the first problem's, or 'some stayed' when others went through")
    func toasts() {
        func toast(_ r: FileReport) -> [Effect] {
            var s = F.mirrored(["a.txt", "b.txt"])
            return reduce(&s, .fileResult(r), env).filter { if case .toast = $0 { true } else { false } }
        }
        #expect(toast(FileReport(kind: .trash, count: 1, problems: [.changed])) == [.toast(.fileChanged)])
        #expect(toast(FileReport(kind: .trash, count: 1, problems: [.gone])) == [.toast(.fileGone)])
        #expect(toast(FileReport(kind: .trash, count: 2, trashed: [F.key(1)], problems: [.notPermitted]))
            == [.toast(.someNotDone)])
        #expect(toast(FileReport(kind: .undo, count: 1, problems: [.notPermitted])) == [.toast(.usePutBack)])
        #expect(toast(FileReport(kind: .undo, count: 1, problems: [.notInTrash])) == [.toast(.usePutBack)])
        #expect(toast(FileReport(kind: .eject, count: 1, problems: [.outside])) == [.toast(.ejectFailed)])
        #expect(toast(FileReport(kind: .importItems, count: 1, problems: [.holdsDesk])) == [.toast(.dropHoldsDesk)])
        #expect(toast(FileReport(kind: .importItems, count: 1, problems: [.noFreeName])) == [.toast(.nameTaken)])
        #expect(toast(FileReport(kind: .trash, count: 1, problems: [.expired])) == [.toast(.fileFailed)])
        #expect(toast(FileReport(kind: .trash, count: 1, trashed: [F.key(1)])).isEmpty)
        for p in FileProblem.allCases {
            #expect(FileReport(kind: .importItems, count: 1, problems: [p]).toast != nil, "\(p) has a toast")
        }
    }

    @Test("An import's hints follow the names files landed under, with their identity; refused files' hints go")
    func importFollowsNames() {
        var s = F.mirrored(["notes.md", "a.txt"])
        let src = [URL(fileURLWithPath: "/elsewhere/notes.md"), URL(fileURLWithPath: "/elsewhere/x.txt")]
        _ = reduce(&s, .requestDropIn(DropIn(urls: src, location: .container(.wastebasket, order: 0), op: .move)), env)
        var journal = UndoJournal()
        let report = FileReport(
            kind: .importItems, count: 2, placed: [.init(source: "notes.md", name: "notes 2.md", key: F.key(40))],
            refusedNames: ["x.txt"], problems: [.notPermitted], undo: FileUndoRef(3)
        )
        let effects = Reducer.reduce(&s, journal: &journal, .fileResult(report), env)
        #expect(effects == [.toast(.someNotDone)])
        #expect(s.hints.map(\.name) == ["notes 2.md"] && s.hints[0].key == F.key(40))
        #expect(journal.undoLabel == "Drop In")
        // With its identity the hint may even place the file in the wastebasket (a name-only one never does).
        Reconciler.reconcile(&s, F.snapshot([F.entry("notes.md", 1), F.entry("a.txt", 2), F.entry("notes 2.md", 40)]), now: F.t0)
        #expect(s.tokens.location(of: F.key(40))?.container == .wastebasket)
    }

    @Test("Results and file undo entries keep the rule: only requests (and ⌘Z of a file entry) reach files")
    func fileEffectRule() {
        var s = F.mirrored(["a.txt"])
        var journal = UndoJournal()
        let results: [FileReport] = FileReport.Kind.allCases.map {
            FileReport(kind: $0, count: 1, trashed: [F.key(1)], problems: [.failed], undo: FileUndoRef(9))
        }
        for r in results {
            let effects = Reducer.reduce(&s, journal: &journal, .fileResult(r), env)
            #expect(!effects.contains { $0.touchesFiles }, "\(r.kind) emitted \(effects)")
            #expect(!DeskAction.fileResult(r).isRequest)
        }
        #expect(DeskAction.requestDropIn(DropIn(urls: [], location: .floor(x: 0), op: .move)).isRequest)
        #expect(DeskAction.requestOpenVolume("v").isRequest && DeskAction.requestRevealVolume("v").isRequest)
        #expect(DeskAction.undo.isRequest && !DeskAction.redo.isRequest, "⌘Z replays a file record; redo never does")
        #expect(Effect.undoFiles(FileUndoRef(1)).mutatesFiles && Effect.undoFiles(FileUndoRef(1)).touchesFiles)
        // The newest file entry undoes first; a layout entry under it still undoes as before.
        var t = F.mirrored(["a.txt", "b.txt"])
        var j = UndoJournal()
        _ = Reducer.reduce(&t, journal: &j, .move([F.key(2)], to: .container(.phone, order: 0)), env)
        _ = Reducer.reduce(&t, journal: &j, .fileResult(FileReport(kind: .trash, count: 1, trashed: [F.key(1)],
                                                                 undo: FileUndoRef(2))), env)
        #expect(Reducer.reduce(&t, journal: &j, .undo, env) == [.undoFiles(FileUndoRef(2))])
        #expect(j.undoLabel == "Move")
        _ = Reducer.reduce(&t, journal: &j, .undo, env)
        #expect(t.tokens.location(of: F.key(2))?.isScreen == true)
    }

    // MARK: Drag-out

    @Test("Drag-out: nothing, a copy or a link change nothing; a move waits for the mirror; the Dock Trash trashes")
    func dragOutRule() {
        #expect(DragOutRule.plan(.none) == .returnHome && DragOutRule.plan(.copy) == .returnHome)
        #expect(DragOutRule.plan(.link) == .returnHome)
        #expect(DragOutRule.plan(.move) == .waitForRemoval(seconds: 5, thenTrash: false))
        #expect(DragOutRule.plan(.generic) == .waitForRemoval(seconds: 5, thenTrash: false))
        #expect(DragOutRule.plan(.delete) == .waitForRemoval(seconds: 1.5, thenTrash: true))
        let still = [F.key(1)]
        #expect(DragOutRule.toTrash(DragOutRule.plan(.delete), stillThere: still) == still)
        #expect(DragOutRule.toTrash(DragOutRule.plan(.move), stillThere: still).isEmpty, "a move never trashes")
        #expect(DragOutRule.toTrash(.returnHome, stillThere: still).isEmpty)
        #expect(DragOutRule.offered(alwaysCopy: true) == [.copy])
        #expect(Set(DragOutRule.offered(alwaysCopy: false)) == [.copy, .move, .link, .generic, .delete])
    }

    // MARK: Menus

    @Test("Move to Trash and Empty Wastebasket are live; the drive menu offers Open, Show in Finder, Eject")
    func menus() {
        var s = F.mirrored(["a.txt", "b.txt"])
        #expect(!MenuSpec.pending.contains("trash") && !MenuSpec.pending.contains("emptyWastebasket"))
        #expect(MenuSpec.token([F.key(1)], s).item("trash")?.isEnabled == true)
        _ = reduce(&s, .move([F.key(2)], to: .container(.wastebasket, order: 0)), env)
        #expect(MenuSpec.wastebasket(s).item("emptyWastebasket")?.isEnabled == true)
        #expect(MenuSpec.desk(s).item("emptyWastebasket")?.isEnabled == true)
        if case .requestTrash([F.key(1)])? = MenuSpec.token([F.key(1)], s).item("trash")?.command?.action(s) {} else {
            Issue.record("Move to Trash is a request")
        }

        let v = VolumeEntry(id: "U1", name: "Stick", path: "/Volumes/Stick", kind: .removable, isEjectable: true)
        let drive = MenuSpec.drive(v)
        #expect(drive.ids == ["drive.open", "drive.reveal", "drive.eject"])
        #expect(drive.item("drive.eject")?.title == "Eject “Stick”")
        if case .requestEject("U1")? = drive.item("drive.eject")?.command?.action(s) {} else { Issue.record("eject") }
        if case .requestOpenVolume("U1")? = drive.item("drive.open")?.command?.action(s) {} else { Issue.record("open") }
        if case .requestRevealVolume("U1")? = drive.item("drive.reveal")?.command?.action(s) {} else { Issue.record("reveal") }
        var fixed = v
        fixed.isEjectable = false
        #expect(MenuSpec.drive(fixed).item("drive.eject")?.isEnabled == false)

        let five = (0..<5).map { VolumeEntry(id: "V\($0)", name: "D\($0)", path: "/Volumes/D\($0)", kind: .externalDisk, isEjectable: true) }
        let split = MenuSpec.hubSplit(five)
        #expect(split.shown.count == MenuSpec.hubSlots && split.more.map(\.id) == ["V4"])
        let more = MenuSpec.drives(split.more, from: MenuSpec.hubSlots)
        #expect(more.ids == ["drive.4", "drive.4.open", "drive.4.reveal", "drive.4.eject"])
    }
}

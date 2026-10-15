import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// The app side of `FileOperator` (M11): which origin each file effect is minted with, where file actions may act in
/// each run mode, and what a `FileResult` means for the model.
@Suite("File reports and intent origins")
struct FileReportsTests {
    @Test("Each file effect is minted with the one origin its request's gesture allows; none without a gesture")
    func mintedOrigins() {
        let u = [URL(fileURLWithPath: "/x/a.txt")]
        let k = [TokenKey(volume: "V", inode: 1)]
        let plain = Effect.trash(u, expected: k, confirm: nil)
        let sheet = Effect.trash(u, expected: k, confirm: .emptyWastebasket(names: ["a.txt"], more: 0))
        let drop = Effect.importFiles(u, ops: [.move], hints: [:])
        let undo = Effect.undoFiles(FileUndoRef(1))
        typealias O = ExplicitIntent.Origin
        for o in [O.menuItem, .inventory, .dragToTrash] { #expect(O.minted(for: plain, requestedVia: o) == o) }
        for o in [O.drop, .undo, .sheetConfirm] { #expect(O.minted(for: plain, requestedVia: o) == nil, "\(o)") }
        #expect(O.minted(for: sheet, requestedVia: .menuItem) == nil, "not before the sheet is confirmed")
        #expect(O.minted(for: sheet, requestedVia: .menuItem, confirmed: true) == .sheetConfirm)
        #expect(O.minted(for: sheet, requestedVia: .drop, confirmed: true) == nil, "the sheet is asked for from a menu")
        #expect(O.minted(for: drop, requestedVia: .drop) == .drop)
        #expect(O.minted(for: drop, requestedVia: .menuItem) == nil, "a drop-in needs a drop")
        #expect(O.minted(for: undo, requestedVia: .undo) == .undo && O.minted(for: undo, requestedVia: .menuItem) == .undo)
        #expect(O.minted(for: undo, requestedVia: .drop) == nil && O.minted(for: undo, requestedVia: .inventory) == nil)
        #expect(O.minted(for: .eject("/Volumes/X"), requestedVia: .inventory) == .inventory)
        #expect(O.minted(for: .eject("/Volumes/X"), requestedVia: .dragToTrash) == nil)
        // No gesture named: nothing is minted, whatever the effect.
        for e in [plain, drop, undo, Effect.eject("/Volumes/X")] {
            #expect(O.minted(for: e, requestedVia: nil) == nil, "\(e)")
            #expect(O.minted(for: e, requestedVia: nil, confirmed: true) == nil, "\(e)")
        }
        #expect(O.minted(for: sheet, requestedVia: nil, confirmed: true) == nil)
        for e: Effect in [.open(u), .reveal(u), .quickLook(u), .copy(u), .persist, .connectDesktop, .cancelFiles(FileUndoRef(1))] {
            #expect(O.minted(for: e, requestedVia: .menuItem) == nil, "\(e) changes no file")
        }
        // Every minted origin is one FileOperator accepts for that method (Errata 14).
        #expect(FileOperator.Method.trash.origins.contains(.sheetConfirm))
        #expect(FileOperator.Method.importItems.origins == [.drop] && FileOperator.Method.undo.origins == [.undo])
    }

    @Test("Only desk mode uses the real Trash; every other mode the FakeTrash in the state folder, confined")
    func scopes() {
        let folder = URL(fileURLWithPath: "/tmp/fixture", isDirectory: true)
        let state = URL(fileURLWithPath: "/tmp/state", isDirectory: true)
        let source = URL(fileURLWithPath: "/tmp/source", isDirectory: true)
        let desk = FileActionScope(mode: .desk, folder: folder, stateDirectory: state)
        #expect(desk.trashFolder == nil && desk.sandboxRoots == nil)
        for mode: SafetyGuard.Mode in [.windowed, .headless, .demo, .test, .tool] {
            let s = FileActionScope(mode: mode, folder: folder, stateDirectory: state, extraRoots: [source])
            #expect(s.trashFolder == state.appendingPathComponent("FakeTrash", isDirectory: true), "\(mode)")
            #expect(s.sandboxRoots == [folder, state, source], "\(mode)")
            if case .system = s.trash { Issue.record("\(mode) would use the real Trash") }
        }
    }

    @Test("Refusals map onto the model's problems")
    func problems() {
        let cases: [(FileRefusal, FileProblem)] = [
            (.identityChanged, .changed), (.missing, .gone), (.notPermitted, .notPermitted), (.notInTrash, .notInTrash),
            (.noFreeName, .noFreeName), (.containsDesktop, .holdsDesk), (.volumeRoot, .wholeVolume),
            (.outsideRoot, .outside), (.outsideSandbox, .outside), (.notEjectable, .outside), (.staleIntent, .expired),
            (.spentIntent, .expired), (.cancelled, .expired), (.unknownRecord, .expired), (.wrongOrigin, .failed),
            (.mismatchedRequest, .failed), (.failed(5), .failed),
        ]
        for (refusal, problem) in cases { #expect(FileProblem(refusal) == problem, "\(refusal)") }
    }

    @Test("A trash report names the tokens whose files went; one that changed meanwhile stays, with a problem")
    func trashReport() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let b = try rig.file(rig.desk, "b.txt")
        let keys = [rig.key(a), TokenKey(volume: rig.key(b).volume, inode: rig.key(b).inode + 1_000_000)]
        let result = await rig.op.trash([a, b], expecting: keys, rig.intent())
        let report = FileReport(trash: result, keys: keys, kind: .emptyWastebasket, undo: FileUndoRef(4))
        #expect(report.kind == .emptyWastebasket && report.count == 2)
        #expect(report.trashed == [keys[0]] && report.problems == [.changed] && report.undo == FileUndoRef(4))
        #expect(report.toast == .someChanged)
        #expect(rig.trashNames == ["a.txt"] && rig.exists(b))

        // Undo of it: the report carries nothing to change in the model, no problem, and says what it did.
        let undo = await rig.op.undo(try #require(result.undo), rig.intent(.undo))
        let undone = FileReport(undo: undo, of: .emptyWastebasket, ticket: FileUndoRef(4))
        #expect(undone.kind == .undo && undone.problems.isEmpty && rig.exists(a) && rig.inode(a) == keys[0].inode)
        #expect(undone.toast == .undidTrash && undone.ticket == FileUndoRef(4) && !undone.kept)
    }

    @Test("A refused undo of a drop-in never points at Put Back; one of a trash does; each success says what it did")
    func undoToasts() async throws {
        let refused = FileResult(outcomes: [.refused(URL(fileURLWithPath: "/d/x.txt"), .notPermitted)], undo: nil)
        #expect(FileReport(undo: refused, of: .importItems).toast == .cantMoveBack, "S12: the source is protected")
        #expect(FileReport(undo: refused, of: .trash).toast == .usePutBack, "S11: the Trash is protected")
        #expect(FileReport(undo: refused, of: .emptyWastebasket).toast == .usePutBack)
        let changed = FileResult(outcomes: [.refused(URL(fileURLWithPath: "/d/x.txt"), .identityChanged)], undo: nil)
        #expect(FileReport(undo: changed, of: .importItems).toast == .fileChanged)

        let rig = try FileRig()
        let moving = try rig.file(rig.elsewhere, "moving.txt")
        let copying = try rig.file(rig.elsewhere, "copying.txt")
        let moved = await rig.op.importItems([moving], op: .move, rig.intent(.drop))
        let copied = await rig.op.importItems([copying], op: .copy, rig.intent(.drop))
        let movedBack = await rig.op.undo(try #require(moved.undo), rig.intent(.undo))
        let trashedCopy = await rig.op.undo(try #require(copied.undo), rig.intent(.undo))
        #expect(FileReport(undo: movedBack, of: .importItems).toast == .undidMoveIn)
        #expect(FileReport(undo: trashedCopy, of: .importItems).toast == .undidCopyIn)
        let both = FileResult(outcomes: movedBack.outcomes + trashedCopy.outcomes, undo: nil)
        #expect(FileReport(undo: both, of: .importItems).toast == .undidDropIn)
        #expect(rig.exists(moving) && !rig.exists(rig.at(rig.desk, "copying.txt")))
    }

    @Test("An undo refused before it ran keeps its record, which redeems later; one that ran spends it")
    func keptRecords() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let trashed = await rig.op.trash([a], expecting: [rig.key(a)], rig.intent())
        let record = try #require(trashed.undo)
        // A stale intent (an actor busy for > 10 s): refused before the record is redeemed.
        let stale = await rig.op.undo(record, rig.intent(.undo, age: 11))
        #expect(FileReport.recordKept(stale) && FileReport(undo: stale, of: .trash, kept: true).kept)
        #expect(FileReport(undo: stale, of: .trash).toast == .fileFailed)
        let again = await rig.op.undo(record, rig.intent(.undo))
        #expect(again.refusals.isEmpty && rig.exists(a), "the kept record still redeems")
        #expect(!FileReport.recordKept(again))
        let spent = await rig.op.undo(record, rig.intent(.undo))
        #expect(spent.refusals == [.unknownRecord] && !FileReport.recordKept(spent), "a spent record is not kept")
    }

    @Test("An import report follows each item to its name on the desk (\" 2\" after a clash), with its identity there")
    func importReport() async throws {
        let rig = try FileRig()
        try rig.file(rig.desk, "notes.md", "mine")
        let notes = try rig.file(rig.elsewhere, "notes.md", "dropped")
        let fresh = try rig.file(rig.elsewhere, "fresh.txt")
        let missing = rig.at(rig.elsewhere, "gone.txt")
        let movedInode = rig.inode(notes)
        let result = await rig.op.importItems([notes, fresh, missing], op: .move, rig.intent(.drop))
        let report = FileReport(import: result, undo: FileUndoRef(2))
        #expect(report.placed.map(\.source) == [notes.path, fresh.path], "items are named by their source paths")
        #expect(report.placed.map(\.name) == ["notes 2.md", "fresh.txt"])
        #expect(report.placed[0].key?.inode == movedInode, "a same-volume move keeps the inode")
        #expect(report.placed[0].key == rig.key(rig.at(rig.desk, "notes 2.md")))
        #expect(report.placed.allSatisfy { !$0.copied } && report.undoLabel == "Move In")
        #expect(report.refused == [missing.path] && report.problems == [.gone] && report.toast == .someGone)

        // A copy's identity is the copy's.
        let copied = try rig.file(rig.elsewhere, "copy.txt")
        let copy = FileReport(import: await rig.op.importItems([copied], op: .copy, rig.intent(.drop)), undo: nil)
        #expect(copy.placed.first?.key == rig.key(rig.at(rig.desk, "copy.txt")))
        #expect(copy.placed.first?.key?.inode != rig.inode(copied))
        #expect(copy.placed.first?.copied == true && copy.undoLabel == "Copy In")
    }

    @Test("An eject refused outside desk mode reports a problem; nothing is unmounted")
    func ejectReport() async throws {
        let rig = try FileRig()
        let outcome = await rig.op.eject(rig.desk, rig.intent())
        let report = FileReport(eject: outcome)
        #expect(report.problems == [.outside] && report.toast == .ejectFailed)
    }

    @Test("Identity is the item itself: a symlink's own inode, not its target's")
    func identity() throws {
        let rig = try FileRig()
        let target = try rig.file(rig.elsewhere, "target.txt")
        let link = rig.at(rig.desk, "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(FileReport.identity(of: link) == rig.key(link))
        #expect(FileReport.identity(of: link) != rig.key(target))
        #expect(FileReport.identity(of: rig.at(rig.desk, "nope")) == nil)
    }
}

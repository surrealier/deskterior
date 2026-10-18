import Foundation
import Testing
@testable import DeskCore

/// One editing session of a note or a day page is one undo entry (`UndoJournal.record(…, coalesce:)`), so the
/// 20-entry journal never loses a file action to typing.
@Suite("Undo: editing sessions")
struct UndoCoalesceTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)
    let day = DayKey("2026-10-18")!

    @discardableResult
    func run(_ s: inout DeskState, _ j: inout UndoJournal, _ a: DeskAction) -> [Effect] {
        Reducer.reduce(&s, journal: &j, a, env)
    }

    func note(_ s: inout DeskState, _ text: String = "") -> NoteID {
        let id = s.memos.nextNoteID
        _ = reduce(&s, .addNote(NewNote(id: id, text: text, colour: .yellow), session: nil), env)
        return id
    }

    @Test("The session keys: a note's or a day's, with the session; none for other actions")
    func keys() {
        let n = NoteID(3)
        #expect(UndoJournal.coalesceKey(for: .editNote(n, text: "x", session: 7)) == "note:N3:7")
        #expect(UndoJournal.coalesceKey(for: .addNote(NewNote(id: n, text: "", colour: .sky), session: 7)) == "note:N3:7")
        #expect(UndoJournal.coalesceKey(for: .addNote(NewNote(id: n, text: "", colour: .sky), session: nil)) == nil)
        #expect(UndoJournal.coalesceKey(for: .editDayPage(day, text: "x", session: 2)) == "day:2026-10-18:2")
        for a: DeskAction in [.noteColour(n, .lime), .removeNote(n), .moveNote(n, to: ArtPoint(0, 0)), .takeEverythingOut] {
            #expect(UndoJournal.coalesceKey(for: a) == nil, "\(a)")
        }
    }

    @Test("Ten commits of one session are one entry; one undo takes back all of them")
    func oneSessionOneEntry() {
        var s = F.mirrored(["a.txt"])
        let id = note(&s, "start")
        var j = UndoJournal()
        for i in 1...10 { run(&s, &j, .editNote(id, text: "start \(i)", session: 4)) }
        #expect(j.undoStack.count == 1 && j.undoLabel == "Edit Note" && s.memos.notes[id]?.text == "start 10")
        run(&s, &j, .undo)
        #expect(s.memos.notes[id]?.text == "start" && j.undoStack.isEmpty && j.redoLabel == "Edit Note")
        run(&s, &j, .redo)
        #expect(s.memos.notes[id]?.text == "start 10")
    }

    @Test("Another session, another note or a day page starts a new entry")
    func newEntries() {
        var s = F.mirrored(["a.txt"])
        let a = note(&s), b = note(&s)
        var j = UndoJournal()
        run(&s, &j, .editNote(a, text: "1", session: 1))
        run(&s, &j, .editNote(a, text: "12", session: 1))
        run(&s, &j, .editNote(a, text: "123", session: 2))
        run(&s, &j, .editNote(b, text: "x", session: 2))
        run(&s, &j, .editDayPage(day, text: "p", session: 2))
        run(&s, &j, .editDayPage(day, text: "pp", session: 2))
        #expect(j.undoStack.map(\.label) == ["Edit Note", "Edit Note", "Edit Note", "Edit Memo"])
        // Something else in between ends the session's entry: the next commit starts another.
        run(&s, &j, .noteColour(a, .pink))
        run(&s, &j, .editDayPage(day, text: "ppp", session: 2))
        #expect(j.undoStack.map(\.label).suffix(3) == ["Edit Memo", "Note Colour", "Edit Memo"])
    }

    @Test("A session that types its way back to where it began leaves no entry")
    func backToStart() {
        var s = F.mirrored(["a.txt"])
        let id = note(&s, "same")
        var j = UndoJournal()
        run(&s, &j, .move([F.key(1)], to: .screen(page: 0, col: 3, row: 3)))
        // The clock moves between commits, as it does in the app: the note's edit time is not a change anyone sees.
        _ = Reducer.reduce(&s, journal: &j, .editNote(id, text: "samex", session: 1), ReduceEnv(now: F.t0 + 5))
        _ = Reducer.reduce(&s, journal: &j, .editNote(id, text: "same", session: 1), ReduceEnv(now: F.t0 + 9))
        #expect(j.undoStack.map(\.label) == ["Move"])
        run(&s, &j, .editDayPage(day, text: "x", session: 1))
        run(&s, &j, .editDayPage(day, text: "", session: 1))
        #expect(j.undoStack.map(\.label) == ["Move"] && s.memos.pages.isEmpty)
        // A session that ends somewhere else stays.
        run(&s, &j, .editNote(id, text: "samex", session: 2))
        _ = Reducer.reduce(&s, journal: &j, .editNote(id, text: "same!", session: 2), ReduceEnv(now: F.t0 + 12))
        #expect(j.undoStack.map(\.label) == ["Move", "Edit Note"])
    }

    @Test("New Sticky Note and the typing in its editor are one entry")
    func newNoteSession() {
        var s = F.mirrored(["a.txt"])
        var j = UndoJournal()
        let id = s.memos.nextNoteID
        run(&s, &j, .addNote(NewNote(id: id, text: "", colour: .yellow), session: 8))
        for text in ["우", "우유", "우유 사기"] { run(&s, &j, .editNote(id, text: text, session: 8)) }
        #expect(j.undoStack.count == 1 && j.undoLabel == "New Sticky Note" && s.memos.notes[id]?.text == "우유 사기")
        run(&s, &j, .undo)
        #expect(s.memos.notes.isEmpty)
        run(&s, &j, .redo)
        #expect(s.memos.notes[id]?.text == "우유 사기")
    }

    @Test("A Move to Trash under a typing session survives 50 commits")
    func fileEntrySurvives() {
        var s = F.mirrored(["a.txt", "b.txt"])
        let id = note(&s)
        var j = UndoJournal()
        run(&s, &j, .editNote(id, text: "x", session: 1))
        run(&s, &j, .fileStarted(FileUndoRef(5), .trash, op: nil))
        run(&s, &j, .fileResult(FileReport(kind: .trash, count: 1, trashed: [F.key(2)], undo: FileUndoRef(5),
                                           ticket: FileUndoRef(5))))
        for i in 0..<50 { run(&s, &j, .editNote(id, text: "x\(i)", session: 1)) }
        #expect(j.undoStack.map(\.label) == ["Edit Note", "Move to Trash", "Edit Note"])
        // The typing undoes first; then ⌘Z replays the trash's record.
        run(&s, &j, .undo)
        #expect(s.memos.notes[id]?.text == "x")
        #expect(run(&s, &j, .undo) == [.undoFiles(FileUndoRef(5))])
    }

    @Test("A session's entry takes only its own change: a pile that settles meanwhile does not move back on undo")
    func mergeKeepsOtherChanges() {
        var s = F.mirrored(["a.txt"])
        let id = note(&s)
        _ = reduce(&s, .dropOnDesk([F.key(1)], pile: "P1", at: [200, 40]), env)
        var j = UndoJournal()
        run(&s, &j, .editNote(id, text: "a", session: 1))
        _ = reduce(&s, .pilesSettled(["P1": [210, 44]]), env)
        run(&s, &j, .editNote(id, text: "ab", session: 1))
        #expect(j.undoStack.count == 1)
        run(&s, &j, .undo)
        #expect(s.memos.notes[id]?.text == "" && s.piles[PileID("P1")] == [210, 44])
    }
}

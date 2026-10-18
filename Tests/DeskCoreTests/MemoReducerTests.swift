import Foundation
import Testing
@testable import DeskCore

/// Sticky notes, the day pages and the D-Day in the reducer (Erratum 31): caps, clean text, ids never reused, where
/// notes rest, and undo per note and per day page.
@Suite("Memos in the reducer")
struct MemoReducerTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)
    let day = DayKey("2026-10-18")!

    @discardableResult
    func run(_ s: inout DeskState, _ j: inout UndoJournal, _ a: DeskAction) -> [Effect] {
        Reducer.reduce(&s, journal: &j, a, env)
    }

    /// Adds a note with the next id; returns that id.
    @discardableResult
    func add(_ s: inout DeskState, _ text: String = "", colour: NoteColour = .yellow, day: DayKey? = nil,
             at: ArtPoint? = nil) -> NoteID {
        let id = s.memos.nextNoteID
        _ = reduce(&s, .addNote(NewNote(id: id, text: text, colour: colour, day: day, at: at), session: nil), env)
        return id
    }

    // MARK: Notes

    @Test("New Sticky Note: the next id, the first free spot, in front, clean text; a pop, no save")
    func addNote() {
        var s = F.mirrored(["a.txt"])
        let spot = PartitionLayout.firstFreeSpot(in: s)
        let id = s.memos.nextNoteID
        #expect(id == NoteID(1))
        let effects = reduce(&s, .addNote(NewNote(id: id, text: "우유\r\n사기\u{7}", colour: .pink), session: nil), env)
        #expect(effects == [.play(.notePop, .note(id)), .wakeLoop])
        let note = s.memos.notes[id]!
        #expect(note.text == "우유\n사기" && note.colour == .pink && note.pos == spot && note.z == 0 && note.day == nil)
        #expect(note.created == F.t0 && note.edited == F.t0 && s.memos.nextNote == 2 && s.memos.nextNoteID == NoteID(2))
        let second = add(&s, "b", day: day)
        #expect(s.memos.notes[second]?.z == 1 && s.memos.notes[second]?.day == day)
        // A note dropped somewhere needs no pop; it snaps where it was dropped, else takes the first free spot.
        let drop = ArtPoint(240, 130)
        let expected = PartitionLayout.snap(drop, in: s) ?? PartitionLayout.firstFreeSpot(in: s)
        let at = reduce(&s, .addNote(NewNote(id: NoteID(3), text: "", colour: .lime, at: drop), session: nil), env)
        #expect(at == [.wakeLoop] && s.memos.notes.count == 3 && s.memos.notes[NoteID(3)]?.pos == expected)
    }

    @Test("Ids are never reused; a taken or stale id is refused")
    func idsNeverReused() {
        var s = F.mirrored(["a.txt"])
        let one = add(&s), two = add(&s)
        #expect(reduce(&s, .addNote(NewNote(id: one, text: "again", colour: .sky), session: nil), env).isEmpty)
        _ = reduce(&s, .removeNote(two), env)
        #expect(s.memos.nextNoteID == NoteID(3))
        #expect(reduce(&s, .addNote(NewNote(id: two, text: "", colour: .sky), session: nil), env).isEmpty)
        #expect(s.memos.notes[two] == nil && add(&s) == NoteID(3))
        // A later id is fine (the window may count past a note made meanwhile).
        _ = reduce(&s, .addNote(NewNote(id: NoteID(9), text: "", colour: .sky), session: nil), env)
        #expect(s.memos.notes[NoteID(9)] != nil && s.memos.nextNoteID == NoteID(10))
    }

    @Test("Caps: 24 notes, 1000 graphemes a note and a page, a 24-grapheme D-Day title; NFC")
    func caps() {
        var s = F.mirrored(["a.txt"])
        for _ in 0..<MemoBook.maxNotes { add(&s) }
        let full = s
        #expect(reduce(&s, .addNote(NewNote(id: s.memos.nextNoteID, text: "", colour: .cream), session: nil), env)
            == [.toast(.partitionFull)])
        #expect(s == full)
        let long = String(repeating: "가", count: 1200)
        _ = reduce(&s, .editNote(NoteID(1), text: long, session: 0), env)
        #expect(s.memos.notes[NoteID(1)]?.text.count == MemoBook.maxText)
        _ = reduce(&s, .editDayPage(day, text: long, session: 0), env)
        #expect(s.memos.pages[day]?.count == MemoBook.maxText)
        _ = reduce(&s, .setDDay(DDay(day: day, title: String(repeating: "x", count: 40))), env)
        #expect(s.memos.dDay?.title.count == MemoBook.maxTitle)
        // Decomposed Hangul comes in composed.
        _ = reduce(&s, .editNote(NoteID(2), text: "메모".decomposedStringWithCanonicalMapping, session: 0), env)
        #expect(s.memos.notes[NoteID(2)]?.text == "메모" && s.memos.notes[NoteID(2)]?.text.unicodeScalars.count == 2)
        // A torn page needs room too.
        #expect(reduce(&s, .tearOffPage(day, at: nil), env) == [.toast(.partitionFull)] && s.memos.pages[day] != nil)
    }

    @Test("Edit, colour, date, front, remove: each changes only when it changes something")
    func noteEdits() {
        var s = F.mirrored(["a.txt"])
        let a = add(&s, "a"), b = add(&s, "b")
        let later = ReduceEnv(now: F.t0 + 60)
        #expect(reduce(&s, .editNote(a, text: "a2", session: 1), later) == [.wakeLoop])
        #expect(s.memos.notes[a]?.text == "a2" && s.memos.notes[a]?.edited == F.t0 + 60 && s.memos.notes[a]?.created == F.t0)
        #expect(reduce(&s, .editNote(a, text: "a2", session: 1), later).isEmpty)
        #expect(reduce(&s, .noteColour(a, .orange), env) == [.wakeLoop] && s.memos.notes[a]?.colour == .orange)
        #expect(reduce(&s, .noteColour(a, .orange), env).isEmpty)
        #expect(reduce(&s, .noteDay(a, day), env) == [.wakeLoop] && s.memos.notes[a]?.day == day)
        #expect(reduce(&s, .noteDay(a, nil), env) == [.wakeLoop] && s.memos.notes[a]?.day == nil)
        #expect(reduce(&s, .raiseNote(b), env).isEmpty, "already in front")
        #expect(reduce(&s, .raiseNote(a), env) == [.wakeLoop] && s.memos.backToFront.map(\.id) == [b, a])
        #expect(reduce(&s, .removeNote(a), env) == [.wakeLoop] && s.memos.notes[a] == nil)
        for gone in [DeskAction.removeNote(a), .editNote(a, text: "x", session: 1), .noteColour(a, .sky), .raiseNote(a),
                     .moveNote(a, to: ArtPoint(401, 88)), .noteDay(a, day)] {
            #expect(reduce(&s, gone, env).isEmpty, "\(gone)")
        }
    }

    @Test("Move Note: a drop nowhere valid changes nothing (the scene springs back); a valid one snaps, in front")
    func moveNote() {
        var s = F.mirrored(["a.txt"])
        let a = add(&s), b = add(&s)
        let before = s
        // Off the partition altogether.
        for p in [ArtPoint(200, 300), ArtPoint(-100, -100), ArtPoint(600, 40)] {
            #expect(PartitionLayout.snap(p, in: s) == nil, "\(p)")
            #expect(reduce(&s, .moveNote(a, to: p), env).isEmpty, "\(p)")
        }
        #expect(s == before)
        if let spot = PartitionLayout.snap(ArtPoint(403, 90), in: s) {
            #expect(reduce(&s, .moveNote(a, to: ArtPoint(403, 90)), env) == [.wakeLoop])
            #expect(s.memos.notes[a]?.pos == spot && s.memos.backToFront.last?.id == a && s.memos.notes[b]?.z == 1)
        }
    }

    @Test("Where notes rest: new ones take the default spots in order; a drop snaps to the nearest valid spot")
    func whereNotesRest() {
        var s = F.mirrored(["a.txt"])
        let ids = (0..<3).map { _ in add(&s) }
        #expect(ids.map { s.memos.notes[$0]!.pos } == [ArtPoint(371, 67), ArtPoint(401, 67), ArtPoint(371, 88)])
        // A drop just off a valid spot snaps to it; one behind the monitor springs back.
        #expect(reduce(&s, .moveNote(ids[1], to: ArtPoint(435, 141)), env) == [.wakeLoop])
        #expect(s.memos.notes[ids[1]]?.pos == PartitionLayout.snap(ArtPoint(435, 141), in: s))
        #expect(PartitionLayout.isValidRest(s.memos.notes[ids[1]]!.pos, in: s))
        #expect(reduce(&s, .moveNote(ids[0], to: ArtPoint(250, 120)), env).isEmpty)
        #expect(s.memos.notes[ids[0]]?.pos == ArtPoint(371, 67))
        // A torn page dropped on the right wing rests there.
        _ = reduce(&s, .editDayPage(day, text: "p", session: 0), env)
        _ = reduce(&s, .tearOffPage(day, at: ArtPoint(404, 140)), env)
        #expect(s.memos.notes[NoteID(4)]?.pos == ArtPoint(404, 140))
    }

    // MARK: Day pages and the D-Day

    @Test("Day pages: clean text, an empty page goes; no save effect")
    func dayPages() {
        var s = F.mirrored(["a.txt"])
        #expect(reduce(&s, .editDayPage(day, text: "회의 3시\r자료", session: 0), env) == [.wakeLoop])
        #expect(s.memos.pages[day] == "회의 3시\n자료")
        #expect(reduce(&s, .editDayPage(day, text: "회의 3시\n자료", session: 0), env).isEmpty)
        #expect(reduce(&s, .editDayPage(day, text: "", session: 0), env) == [.wakeLoop] && s.memos.pages.isEmpty)
        #expect(reduce(&s, .editDayPage(day, text: "\u{1}", session: 0), env).isEmpty, "nothing but a control character")
    }

    @Test("Tear Off: the page's text moves into a cream note dated that day, and the page goes")
    func tearOff() {
        var s = F.mirrored(["a.txt"])
        add(&s, "first")
        _ = reduce(&s, .editDayPage(day, text: "회의 3시\n자료 준비", session: 0), env)
        let id = s.memos.nextNoteID
        #expect(reduce(&s, .tearOffPage(day, at: nil), env) == [.play(.notePop, .note(id)), .wakeLoop])
        let note = s.memos.notes[id]!
        #expect(note.text == "회의 3시\n자료 준비" && note.colour == .cream && note.day == day && note.z == 1)
        #expect(s.memos.pages[day] == nil && s.memos.nextNoteID == NoteID(id.number + 1))
        #expect(reduce(&s, .tearOffPage(day, at: nil), env).isEmpty, "the page is blank now")
        // Not while the partition is away.
        _ = reduce(&s, .editDayPage(day, text: "again", session: 0), env)
        _ = reduce(&s, .putAway(.partition), env)
        #expect(reduce(&s, .tearOffPage(day, at: nil), env).isEmpty && s.memos.pages[day] == "again")
    }

    @Test("D-Day: set with a clean title, changed, cleared")
    func dDay() {
        var s = F.mirrored(["a.txt"])
        let exam = DDay(day: DayKey("2026-10-30")!, title: " 중간\r\n고사")
        #expect(reduce(&s, .setDDay(exam), env) == [.wakeLoop])
        #expect(s.memos.dDay == DDay(day: exam.day, title: " 중간\n고사"))
        #expect(reduce(&s, .setDDay(DDay(day: exam.day, title: " 중간\n고사")), env).isEmpty)
        #expect(reduce(&s, .setDDay(nil), env) == [.wakeLoop] && s.memos.dDay == nil)
        #expect(reduce(&s, .setDDay(nil), env).isEmpty)
    }

    @Test("Memo actions never save the layout or touch files")
    func noPersist() {
        let a = NoteID(1)
        let actions: [DeskAction] = [
            .addNote(NewNote(id: a, text: "x", colour: .yellow), session: 3), .editNote(a, text: "y", session: 3),
            .noteColour(a, .sky), .noteDay(a, day), .moveNote(a, to: ArtPoint(401, 88)), .raiseNote(a),
            .editDayPage(day, text: "p", session: 3), .tearOffPage(day, at: nil),
            .setDDay(DDay(day: day, title: "t")), .setDDay(nil), .removeNote(a),
        ]
        var s = F.mirrored(["a.txt"])
        for action in actions {
            let effects = reduce(&s, action, env)
            #expect(!effects.contains(.persist) && !effects.contains { $0.touchesFiles }, "\(action)")
            #expect(s.violations().isEmpty)
        }
    }

    // MARK: Undo

    @Test("Each memo action is one undo step that comes back on redo, under its label")
    func undoRedo() {
        var s = F.mirrored(["a.txt"])
        var j = UndoJournal()
        let a = NoteID(1), d2 = DayKey("2026-10-30")!
        let steps: [(DeskAction, String)] = [
            (.addNote(NewNote(id: a, text: "x", colour: .yellow), session: nil), "New Sticky Note"),
            (.editNote(a, text: "y", session: 1), "Edit Note"),
            (.noteColour(a, .lime), "Note Colour"),
            (.noteDay(a, d2), "Note Date"),
            (.addNote(NewNote(id: NoteID(2), text: "", colour: .sky), session: nil), "New Sticky Note"),
            (.raiseNote(a), "Bring to Front"),
            (.editDayPage(day, text: "page", session: 2), "Edit Memo"),
            (.tearOffPage(day, at: nil), "Tear Off Page"),
            (.setDDay(DDay(day: d2, title: "Exam")), "Set D-Day"),
            (.setDDay(nil), "Clear D-Day"),
            (.removeNote(a), "Remove Note"),
        ]
        for (action, label) in steps {
            let before = s.memos
            run(&s, &j, action)
            let after = s.memos
            #expect(after != before && j.undoLabel == label, "\(action)")
            run(&s, &j, .undo)
            #expect(s.memos.notes == before.notes && s.memos.pages == before.pages && s.memos.dDay == before.dDay,
                    "undo \(label)")
            run(&s, &j, .redo)
            #expect(s.memos.notes == after.notes && s.memos.pages == after.pages && s.memos.dDay == after.dDay,
                    "redo \(label)")
        }
        // Undoing everything empties the book again, and ids stay used.
        while !j.undoStack.isEmpty { run(&s, &j, .undo) }
        #expect(s.memos.notes.isEmpty && s.memos.pages.isEmpty && s.memos.dDay == nil && s.memos.nextNoteID == NoteID(4))
    }

    @Test("Undo restores per note and per page: a change made meanwhile to another note survives")
    func undoPerNote() {
        var s = F.mirrored(["a.txt"])
        let a = add(&s, "a"), b = add(&s, "b")
        _ = reduce(&s, .editDayPage(day, text: "kept", session: 9), env)
        var j = UndoJournal()
        run(&s, &j, .editNote(a, text: "a2", session: 1))
        run(&s, &j, .noteColour(a, .sky))
        // Unjournaled changes to another note, the page and the D-Day (as a memo load would make).
        _ = reduce(&s, .editNote(b, text: "b2", session: 5), env)
        _ = reduce(&s, .editDayPage(day, text: "kept too", session: 9), env)
        _ = reduce(&s, .setDDay(DDay(day: day, title: "t")), env)
        while !j.undoStack.isEmpty { run(&s, &j, .undo) }
        #expect(s.memos.notes[a]?.text == "a" && s.memos.notes[a]?.colour == .yellow)
        #expect(s.memos.notes[b]?.text == "b2" && s.memos.pages[day] == "kept too" && s.memos.dDay?.title == "t")
    }

    @Test("Undo of a removal never overfills the partition")
    func undoRemovalWhenFull() {
        var s = F.mirrored(["a.txt"])
        var j = UndoJournal()
        let a = add(&s)
        run(&s, &j, .removeNote(a))
        for _ in 0..<MemoBook.maxNotes { add(&s) }
        run(&s, &j, .undo)
        #expect(s.memos.notes.count == MemoBook.maxNotes && s.memos.notes[a] == nil)
    }
}

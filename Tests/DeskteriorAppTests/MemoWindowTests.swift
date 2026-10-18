import AppKit
import DeskCore
import DeskFiles
import DeskScene
import Foundation
import Metal
import Testing
@testable import DeskteriorApp

/// The Memos window's model without a window: the month grid, the D-Day line, the labels, the editor's cap.
@Suite("Memos window model")
struct MemoWindowModelTests {
    @Test("The month grid starts on Sunday: October 2026 begins on a Thursday and has 31 days")
    func monthGrid() {
        let model = MemoWindowModel(state: DeskState(), today: DayKey("2026-10-18")!)
        let cells = model.cells
        #expect(cells.count == 42)
        #expect(cells.prefix(4).allSatisfy { $0 == nil } && cells[4] == DayKey("2026-10-01"))
        #expect(cells[34] == DayKey("2026-10-31") && cells[35...].allSatisfy { $0 == nil })
        #expect(model.month == DayKey("2026-10-01") && model.day == DayKey("2026-10-18"))
        model.showMonth(3)
        #expect(model.month == DayKey("2027-01-01"), "across the year")
        model.showMonth(-13)
        #expect(model.month == DayKey("2025-12-01"))
        #expect(model.day == DayKey("2026-10-18"), "flipping months does not change the day being edited")
        model.goToday()
        #expect(model.month == DayKey("2026-10-01"))
    }

    @Test("The D-Day line counts from today: D-12 before it, D-DAY on it, D+3 after; the title first")
    func dDayLine() {
        var s = DeskState()
        s.memos.dDay = DDay(day: DayKey("2026-10-30")!, title: "중간고사")
        let model = MemoWindowModel(state: s, today: DayKey("2026-10-18")!)
        // The date as this Mac writes it in English ("Oct 30" in the US).
        let date = model.shortDate(DayKey("2026-10-30")!)
        #expect(date.contains("30") && !date.contains("2026"))
        #expect(model.dDayLine == "중간고사 · \(date) · D-12")
        model.today = DayKey("2026-10-30")!
        #expect(model.dDayLine == "중간고사 · \(date) · D-DAY")
        model.today = DayKey("2026-11-02")!
        #expect(model.dDayLine == "중간고사 · \(date) · D+3")
        model.state.memos.dDay = nil
        #expect(model.dDayLine == nil)
    }

    @Test("A day's cell reads its date, memo, notes and the D-Day; a note's title is its first written line")
    func labels() {
        var s = DeskState()
        let day = DayKey("2026-10-30")!, t = Date(timeIntervalSince1970: 0)
        s.memos.pages[day] = "자료 준비"
        for n in 1...2 {
            s.memos.notes[NoteID(n)] = StickyNote(id: NoteID(n), text: "\n  \n 택배 반품 \nmore", colour: .pink,
                                                  pos: ArtPoint(371, 67), z: n, day: day, created: t, edited: t)
        }
        s.memos.dDay = DDay(day: day, title: "Exam")
        let model = MemoWindowModel(state: s, today: DayKey("2026-10-18")!)
        let marks = s.memos.marks(year: 2026, month: 10)[30] ?? []
        let date = day.date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: L10n.locale,
                                                       calendar: MemoWindowModel.calendar))
        #expect(date.contains("2026") && date.contains("30"))
        #expect(model.cellLabel(day, marks) == "\(date), memo, 2 notes, D-Day: Exam")
        #expect(model.noteTitle(s.memos.notes[NoteID(1)]!) == "택배 반품")
        var empty = s.memos.notes[NoteID(1)]!
        empty.text = " \n"
        #expect(model.noteTitle(empty) == "Empty note")
        #expect(model.notesForDay.isEmpty, "none dated today")
        model.select(day: day)
        #expect(model.notesForDay.map(\.id) == [NoteID(2), NoteID(1)], "front first")
    }

    @Test("The editor holds at most 1000 graphemes (Hangul and emoji count as one each); shortening always fits")
    func cap() {
        let full = String(repeating: "가", count: 999)
        #expect(NoteTextView.fits(full, replacing: NSRange(location: 999, length: 0), with: "👍🏽"))
        #expect(!NoteTextView.fits(full + "a", replacing: NSRange(location: 1000, length: 0), with: "b"))
        #expect(!NoteTextView.fits("", replacing: NSRange(location: 0, length: 0), with: String(repeating: "x", count: 1001)))
        let over = String(repeating: "x", count: 1200)
        #expect(NoteTextView.fits(over, replacing: NSRange(location: 0, length: 10), with: ""), "a deletion goes through")
    }
}

/// The window on a dry-run session (`SessionRig`): what it sends to the store and through `perform`. The note is put
/// straight into the model, so these check the window's commits (`Store.willDispatch` hears them), not the reducer.
@Suite("Memos window", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct MemoWindowTests {
    final class Log {
        var actions: [DeskAction] = []
        /// When each action was sent.
        var times: [Date] = []
        var commands: [MenuCommand] = []

        /// The `editNote` actions sent: (id, text, session).
        var edits: [(NoteID, String, Int)] {
            actions.compactMap { if case let .editNote(id, text, s) = $0 { (id, text, s) } else { nil } }
        }

        /// When the first `editNote` was sent.
        var firstEditTime: Date? {
            zip(actions, times).first { if case .editNote = $0.0 { true } else { false } }?.1
        }
    }

    struct Rig {
        let rig: SessionRig
        let controller: MemoWindowController
        let log: Log
        var store: Store { rig.session.store }
    }

    /// `started`: the session runs (and has loaded its memos) before the note is put in.
    func rig(connected: Bool = false, started: Bool = false, text: String = "우유", forward: Bool = false) async throws
        -> Rig {
        _ = NSApplication.shared
        let rig = try SessionRig(connected: connected)
        let store = rig.session.store
        if started {
            rig.session.start()
            if connected { #expect(await eventually(10) { store.state.access == .connected }) }
        }
        let log = Log()
        let previous = store.willDispatch
        store.willDispatch = { action, state in
            previous?(action, state)
            log.actions.append(action)
            log.times.append(Date())
        }
        store.replace {
            let t = Date(timeIntervalSince1970: 1_792_300_000)
            $0.memos.notes[NoteID(1)] = StickyNote(id: NoteID(1), text: text, colour: .yellow, pos: ArtPoint(371, 67),
                                                   z: 0, created: t, edited: t)
            $0.memos.nextNote = 2
        }
        let session = rig.session
        let controller = MemoWindowController(store: store, today: { DayKey("2026-10-18")! }, perform: { command in
            log.commands.append(command)
            // What AppDelegate.perform does with it: a menu pick's gesture.
            if forward { session.perform(command, from: .menuItem) }
        })
        controller.presents = false  // laid out, never on screen
        return Rig(rig: rig, controller: controller, log: log)
    }

    /// The note editor's text view, once SwiftUI has made it, with the keyboard (typing goes to the first responder;
    /// AppKit ends the editing of a text view that is not, which is a blur).
    func noteTextView(_ r: Rig) async throws -> NSTextView {
        #expect(await eventually(10) {
            r.controller.window?.contentView?.layoutSubtreeIfNeeded()
            return r.controller.model.noteEditor.textView?.window != nil
        })
        let tv = try #require(r.controller.model.noteEditor.textView)
        #expect(tv.window?.makeFirstResponder(tv) == true)
        return tv
    }

    func type(_ text: String, into tv: NSTextView) {
        for c in text { tv.insertText(String(c), replacementRange: tv.selectedRange()) }
    }

    @Test("A burst of typing sends exactly one editNote, 0.8 s after the last keystroke, in the editor's session")
    func burst() async throws {
        let r = try await rig()
        defer { r.controller.close() }
        r.controller.show(.note(NoteID(1)), near: nil, session: 7)
        let tv = try await noteTextView(r)
        #expect(tv.string == "우유")
        type(" 사기", into: tv)
        let typed = Date()
        #expect(await eventually(10) { !r.log.edits.isEmpty })
        // Measured, not slept: the tests share the main queue, so a busy run only makes the commit later.
        let delay = try #require(r.log.firstEditTime).timeIntervalSince(typed)
        #expect(delay >= 0.75, "no commit until 0.8 s after the last keystroke (\(delay) s)")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(r.log.edits.count == 1)
        #expect(r.log.edits.first?.0 == NoteID(1) && r.log.edits.first?.1 == "우유 사기")
        #expect(r.log.edits.first?.2 == 7, "show(_:near:session:) continues the session it was given")
    }

    @Test("No commit while an input method's composition is open; one after unmarkText")
    func markedText() async throws {
        let r = try await rig()
        defer { r.controller.close() }
        r.controller.show(.note(NoteID(1)), near: nil, session: nil)
        let tv = try await noteTextView(r)
        type(" ", into: tv)
        let wherever = NSRange(location: NSNotFound, length: 0)
        tv.setMarkedText("ㅅ", selectedRange: NSRange(location: 1, length: 0), replacementRange: wherever)
        tv.setMarkedText("사", selectedRange: NSRange(location: 1, length: 0), replacementRange: wherever)
        #expect(tv.hasMarkedText())
        try await Task.sleep(for: .milliseconds(2000))
        #expect(r.log.edits.isEmpty, "never mid-composition")
        tv.unmarkText()
        #expect(await eventually(10) { r.log.edits.count == 1 })
        try await Task.sleep(for: .milliseconds(1500))
        #expect(r.log.edits.count == 1)
        #expect(tv.string == "우유 사" && r.log.edits.first?.1 == "우유 사")
    }

    @Test("Closing the window commits at once, ending a composition first; so does a tab switch")
    func closeFlushes() async throws {
        let r = try await rig()
        r.controller.show(.note(NoteID(1)), near: nil, session: nil)
        let tv = try await noteTextView(r)
        type("!", into: tv)
        r.controller.model.switchTab(.calendar)
        #expect(r.log.edits.map(\.1) == ["우유!"], "a tab switch flushes")
        r.controller.model.open(.note(NoteID(1)))
        let again = try await noteTextView(r)
        type("?", into: again)
        again.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        r.controller.window?.close()
        #expect(r.log.edits.count == 2, "closing commits without waiting")
        #expect(r.log.edits.last?.1.hasSuffix("?ㄱ") == true, "the composition was ended and kept")
        r.controller.close()
    }

    @Test("Model text never replaces typing that is not committed yet")
    func neverOverwritesTyping() async throws {
        let r = try await rig()
        defer { r.controller.close() }
        r.controller.model.noteEditor.delay = 60  // no debounced commit during the test, however busy the run
        r.controller.show(.note(NoteID(1)), near: nil, session: nil)
        let tv = try await noteTextView(r)
        type("~", into: tv)
        r.store.replace { $0.memos.notes[NoteID(1)]?.text = "from the desk" }
        r.controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        r.controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(tv.string == "우유~")
        #expect(r.log.edits.isEmpty)
        r.controller.flush()
        #expect(r.log.edits.map(\.1) == ["우유~"], "what was typed is what is committed")
    }

    @Test("Save as Text File goes out through the injected perform closure, after the editor is committed")
    func saveThroughPerform() async throws {
        let r = try await rig()
        defer { r.controller.close() }
        r.controller.show(.note(NoteID(1)), near: nil, session: nil)
        let tv = try await noteTextView(r)
        type("!", into: tv)
        r.controller.model.saveNote()
        #expect(r.log.edits.map(\.1) == ["우유!"])
        #expect(r.log.commands == [.saveMemoFile(.note(NoteID(1)))])
        r.controller.model.open(.today)
        r.controller.model.saveDay()
        #expect(r.log.commands.last == .saveMemoFile(.day(DayKey("2026-10-18")!)))
        #expect(!r.log.actions.contains { if case .requestSaveMemoFile = $0 { true } else { false } },
                "the window itself sends no file request")
    }

    // Needs Track A's memo reducer and UndoJournal.record(…, coalesce:).
    @Test("New Sticky Note and the words typed into it are one undo entry")
    func newNoteIsOneEntry() async throws {
        let r = try await rig()
        defer { r.controller.close() }
        r.controller.show(.notes, near: nil, session: nil)
        let before = r.store.journal.undoStack.count
        r.controller.model.newNote()
        let id = NoteID(2)
        #expect(r.store.state.memos.notes[id] != nil)
        #expect(r.controller.model.note == id && r.controller.model.tab == .notes)
        let tv = try await noteTextView(r)
        type("새 메모", into: tv)
        #expect(await eventually(10) { r.log.edits.count == 1 })
        #expect(r.store.state.memos.notes[id]?.text == "새 메모")
        #expect(r.store.journal.undoStack.count == before + 1)
        #expect(r.store.undoLabel == "New Sticky Note")
        guard case let .addNote(_, session?)? = r.log.actions.first(where: { if case .addNote = $0 { true } else { false } })
        else { Issue.record("no addNote"); return }
        #expect(r.log.edits.first?.2 == session)
    }

    // The runner's log word is "createTextFile": the write lint keeps FileManager's `createFile` out of EffectRunner.
    @Test("The Save button's command runs as a menu pick: the effect runner records createTextFile and the file appears")
    func saveRecordsCreateFile() async throws {
        let r = try await rig(connected: true, started: true, text: "우유 사기", forward: true)
        defer {
            r.controller.close()
            r.rig.session.stop()
        }
        r.controller.show(.note(NoteID(1)), near: nil, session: nil)
        r.controller.model.saveNote()
        #expect(await eventually(10) { r.rig.session.effects.fileLog.last == "createTextFile" })
        #expect(await eventually(10) { r.rig.names(r.rig.desk).contains("우유 사기.txt") })
    }
}

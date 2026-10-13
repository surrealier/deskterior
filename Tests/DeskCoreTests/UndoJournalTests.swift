import Testing
@testable import DeskCore

@Suite("UndoJournal")
struct UndoJournalTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    func cell(_ page: Int, _ col: Int, _ row: Int) -> Location { .screen(page: page, col: col, row: row) }

    @Test("A move undoes and redoes; labels name the step; redo clears on a new change")
    func moveUndoRedo() {
        var s = F.mirrored(["a", "b", "c"])
        var j = UndoJournal()
        #expect(Reducer.reduce(&s, journal: &j, .move([F.key(1)], to: cell(0, 5, 3)), env) == [.persist, .wakeLoop])
        #expect(j.undoLabel == "Move" && j.redoLabel == nil)
        #expect(Reducer.reduce(&s, journal: &j, .undo, env) == [.persist, .wakeLoop])
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 0, 0))
        #expect(j.undoLabel == nil && j.redoLabel == "Move")
        _ = Reducer.reduce(&s, journal: &j, .redo, env)
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 5, 3))
        _ = Reducer.reduce(&s, journal: &j, .undo, env)
        _ = Reducer.reduce(&s, journal: &j, .move([F.key(2), F.key(3)], to: .container(.cabinetTop, order: 0)), env)
        #expect(j.redoLabel == nil && j.undoLabel == "Move 2 Items")
        #expect(Reducer.reduce(&s, journal: &j, .redo, env).isEmpty)
        #expect(s.violations().isEmpty)
    }

    @Test("A swap undoes back into both cells")
    func swapUndo() {
        var s = F.mirrored(["a", "b"])
        var j = UndoJournal()
        _ = Reducer.reduce(&s, journal: &j, .move([F.key(1)], to: cell(0, 1, 0)), env)
        #expect(s.tokens.location(of: F.key(2)) == cell(0, 0, 0))
        _ = Reducer.reduce(&s, journal: &j, .undo, env)
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 0, 0) && s.tokens.location(of: F.key(2)) == cell(0, 1, 0))
    }

    @Test("Take Everything Out is one undo: containers refill in order and the monitor goes back off")
    func takeEverythingOutUndo() {
        var s = F.mirrored(["a", "b", "c", "d"])
        var j = UndoJournal()
        _ = reduce(&s, .move([F.key(1), F.key(2)], to: .container(.cabinetMiddle, order: 0)), env)
        _ = reduce(&s, .move([F.key(3)], to: .container(.wastebasket, order: 0)), env)
        _ = reduce(&s, .power(false), env)
        s.monitor.av = true
        let before = s
        _ = Reducer.reduce(&s, journal: &j, .takeEverythingOut, env)
        #expect(s.tokens.keys { !$0.isScreen }.isEmpty && s.monitor.power == .on && !s.monitor.av)
        #expect(j.undoLabel == "Take Everything Out")
        _ = Reducer.reduce(&s, journal: &j, .undo, env)
        #expect(s.tokens.members(of: .cabinetMiddle) == [F.key(1), F.key(2)])
        #expect(s.tokens.members(of: .wastebasket) == [F.key(3)])
        #expect(s.monitor.power == .off && s.monitor.av)
        #expect(s.tokens.location(of: F.key(4)) == before.tokens.location(of: F.key(4)))
        #expect(s.violations().isEmpty)
    }

    @Test("Undo keeps what happened since: new files stay, removed files are skipped, a taken cell yields")
    func undoAfterChanges() {
        var s = F.mirrored(["a", "b", "c"])
        var j = UndoJournal()
        _ = Reducer.reduce(&s, journal: &j, .move([F.key(1)], to: cell(0, 8, 4)), env)
        _ = Reducer.reduce(&s, journal: &j, .move([F.key(2)], to: cell(0, 7, 4)), env)
        // A new file takes a's old cell; c is deleted.
        _ = reduce(&s, .snapshot(F.snapshot([F.entry("a", 1), F.entry("b", 2), F.entry("n", 9)]), now: F.t0), env)
        #expect(s.tokens.location(of: F.key(9)) == cell(0, 0, 0))
        _ = Reducer.reduce(&s, journal: &j, .undo, env)
        _ = Reducer.reduce(&s, journal: &j, .undo, env)
        #expect(s.tokens.location(of: F.key(9)) == cell(0, 0, 0), "the new file keeps its cell")
        #expect(s.tokens.location(of: F.key(2)) == cell(0, 1, 0))
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 0, 1), "a's cell was taken: the nearest free one")
        #expect(!s.tokens.contains(F.key(3)))
        #expect(s.violations().isEmpty)
    }

    @Test("Undo follows a token re-keyed by a safe-save")
    func undoFollowsRekey() {
        var s = F.mirrored(["a", "b"])
        var j = UndoJournal()
        _ = Reducer.reduce(&s, journal: &j, .move([F.key(1)], to: .container(.riserLeft, order: 0)), env)
        let meta = s.tokens.meta(of: F.key(1))!
        s.tokens.rekey(F.key(1), to: F.key(50), meta: meta)
        s.memory.alias(F.key(1), to: F.key(50))
        _ = Reducer.reduce(&s, journal: &j, .undo, env)
        #expect(s.tokens.location(of: F.key(50)) == cell(0, 0, 0))
    }

    @Test("Only layout actions are journaled, no-ops are not, and the journal keeps 20 steps")
    func whatIsJournaled() {
        var s = F.mirrored(["a", "b"])
        var j = UndoJournal()
        _ = Reducer.reduce(&s, journal: &j, .power(false), env)
        _ = Reducer.reduce(&s, journal: &j, .setPage(0), env)
        _ = Reducer.reduce(&s, journal: &j, .move([F.key(1)], to: cell(0, 0, 0)), env)
        #expect(j.undoStack.isEmpty)
        for i in 0..<25 { _ = Reducer.reduce(&s, journal: &j, .move([F.key(1)], to: cell(0, 2 + i % 6, 2)), env) }
        #expect(j.undoStack.count == UndoJournal.capacity)
        // Without a journal, undo and redo do nothing.
        let before = s
        #expect(reduce(&s, .undo, env).isEmpty && reduce(&s, .redo, env).isEmpty && s == before)
    }
}

import Foundation
import Testing
@testable import DeskCore

/// Put Away and Bring Back (Erratum 30): objects leave and return in one journaled step each, files never stay
/// inside a put-away place, and what rests where an object returns moves aside.
@Suite("Put Away and Bring Back")
struct TidyReducerTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    @discardableResult
    func run(_ s: inout DeskState, _ j: inout UndoJournal, _ a: DeskAction) -> [Effect] {
        Reducer.reduce(&s, journal: &j, a, env)
    }

    /// The centre of a back-strip footprint (a plane point inside it).
    func inside(_ name: String) -> SIMD2<Float> {
        let f = DeskPlanePhysics.footprints(stowed: [])[name]!
        return SIMD2(f.x + f.width / 2, f.d + 4)
    }

    func meets(_ name: String, _ pos: SIMD2<Float>) -> Bool {
        DeskPlanePhysics.footprints(stowed: [])[name]!.intersects(.centred(at: pos, size: DeskPlanePhysics.pileSize))
    }

    // MARK: Put Away, Bring Back

    @Test("Every object puts away and comes back, one step each; again does nothing")
    func everyObject() {
        for id in StowID.allCases {
            var s = F.mirrored(["a.txt"])
            var j = UndoJournal()
            #expect(run(&s, &j, .putAway(id)) == [.play(.putAway, .stowable(id)), .persist, .wakeLoop], "\(id)")
            #expect(!s.isOut(id) && s.stowed == [id] && j.undoLabel == "Put Away", "\(id)")
            #expect(run(&s, &j, .putAway(id)).isEmpty && j.undoStack.count == 1, "\(id)")
            #expect(run(&s, &j, .bringBack(id)) == [.play(.bringBack, .stowable(id)), .persist, .wakeLoop], "\(id)")
            #expect(s.isOut(id) && s.stowed.isEmpty && j.undoLabel == "Bring Back", "\(id)")
            #expect(run(&s, &j, .bringBack(id)).isEmpty && j.undoStack.count == 2, "\(id)")
            #expect(s.violations().isEmpty, "\(id)")
        }
    }

    @Test("An empty place goes without a parade or a toast; its drawers shut")
    func emptyPlace() {
        var s = F.mirrored(["a.txt"])
        s.drawers[.cabinetTop] = DrawerState(p: 12)
        s.drawers[.riserLeft] = DrawerState(p: 3)
        let before = s.tokens
        #expect(reduce(&s, .putAway(.cabinet), env) == [.play(.putAway, .stowable(.cabinet)), .persist, .wakeLoop])
        #expect(s.drawerOpening(.cabinetTop) == 0 && s.drawerOpening(.riserLeft) == 3, "only its own drawers")
        #expect(s.tokens == before && s.monitor == MonitorState())
    }

    @Test("A place with files takes them to the monitor first, which comes on: one step, one undo, a toast")
    func takesFilesOut() {
        var s = F.mirrored(["a.txt", "b.png", "c.txt"])
        var j = UndoJournal()
        run(&s, &j, .move([F.key(2), F.key(3)], to: .container(.cabinetTop, order: 0)))
        s.drawers[.cabinetTop] = DrawerState(p: 12)
        _ = reduce(&s, .power(false), env)
        s.monitor.av = true
        s.monitor.pendingNew = 2
        let effects = run(&s, &j, .putAway(.cabinet))
        #expect(effects == [
            .play(.crtOn, .monitor), .play(.parade, .tokens([F.key(2), F.key(3)])), .play(.putAway, .stowable(.cabinet)),
            .toast(.tookFilesOut), .persist, .wakeLoop,
        ])
        #expect(s.monitor.power == .on && !s.monitor.av && s.monitor.pendingNew == 0 && s.monitor.page == 0)
        #expect(s.tokens.location(of: F.key(2))?.isScreen == true && s.tokens.location(of: F.key(3))?.isScreen == true)
        #expect(s.drawerOpening(.cabinetTop) == 0 && s.stowed == [.cabinet] && s.violations().isEmpty)
        #expect(j.undoLabel == "Put Away" && j.undoStack.count == 2)

        // Undo: the cabinet comes back before the files go back in; the monitor and the drawer are as they were.
        run(&s, &j, .undo)
        #expect(s.isOut(.cabinet) && s.tokens.members(of: .cabinetTop) == [F.key(2), F.key(3)])
        #expect(s.monitor.power == .off && s.monitor.av && s.drawerOpening(.cabinetTop) == 12)
        #expect(j.undoLabel == "Move 2 Items" && j.redoLabel == "Put Away" && s.violations().isEmpty)
        // Redo: the files go out, then the cabinet goes.
        run(&s, &j, .redo)
        #expect(!s.isOut(.cabinet) && s.tokens.count(in: .cabinetTop) == 0 && s.monitor.power == .on)
        #expect(s.violations().isEmpty)
    }

    @Test("The partition takes its clipped files out with it; its add-ons keep their own flags")
    func partitionAndAddOns() {
        var s = F.mirrored(["a.txt", "b.txt"])
        s.tokens.move(F.key(2), to: .container(.memoClips, order: 0))
        _ = reduce(&s, .putAway(.dailyPad), env)
        let effects = reduce(&s, .putAway(.partition), env)
        #expect(effects.contains(.toast(.tookFilesOut)) && s.tokens.location(of: F.key(2))?.isScreen == true)
        #expect(s.stowed == [.dailyPad, .partition] && !s.isOut(.memoClips) && s.isAway(.memoClips))
        // An add-on cannot go while its partition is away.
        #expect(reduce(&s, .putAway(.clipLight), env).isEmpty)
        _ = reduce(&s, .bringBack(.partition), env)
        #expect(s.isOut(.partition) && s.isOut(.memoClips) && !s.isOut(.dailyPad), "the pad stays put away")
        // Bringing back an add-on brings back its partition.
        _ = reduce(&s, .putAway(.partition), env)
        #expect(reduce(&s, .bringBack(.dailyPad), env) == [.play(.bringBack, .stowable(.dailyPad)), .persist, .wakeLoop])
        #expect(s.stowed.isEmpty)
        _ = reduce(&s, .putAway(.partition), env)
        _ = reduce(&s, .bringBack(.memoClips), env)
        #expect(s.stowed.isEmpty, "an add-on out on its own flag brings back the partition it hangs on")
        #expect(s.violations().isEmpty)
    }

    @Test("Undo puts an object away only once its places are empty")
    func undoKeepsOccupiedOut() {
        var s = F.mirrored(["a.txt", "b.txt"])
        _ = reduce(&s, .putAway(.cabinet), env)
        var j = UndoJournal()
        run(&s, &j, .bringBack(.cabinet))
        // A file goes in without a journal entry (as a returning file would).
        _ = reduce(&s, .move([F.key(1)], to: .container(.cabinetMiddle, order: 0)), env)
        run(&s, &j, .undo)
        #expect(s.isOut(.cabinet) && s.tokens.members(of: .cabinetMiddle) == [F.key(1)])
        #expect(s.violations().isEmpty)
    }

    // MARK: Nothing hides inside

    @Test("A move into a put-away place is refused, a settle too")
    func moveRefused() {
        var s = F.mirrored(["a.txt", "b.txt"])
        _ = reduce(&s, .putAway(.riserDrawers), env)
        _ = reduce(&s, .putAway(.partition), env)
        let before = s
        #expect(reduce(&s, .move([F.key(1)], to: .container(.riserLeft, order: 0)), env) == [.toast(.putAwayPlace)])
        #expect(reduce(&s, .move([F.key(1), F.key(2)], to: .container(.memoClips, order: 0)), env) == [.toast(.putAwayPlace)])
        let report = SettleReport(moves: [.init(key: F.key(1), to: .container(.riserCubby, order: 0))])
        _ = reduce(&s, .settle(report), env)
        #expect(reduce(&s, .openContainer(.riserLeft), env).isEmpty)
        #expect(s == before)
        // Out places still take files.
        #expect(reduce(&s, .move([F.key(1)], to: .container(.cabinetTop, order: 0)), env) == [.persist, .wakeLoop])
    }

    @Test("Move to ▸ and Move Contents to ▸ leave put-away places out")
    func menusOmitAway() {
        var s = F.mirrored(["a.txt", "b.txt"])
        s.tokens.move(F.key(2), to: .container(.penCup, order: 0))
        _ = reduce(&s, .putAway(.cabinet), env)
        _ = reduce(&s, .putAway(.partition), env)
        let ids = MenuSpec.token([F.key(1)], s).ids
        for c in [ContainerID.cabinetTop, .cabinetMiddle, .cabinetFile, .memoClips] {
            #expect(!ids.contains("moveTo.\(c.rawValue)"), "\(c)")
        }
        #expect(ids.contains("moveTo.riserLeft") && ids.contains("moveTo.phone") && ids.contains("moveTo.wastebasket"))
        let contents = MenuSpec.container(.penCup, s).ids
        #expect(!contents.contains("moveTo.cabinetFile") && !contents.contains("moveTo.memoClips"))
        #expect(contents.contains("moveTo.riserRight"))
        _ = reduce(&s, .bringBack(.partition), env)
        #expect(MenuSpec.token([F.key(1)], s).ids.contains("moveTo.memoClips"), "the memo clips while the partition is out")
    }

    @Test("A returning file aimed at a put-away place stays hidden in a shut drawer; a shown one goes to the monitor")
    func returningFiles() {
        var s = F.mirrored(["a.png", "b.txt", "c.txt"])
        _ = reduce(&s, .move([F.key(1)], to: .container(.cabinetTop, order: 0)), env)
        _ = reduce(&s, .move([F.key(2)], to: .container(.memoClips, order: 0)), env)
        _ = reduce(&s, .move([F.key(3)], to: .container(.riserRight, order: 0)), env)
        Reconciler.reconcile(&s, F.snapshot([]), now: F.t0)
        #expect(s.tombstones.count == 3)
        _ = reduce(&s, .putAway(.cabinet), env)
        _ = reduce(&s, .putAway(.partition), env)
        s.drawers[.riserLeft] = DrawerState(p: 10)
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.png", 1), F.entry("b.txt", 2), F.entry("c.txt", 3)]), now: F.t0 + 60)
        #expect(s.tokens.location(of: F.key(1)) == .container(.riserRight, order: 1), "the open left drawer is passed over")
        #expect(s.tokens.location(of: F.key(2))?.isScreen == true, "a file from the memo clips stays in sight")
        #expect(s.tokens.location(of: F.key(3)) == .container(.riserRight, order: 0))
        #expect(s.violations().isEmpty)

        // With every drawer away and the phone face up, a hidden file has nowhere hidden to go: the monitor.
        var t = F.mirrored(["a.png"])
        _ = reduce(&t, .move([F.key(1)], to: .container(.cabinetFile, order: 0)), env)
        Reconciler.reconcile(&t, F.snapshot([]), now: F.t0)
        _ = reduce(&t, .putAway(.cabinet), env)
        _ = reduce(&t, .putAway(.riserDrawers), env)
        Reconciler.reconcile(&t, F.snapshot([F.entry("a.png", 1)]), now: F.t0 + 60)
        #expect(t.tokens.location(of: F.key(1))?.isScreen == true && t.violations().isEmpty)
    }

    @Test("Undo of a move out of a place since put away puts the file in a shut drawer, not inside it")
    func undoIntoAwayPlace() {
        var s = F.mirrored(["a.txt"])
        var j = UndoJournal()
        run(&s, &j, .move([F.key(1)], to: .container(.phone, order: 0)))
        run(&s, &j, .move([F.key(1)], to: .screen(page: 0, col: 4, row: 2)))
        _ = reduce(&s, .putAway(.phoneStand), env)
        run(&s, &j, .undo)
        #expect(s.tokens.location(of: F.key(1)) == .container(.riserLeft, order: 0))
        #expect(!s.isOut(.phoneStand) && s.violations().isEmpty)
    }

    // MARK: Make room

    @Test("Bring Back moves a pile off a returning plant's strip and the pen cup home; undo puts both back")
    func makeRoomPlant() {
        var s = F.mirrored(["a.txt"])
        _ = reduce(&s, .putAway(.plant), env)
        _ = reduce(&s, .dropOnDesk([F.key(1)], pile: "P1", at: inside("plant")), env)
        s.penCup.pos = inside("plant") + SIMD2(0, -2)
        #expect(StowCatalog.blockers(of: .plant, in: s) == 2)
        var j = UndoJournal()
        let effects = run(&s, &j, .bringBack(.plant))
        #expect(effects == [.play(.bringBack, .stowable(.plant)), .toast(.madeRoom), .persist, .wakeLoop])
        let pos = s.piles[PileID("P1")]!
        #expect(!meets("plant", pos) && PileWatchdog().isValidSpot(pos, others: []))
        #expect(s.penCup.pos == PenCupState().pos && StowCatalog.blockers(of: .plant, in: s) == 0)
        #expect(s.tokens.location(of: F.key(1)) == .desk(pile: "P1", order: 0) && j.undoLabel == "Bring Back")
        run(&s, &j, .undo)
        #expect(!s.isOut(.plant) && s.piles[PileID("P1")] == inside("plant"))
    }

    @Test("Bring Back moves a pile off a returning phone stand's strip")
    func makeRoomPhone() {
        var s = F.mirrored(["a.txt"])
        _ = reduce(&s, .putAway(.phoneStand), env)
        _ = reduce(&s, .dropOnDesk([F.key(1)], pile: "P1", at: inside("phone")), env)
        #expect(reduce(&s, .bringBack(.phoneStand), env).contains(.toast(.madeRoom)))
        #expect(!meets("phone", s.piles[PileID("P1")]!) && StowCatalog.blockers(of: .phoneStand, in: s) == 0)
    }

    @Test("Bring Back moves floor tokens out of a returning cabinet's span; the chair stays")
    func makeRoomCabinet() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt"])
        _ = reduce(&s, .putAway(.cabinet), env)
        _ = reduce(&s, .dropOnFloor([F.key(1), F.key(2)], x: CoreLayout.cabinet.midX), env)
        _ = reduce(&s, .dropOnFloor([F.key(3)], x: CoreLayout.cabinet.minX + 4), env)
        _ = reduce(&s, .chair(Float(CoreLayout.cabinet.minX), 0), env)
        let chair = s.chair
        #expect(StowCatalog.blockers(of: .cabinet, in: s) == 3)
        #expect(reduce(&s, .bringBack(.cabinet), env).contains(.toast(.madeRoom)))
        #expect(StowCatalog.blockers(of: .cabinet, in: s) == 0 && s.chair == chair)
        let xs = [F.key(1), F.key(2), F.key(3)].compactMap { k -> Int? in
            if case let .floor(x)? = s.tokens.location(of: k) { x } else { nil }
        }
        #expect(xs.count == 3 && Set(xs).count == 3, "each stands on a spot of its own: \(xs)")
        #expect(xs.allSatisfy { FloorLine.isFree($0, avoiding: FloorLine.furniture) })
        #expect(s.violations().isEmpty)
    }

    @Test("Nothing in the way: no toast")
    func makeRoomNothing() {
        var s = F.mirrored(["a.txt"])
        _ = reduce(&s, .dropOnDesk([F.key(1)], pile: "P1", at: [200, 40]), env)
        for id in StowID.allCases { _ = reduce(&s, .putAway(id), env) }
        #expect(!reduce(&s, .bringBackAll, env).contains(.toast(.madeRoom)))
        #expect(s.piles[PileID("P1")] == [200, 40])
    }

    @Test("Bring Back snaps a note a returning fixture would cover", .enabled(if: partitionLayoutReady))
    func makeRoomNotes() {
        var s = F.mirrored(["a.txt"])
        _ = reduce(&s, .putAway(.dDayCard), env)
        _ = reduce(&s, .setDDay(DDay(day: DayKey("2026-10-30")!, title: "Exam")), env)
        // The spot where the D-Day card hangs is free while the card is away.
        let spot = PartitionLayout.defaultSpots.last!
        #expect(PartitionLayout.isValidRest(spot, in: s))
        _ = reduce(&s, .addNote(NewNote(id: NoteID(1), text: "x", colour: .yellow, at: spot), session: nil), env)
        #expect(s.memos.notes[NoteID(1)]?.pos == spot)
        var j = UndoJournal()
        #expect(run(&s, &j, .bringBack(.dDayCard)).contains(.toast(.madeRoom)))
        let moved = s.memos.notes[NoteID(1)]!.pos
        #expect(moved != spot && PartitionLayout.isValidRest(moved, in: s))
        run(&s, &j, .undo)
        #expect(!s.isOut(.dDayCard) && s.memos.notes[NoteID(1)]?.pos == spot)
    }

    @Test("Bring Everything Back is one entry with one toast")
    func bringBackAll() {
        var s = F.mirrored(["a.txt", "b.txt"])
        for id in [StowID.plant, .phoneStand, .cabinet, .wallArt, .partition] { _ = reduce(&s, .putAway(id), env) }
        _ = reduce(&s, .dropOnDesk([F.key(1)], pile: "P1", at: inside("plant")), env)
        _ = reduce(&s, .dropOnFloor([F.key(2)], x: CoreLayout.cabinet.midX), env)
        let before = s
        var j = UndoJournal()
        let effects = run(&s, &j, .bringBackAll)
        #expect(effects.filter { if case .toast = $0 { true } else { false } } == [.toast(.madeRoom)])
        #expect(effects.filter { if case .play(.bringBack, _) = $0 { true } else { false } }.count == 5)
        #expect(s.stowed.isEmpty && j.undoStack.count == 1 && j.undoLabel == "Bring Everything Back")
        #expect(run(&s, &j, .bringBackAll).isEmpty, "nothing left to bring back")
        run(&s, &j, .undo)
        #expect(s.stowed == before.stowed && s.piles == before.piles && s.tokens == before.tokens)
    }

    // MARK: Invariants and the rest of the model

    @Test("No put-away place ever holds a token, through random tidying, moves, undo and redo")
    func invariantProperty() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot((0..<30).map { F.entry("t\($0)", UInt64($0 + 1)) }), now: F.t0)
        var j = UndoJournal()
        var rng = SplitMix64(seed: 7)
        for step in 0..<1500 {
            let id = StowID.allCases[rng.nextInt(below: StowID.allCases.count)]
            let c = ContainerID.allCases[rng.nextInt(below: ContainerID.allCases.count)]
            let keys = (0..<(1 + rng.nextInt(below: 3))).map { _ in F.key(UInt64(1 + rng.nextInt(below: 30))) }
            let action: DeskAction = switch rng.nextInt(below: 12) {
            case 0, 1: .putAway(id)
            case 2: .bringBack(id)
            case 3: .bringBackAll
            case 4: .undo
            case 5: .redo
            case 6: .takeAllOut(c)
            case 7: .dropOnFloor(keys, x: rng.nextInt(below: 500))
            default: .move(keys, to: .container(c, order: rng.nextInt(below: 4)))
            }
            run(&s, &j, action)
            let problems = s.violations()
            #expect(problems.isEmpty, "step \(step) \(action): \(problems)")
            if !problems.isEmpty { break }
        }
        #expect(s.tokens.count == 30)
    }

    @Test("Adopting a layout brings back what holds its files, keeping the rest of the element state")
    func adoptLayout() {
        var here = F.mirrored(["a.txt"])
        for id in [StowID.cabinet, .partition, .plant] { _ = reduce(&here, .putAway(id), env) }
        here.clipLightOn = true
        here.memos.dDay = DDay(day: DayKey("2026-10-30")!, title: "Exam")
        var other = F.mirrored(["x.txt", "y.txt"])
        other.tokens.move(F.key(1), to: .container(.cabinetFile, order: 0))
        here.adoptLayout(of: other)
        #expect(here.isOut(.cabinet) && here.stowed == [.partition, .plant] && here.violations().isEmpty)
        #expect(here.drawerOpening(.cabinetFile) == 0, "nothing becomes visible")
        #expect(here.clipLightOn && here.memos.dDay?.title == "Exam")
        other.tokens.move(F.key(2), to: .container(.memoClips, order: 0))
        here.adoptLayout(of: other)
        #expect(here.stowed == [.plant] && here.violations().isEmpty)
    }

    @Test("Take Everything Out includes the memo clips")
    func takeEverythingOutClips() {
        var s = F.mirrored(["a.txt", "b.txt"])
        _ = reduce(&s, .move([F.key(2)], to: .container(.memoClips, order: 0)), env)
        _ = reduce(&s, .takeEverythingOut, env)
        #expect(s.tokens.location(of: F.key(2))?.isScreen == true)
    }

    @Test("The clip light switches only while it is out, and is not journaled")
    func clipLight() {
        var s = F.mirrored(["a.txt"])
        var j = UndoJournal()
        #expect(run(&s, &j, .clipLight(true)) == [.persist, .wakeLoop] && s.clipLightOn)
        #expect(run(&s, &j, .clipLight(true)).isEmpty && j.undoStack.isEmpty)
        run(&s, &j, .putAway(.clipLight))
        #expect(s.clipLightOn, "an away clip light keeps how it was set")
        #expect(run(&s, &j, .clipLight(false)).isEmpty && s.clipLightOn)
        run(&s, &j, .bringBack(.clipLight))
        run(&s, &j, .putAway(.partition))
        #expect(run(&s, &j, .clipLight(false)).isEmpty)
        run(&s, &j, .bringBack(.partition))
        #expect(run(&s, &j, .clipLight(false)) == [.persist, .wakeLoop] && !s.clipLightOn)
    }
}

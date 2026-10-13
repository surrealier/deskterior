import Foundation
import Testing
@testable import DeskCore

@Suite("Containers (M6): reducer, menus and the pure helpers the scene elements use")
struct ContainerReducerTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    /// A desk with `n` tokens, the first `inside` of them in `id`.
    static func desk(_ n: Int, inside: Int = 0, _ id: ContainerID = .riserLeft) -> DeskState {
        var s = F.mirrored((1...n).map { "f\($0).txt" })
        for i in 0..<inside { s.tokens.move(F.key(UInt64(i + 1)), to: .container(id, order: i)) }
        return s
    }

    @Test("Open: a drawer slides all the way out; Close: back to its rest, ajar at the jam gap when overfull")
    func openClose() {
        var s = Self.desk(12, inside: 10)
        #expect(reduce(&s, .openContainer(.riserLeft), env) == [.persist, .wakeLoop])
        #expect(s.drawerOpening(.riserLeft) == 10)
        #expect(Visibility.of(s.tokens.location(of: F.key(1))!, s).appearance == .mini)
        #expect(reduce(&s, .openContainer(.riserLeft), env).isEmpty, "already open")
        #expect(reduce(&s, .closeContainer(.riserLeft), env) == [.persist, .wakeLoop])
        #expect(s.drawerOpening(.riserLeft) == 2, "ten in a drawer for eight rest 2 px out")
        #expect(Visibility.of(s.tokens.location(of: F.key(1))!, s).isHidden)
        #expect(reduce(&s, .closeContainer(.riserLeft), env).isEmpty)
        // Neither touches files nor joins the undo journal.
        var journal = UndoJournal()
        _ = Reducer.reduce(&s, journal: &journal, .openContainer(.riserRight), env)
        #expect(journal.undoLabel == nil && s.drawerOpening(.riserRight) == 10)
        #expect(reduce(&s, .openContainer(.riserCubby), env).isEmpty && reduce(&s, .closeContainer(.penCup), env).isEmpty)
    }

    @Test("Cabinet drawers are interlocked, and opening one rolls a blocking chair clear (model side)")
    func cabinetOpen() {
        var s = Self.desk(4)
        s.drawers[.cabinetMiddle] = DrawerState(p: 14)
        s.chair.x = 380
        #expect(DrawerSim.cabinetOpenLimit(travel: 12, chairX: s.chair.x) == 3, "the chair blocks the fronts")
        _ = reduce(&s, .openContainer(.cabinetTop), env)
        #expect(s.drawerOpening(.cabinetTop) == 12 && s.drawerOpening(.cabinetMiddle) == 0)
        #expect(s.chair.x == Reducer.chairClearX && DrawerSim.cabinetOpenLimit(travel: 12, chairX: s.chair.x) == 12)
        #expect(Reducer.chairClearX < RollerSim.cabinetBlockX())
        // A chair out of the way stays put; an overfull drawer shut by the interlock stays ajar.
        s.chair.x = 120
        for i in 1...4 { s.tokens.move(F.key(UInt64(i)), to: .container(.cabinetTop, order: 0)) }
        s.drawers[.cabinetTop] = DrawerState(p: 12)
        var full = s
        for i in 0..<10 { full.tokens.insert(F.key(UInt64(100 + i)), meta: TokenMeta(name: "x\(i)", kind: .text), at: .container(.cabinetTop, order: 0)) }
        _ = reduce(&full, .openContainer(.cabinetFile), env)
        #expect(full.chair.x == 120 && full.drawerOpening(.cabinetFile) == 18)
        #expect(full.drawerOpening(.cabinetTop) == 6, "fourteen in the top drawer: it rests at its 6-px gap")
    }

    @Test("The phone's face is absolute: a repeated commit changes nothing; PhoneMachine commits it")
    func phoneFace() {
        var s = Self.desk(2)
        #expect(reduce(&s, .phoneFace(down: true), env) == [.persist, .wakeLoop] && s.phone.faceDown)
        #expect(reduce(&s, .phoneFace(down: true), env).isEmpty && s.phone.faceDown)
        #expect(reduce(&s, .openContainer(.phone), env) == [.persist, .wakeLoop] && !s.phone.faceDown)
        #expect(reduce(&s, .closeContainer(.phone), env) == [.persist, .wakeLoop] && s.phone.faceDown)
        guard case .phoneFace(down: false)? = PhoneMachine.action(committing: false, model: s.phone) else {
            Issue.record("a face-up commit is .phoneFace(down: false)")
            return
        }
        #expect(PhoneMachine.action(committing: true, model: s.phone) == nil)
    }

    @Test("Show on Desk opens a token's drawer (rolling the chair clear, shutting the cabinet's others), flips the phone up")
    func showOnDesk() {
        var s = Self.desk(6)
        s.tokens.move(F.key(1), to: .container(.cabinetFile, order: 0))
        s.tokens.move(F.key(2), to: .container(.phone, order: 0))
        s.tokens.move(F.key(3), to: .container(.riserCubby, order: 0))
        s.drawers[.cabinetTop] = DrawerState(p: 12)
        s.chair.x = 400
        s.phone.faceDown = true
        let effects = reduce(&s, .showOnDesk(F.key(1)), env)
        #expect(effects.contains(.play(.pulse, .token(F.key(1)))))
        #expect(s.drawerOpening(.cabinetFile) == 18 && s.drawerOpening(.cabinetTop) == 0 && s.chair.x == Reducer.chairClearX)
        #expect(!Visibility.of(s.tokens.location(of: F.key(1))!, s).isHidden)
        _ = reduce(&s, .showOnDesk(F.key(2)), env)
        #expect(!s.phone.faceDown && !Visibility.of(s.tokens.location(of: F.key(2))!, s).isHidden)
        let before = s
        _ = reduce(&s, .showOnDesk(F.key(3)), env)
        #expect(s.drawers == before.drawers && s.chair == before.chair, "the cubby is open already")
    }

    @Test("New actions never touch files and keep the model's invariants")
    func noFiles() {
        let actions: [DeskAction] = ContainerID.allCases.flatMap { [.openContainer($0), .closeContainer($0)] }
            + [.phoneFace(down: true), .phoneFace(down: false)]
        for a in actions {
            var s = Self.desk(5, inside: 3, .cabinetMiddle)
            var journal = UndoJournal()
            var effects = Reducer.reduce(&s, journal: &journal, a, env)
            effects += Reducer.reduce(&s, journal: &journal, .undo, env)
            #expect(!a.isRequest && !effects.contains { $0.touchesFiles }, "\(a)")
            #expect(s.violations().isEmpty, "\(a)")
        }
    }

    @Test("Container menu: Open/Close, List Contents (names fly to the monitor), Move Contents to ▸, Take All Out")
    func menu() {
        var s = Self.desk(25, inside: 22, .cabinetFile)
        let m = MenuSpec.container(.cabinetFile, s)
        #expect(m.ids.prefix(1) == ["open"] && m.item("open")?.command == .openContainer(.cabinetFile))
        if case .openContainer(.cabinetFile)? = m.item("open")?.command?.action(s) {} else { Issue.record("Open is a model action") }
        let list = m.item("listContents")
        guard case let .submenu(rows)? = list?.content else { Issue.record("no list"); return }
        #expect(rows.count == MenuSpec.listLimit + 2 && rows.last?.id == "list.more" && rows.last?.command == .inventory)
        #expect(rows.first?.title == "f1.txt" && rows[1].title == "f2.txt", "by name: f1, f2 … f10 after f9")
        guard case let .moveTo(keys, to)? = rows.first?.command else { Issue.record("a row flies its token"); return }
        #expect(keys == [F.key(1)] && to.isScreen)
        #expect(m.item("moveTo.cabinetFile") == nil && m.item("moveTo.monitor")?.isEnabled == true)
        #expect(m.item("moveTo.penCup")?.isEnabled == false, "22 do not fit a cup of 6")
        #expect(m.item("takeAllOut")?.command == .takeAllOut(.cabinetFile))
        if case .takeAllOut(.cabinetFile)? = m.item("takeAllOut")?.command?.action(s) {} else { Issue.record("Take All Out") }
        s.drawers[.cabinetFile] = DrawerState(p: 18)
        #expect(MenuSpec.container(.cabinetFile, s).item("close")?.command == .closeContainer(.cabinetFile))
        // Empty: nothing to list, move or take out. The phone turns; the cubby only lists.
        let empty = MenuSpec.container(.riserRight, s)
        #expect(empty.item("listContents")?.isEnabled == false && empty.item("takeAllOut")?.isEnabled == false)
        #expect(MenuSpec.container(.phone, s).item("faceDown")?.command == .closeContainer(.phone))
        s.phone.faceDown = true
        #expect(MenuSpec.container(.phone, s).item("faceUp")?.title == "Turn Face Up")
        #expect(MenuSpec.container(.riserCubby, s).item("open") == nil)
    }

    @Test("A scripted chair roll comes to rest within a few px of its target, even across most of the floor")
    func chairRoll() {
        for (from, to) in [(Float(400), Reducer.chairClearX), (200, 334), (90, 420), (330, 70)] {
            var r = RollerSim(x: from)
            r.roll(to: to)
            var steps = 0
            while r.needsFrames, steps < 1200 {
                _ = r.step(1.0 / 60)
                steps += 1
            }
            #expect(abs(r.x - to) <= 3, "\(from) → \(to) rested at \(r.x)")
        }
        var held = RollerSim(x: 200)
        held.beginDrag(pointerX: 210)
        held.roll(to: 300)
        #expect(held.v == 0, "a held chair ignores scripted rolls")
    }

    @Test("ContentJostle.place starts an item elsewhere and it springs home")
    func jostlePlace() {
        var j = ContentJostle(homes: [8, 8], bounds: 3...8)
        j.place(1, at: -20, velocity: 40)
        #expect(j.positions[1] == 3 && !j.isAsleep)
        for _ in 0..<240 { j.step(drawerAcceleration: 0, 1.0 / 60) }
        #expect(j.isAsleep && j.pixelOffsets == [0, 0])
        j.place(5, at: 4)
        #expect(j.isAsleep, "out of range: ignored")
    }

    @Test("Interior marks: a hidden item leaves a gap, a selected one draws on top with its backdrop")
    func marks() {
        let items = InteriorRasterTests.items(6)
        let id = ContainerID.riserLeft
        let all = InteriorRaster.drawerContents(id, items: items, opening: 10)
        let gap = InteriorRaster.drawerContents(id, items: items, opening: 10, marks: .init(hidden: [5]))
        let rects = InteriorRaster.itemRects(id, items: items)
        // Pixels outside item 5's rect are the same; inside they differ.
        var outside = 0, inside = 0
        for y in 0..<all.height {
            for x in 0..<all.width where all.pixel(x, y) != gap.pixel(x, y) {
                if rects[5].contains(ArtPoint(x, y)) { inside += 1 } else { outside += 1 }
            }
        }
        #expect(inside > 0 && outside == 0)
        let order = InteriorRaster.drawOrder(6, open: true, marks: .init(selected: [2])) { _ in 0 }
        #expect(order.last == 2 && order.dropLast() == [0, 1, 3, 4, 5])
        #expect(InteriorRaster.drawOrder(6, open: false, marks: .init(selected: [2])) { _ in 0 } == Array(0..<6))
        #expect(InteriorRaster.drawOrder(3, open: true, marks: .init(raised: [0])) { _ in 0 } == [1, 2, 0])
        let selected = InteriorRaster.drawerContents(id, items: items, opening: 10, marks: .init(selected: [2]))
        let changed = zip(all.pixels, selected.pixels).filter { $0 != $1 }.map(\.1)
        #expect(changed.contains(Role.selection.color), "the backdrop's light ring shows round the picked mini")
        // Shut drawers draw paper, except items sliding in through a chomp.
        let peek = InteriorRaster.drawerContents(id, items: items, opening: 4, revealed: false)
        let entering = InteriorRaster.drawerContents(id, items: items, opening: 4, revealed: false, marks: .init(shown: [0]))
        #expect(peek != entering)
    }

    @Test("Cubby and phone rects match what the art draws")
    func rects() {
        let items = InteriorRasterTests.items(9)
        let cubby = InteriorRaster.cubby(items)
        let rects = InteriorRaster.cubbyRects(count: items.count)
        for y in 0..<cubby.height {
            for x in 0..<cubby.width where cubby.pixel(x, y).a != 0 {
                #expect(rects.contains { $0.contains(ArtPoint(x, y)) }, "(\(x),\(y)) is in no rect")
            }
        }
        let minis = (0..<6).map { _ in PixelBuffer(width: 5, height: 5, fill: Ink.red3.color) }
        let phone = PropArt.phoneStand(face: .up, minis: minis).image
        for i in 0..<6 {
            let r = InteriorRaster.phoneMiniRect(i)
            #expect(phone.pixel(r.x, r.y) == Ink.red3.color && phone.pixel(r.maxX - 1, r.maxY - 1) == Ink.red3.color)
        }
    }
}

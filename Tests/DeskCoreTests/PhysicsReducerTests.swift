import Foundation
import Testing
@testable import DeskCore

@Suite("Reducer: the desk plane (M7)")
struct PhysicsReducerTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    @Test("dropOnDesk makes a pile at the point, joins an existing one in place, and moves a pile taken whole")
    func dropOnDesk() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt"])
        #expect(reduce(&s, .dropOnDesk([F.key(1)], pile: "P1", at: [200, 40]), env) == [.persist, .wakeLoop])
        #expect(s.tokens.location(of: F.key(1)) == .desk(pile: "P1", order: 0) && s.piles["P1"] == [200, 40])
        _ = reduce(&s, .dropOnDesk([F.key(2)], pile: "P1", at: [206, 44]), env)
        #expect(s.tokens.location(of: F.key(2)) == .desk(pile: "P1", order: 1) && s.piles["P1"] == [200, 40],
                "joining keeps the pile where it is")
        // The whole pile, picked up and put down elsewhere under its own id.
        _ = reduce(&s, .dropOnDesk([F.key(2), F.key(1)], pile: "P1", at: [300, 60]), env)
        #expect(s.piles["P1"] == [300, 60] && s.tokens.members(of: "P1") == [F.key(2), F.key(1)])
        // Into another pile: the emptied one is forgotten.
        _ = reduce(&s, .dropOnDesk([F.key(1), F.key(2)], pile: "P2", at: [100, 20]), env)
        #expect(s.piles == ["P2": [100, 20]] && s.violations().isEmpty)
    }

    @Test("dropOnDesk refuses points off the desk or not finite, and gone tokens")
    func dropOnDeskRefusals() {
        var s = F.mirrored(["a.txt"])
        let before = s
        #expect(reduce(&s, .dropOnDesk([F.key(1)], pile: "P1", at: [.nan, 3]), env).isEmpty)
        #expect(reduce(&s, .dropOnDesk([F.key(1)], pile: "P1", at: [600, 40]), env).isEmpty)
        #expect(reduce(&s, .dropOnDesk([F.key(1)], pile: "P1", at: [200, -1]), env).isEmpty)
        #expect(reduce(&s, .dropOnDesk([F.key(9)], pile: "P1", at: [200, 40]), env).isEmpty)
        #expect(s == before)
    }

    @Test("dropOnDesk is one undoable move; undo brings the pile's place back")
    func dropOnDeskUndo() {
        var s = F.mirrored(["a.txt", "b.txt"])
        var journal = UndoJournal()
        _ = Reducer.reduce(&s, journal: &journal, .dropOnDesk([F.key(1), F.key(2)], pile: "P1", at: [200, 40]), env)
        #expect(journal.undoLabel == "Move 2 Items")
        _ = Reducer.reduce(&s, journal: &journal, .dropOnDesk([F.key(1), F.key(2)], pile: "P1", at: [260, 70]), env)
        _ = Reducer.reduce(&s, journal: &journal, .undo, env)
        #expect(s.piles["P1"] == [200, 40])
        _ = Reducer.reduce(&s, journal: &journal, .undo, env)
        #expect(s.tokens.location(of: F.key(1))?.isScreen == true && s.piles.isEmpty)
    }

    @Test("Tip Over / Stand Up play on the cup and the basket only and change nothing yet")
    func tipActions() {
        var s = F.mirrored(["a.txt"])
        let before = s
        #expect(reduce(&s, .tipOver(.penCup), env) == [.play(.tipOver, .container(.penCup)), .wakeLoop])
        #expect(reduce(&s, .standUp(.wastebasket), env) == [.play(.standUp, .container(.wastebasket)), .wakeLoop])
        #expect(reduce(&s, .tipOver(.riserLeft), env).isEmpty)
        #expect(s == before)
        #expect(MenuCommand.tipOver(.penCup).action(s).map { "\($0)" } == "tipOver(DeskCore.ContainerID.penCup)")
    }

    @Test("Floor drops spread 18 px apart from the nearest free spot, around furniture and other floor tokens")
    func floorMoves() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt", "d.txt"])
        _ = reduce(&s, .move([F.key(1)], to: .floor(x: 200)), env)
        #expect(s.tokens.location(of: F.key(1)) == .floor(x: 200))
        _ = reduce(&s, .move([F.key(2), F.key(3)], to: .floor(x: 200)), env)
        #expect(s.tokens.location(of: F.key(2)) == .floor(x: 184) || s.tokens.location(of: F.key(2)) == .floor(x: 216))
        let xs = [F.key(1), F.key(2), F.key(3)].compactMap { k -> Int? in
            if case let .floor(x)? = s.tokens.location(of: k) { x } else { nil }
        }.sorted()
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $1 - $0 >= 16 }, "no two overlap: \(xs)")
        // In front of the basket's spot it steps aside; with the basket lying on its side, that spot stays clear
        // too (it stands back up there).
        _ = reduce(&s, .move([F.key(4)], to: .floor(x: 64)), env)
        #expect(s.tokens.location(of: F.key(4)) == .floor(x: 40))
        #expect(Reducer.floorSpots(near: 64, count: 1, basket: BasketState(state: "tippedRight")) == [40])
        #expect(Reducer.floorSpots(near: 105, count: 1, basket: BasketState(state: "tippedRight")) == [128])
        // At the core's right end (past the desk's leg) the row turns back and steps over the leg and the cabinet.
        #expect(Reducer.floorSpots(near: 500, count: 3) == [502, 384, 366])
    }

    @Test("Fresh pile ids never collide with live piles, tombstones or each other")
    func pileIDs() {
        var s = F.mirrored(["a.txt"])
        s.tokens.move(F.key(1), to: .desk(pile: "P7", order: 0))
        s.piles["P7"] = [100, 10]
        #expect(s.makePileIDs(3) == ["P8", "P9", "P10"])
        #expect(s.makePileIDs(0).isEmpty)
    }

    @Test("Cup and basket menus: Tip Over while standing, Stand Up while down; Empty Wastebasket… with something in it")
    func menus() {
        var s = F.mirrored(["a.txt"])
        #expect(MenuSpec.penCup(s).item("tipOver")?.isEnabled == true && MenuSpec.penCup(s).item("standUp")?.isEnabled == false)
        s.penCup.state = PenCupMachine.lyingRightName
        #expect(MenuSpec.penCup(s).item("tipOver")?.isEnabled == false && MenuSpec.penCup(s).item("standUp")?.isEnabled == true)
        s.tokens.move(F.key(1), to: .container(.wastebasket, order: 0))
        let basket = MenuSpec.wastebasket(s)
        #expect(basket.item("emptyWastebasket")?.isEnabled == true && basket.item("emptyWastebasket")?.command == .emptyWastebasket)
        s.wastebasket.state = WastebasketMachine.tippedLeftName
        #expect(MenuSpec.wastebasket(s).item("standUp")?.isEnabled == true)
    }

    @Test("The watchdog lets a pile hang over an edge while its centre is on the desk")
    func watchdogOverhang() {
        var w = PileWatchdog()
        #expect(w.check("P1", position: [14, 3], isAwake: false, dt: 1.0 / 60) == .ok)
        #expect(!w.inBounds([14, 3]) && w.isOnDesk([14, 3]))
        if case .snap(_, .outOfBounds) = w.check("P1", position: [10, 3], isAwake: false, dt: 1.0 / 60) {} else {
            Issue.record("a centre off the desk snaps back")
        }
    }
}

@Suite("Pile art")
struct PileArtTests {
    @Test("Stacks: up to three icons 2 px up and right, a count tag from two, a short cast shadow, the selection frame")
    func stacks() {
        let icons = [IconKind.pdf, .image, .folder, .zip].map { KindIcons.icon($0).image }
        let one = PileArt.stack([icons[0]], count: 1)
        #expect(one.iconOrigins == [ArtPoint(2, 2)] && one.base == ArtPoint(10, 18))
        #expect(one.image.size == ArtSize(20, 20))
        let four = PileArt.stack(icons, count: 4)
        #expect(four.iconOrigins == [ArtPoint(2, 7), ArtPoint(4, 5), ArtPoint(6, 3)], "three drawn, front first")
        // The shadow shows in the image but takes no clicks.
        let shadowOnly = (0..<four.image.height).flatMap { y in (0..<four.image.width).map { (x: $0, y: y) } }
            .filter { four.image.pixel($0.x, $0.y).a != 0 && four.hitMask.pixel($0.x, $0.y).a == 0 }
        #expect(!shadowOnly.isEmpty && shadowOnly.allSatisfy { four.image.pixel($0.x, $0.y) == Ink.oak3.color })
        let hop = PileArt.stack(icons, count: 4, lift: 2)
        #expect(hop.base == ArtPoint(four.base.x, four.base.y + 2) && hop.iconOrigins[0].y == four.iconOrigins[0].y,
                "the icons rise off the shadow")
        var sheet = PixelCanvas(width: 120, height: 30)
        for (i, s) in [one, PileArt.stack(Array(icons.prefix(2)), count: 2), four, hop,
                       PileArt.stack([icons[1]], count: 1, selected: true)].enumerated() {
            sheet.blit(s.image, at: ArtPoint(i * 24, 30 - s.image.height))
        }
        #expect(Golden.match(sheet.buffer, "pile-stacks"))
    }

    @Test("The squash keeps the 1-px outline on every side and scales with the impact")
    func squashOutline() {
        let icon = KindIcons.icon(.doc).image
        func edges(_ b: PixelBuffer) -> [Set<RGBA8>] {
            let r = b.opaqueBounds()
            let row = { (y: Int) in Set((r.minX..<r.maxX).map { b.pixel($0, y) }.filter { $0.a != 0 }) }
            let col = { (x: Int) in Set((r.minY..<r.maxY).map { b.pixel(x, $0) }.filter { $0.a != 0 }) }
            return [row(r.minY), row(r.maxY - 1), col(r.minX), col(r.maxX - 1)]
        }
        let want = edges(icon), box = icon.opaqueBounds()
        for amount in [1, 2] {
            let frames = PileArt.squash(icon, amount: amount)
            #expect(frames[0].opaqueBounds().size == ArtSize(box.w + amount + 1, box.h - 2 * amount))
            #expect(frames[1].opaqueBounds().size == ArtSize(box.w - amount, box.h + amount))
            for f in frames.prefix(2) { #expect(edges(f) == want, "amount \(amount)") }
        }
        let none = PileArt.squash(icon, amount: 0)
        #expect(none[0] == none[2] && none[1] == none[2])
        // Reshaping never invents a colour: every pixel comes from the image.
        let wide = PileArt.reshaped(icon, to: ArtSize(21, 11))
        #expect(Set(wide.pixels).isSubset(of: Set(icon.pixels)))
    }

    @Test("The landing squash keeps the image's bottom centre and ends at rest")
    func squash() {
        let icon = KindIcons.icon(.doc).image
        let frames = PileArt.squash(icon)
        #expect(frames.count == 3 && frames.allSatisfy { $0.size == ArtSize(20, 18) })
        var rest = PixelBuffer(width: 20, height: 18)
        rest.blit(icon, at: ArtPoint(2, 2))
        #expect(frames[2] == rest)
        #expect(frames[0].opaqueBounds().maxY == 18 && frames[0].opaqueBounds().h < icon.opaqueBounds().h)
    }
}

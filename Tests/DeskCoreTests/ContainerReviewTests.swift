import DeskPixels
import Testing
@testable import DeskCore

/// Regressions from the M6 container review: every mini on show stays reachable, a peek or a chomp never reveals,
/// an emptied drawer shuts, hard sleep ends a chomp shut, Move to ▸ never offers where the tokens already are.
@Suite("Container review")
struct ContainerReviewTests {
    static let dt: Float = 1.0 / 60

    /// `n` items with seeds drawn from `seed` (as token keys would give them).
    static func items(_ n: Int, seed: UInt64) -> [InteriorRaster.Item] {
        var rng = SplitMix64(seed: seed)
        return (0..<n).map { InteriorRaster.Item(kind: InteriorRasterTests.kinds[$0 % 10], seed: rng.next()) }
    }

    /// The items of `count` that `owner` never gives a whole `block` of `area`.
    static func unreachable(
        _ count: Int, in area: ArtRect, block: ArtSize = ArtSize(3, 3), owner: (ArtPoint) -> Int?
    ) -> [Int] {
        // Who owns each pixel, then which items own a whole block somewhere.
        let grid = (area.minY..<area.maxY).map { y in (area.minX..<area.maxX).map { owner(ArtPoint($0, y)) } }
        var reached = Set<Int>()
        for y in 0..<max(0, grid.count - block.h + 1) {
            for x in 0..<max(0, area.w - block.w + 1) {
                guard let i = grid[y][x], !reached.contains(i) else { continue }
                let whole = (0..<block.h).allSatisfy { dy in (0..<block.w).allSatisfy { grid[y + dy][x + $0] == i } }
                if whole { reached.insert(i) }
            }
        }
        return (0..<count).filter { !reached.contains($0) }
    }

    @Test("Up to the hard cap, every mini in an open drawer owns a 3×3 block the pointer can pick (a folder, a strip)")
    func drawerReach() {
        for id in ContainerID.allCases where id.isDrawer {
            let size = InteriorRaster.contentSize(id)
            // Fully open, the content rows below the back edge's shadow row show.
            let visible = ArtRect(0, 1, size.w, size.h - 1)
            for n in 1...id.spec.hardCap {
                for seed in UInt64(1)...24 {
                    let items = Self.items(n, seed: seed &* 0x9E37)
                    let rects = InteriorRaster.itemRects(id, items: items)
                    let order = InteriorRaster.drawOrder(n, open: true, marks: .none) { rects[$0].maxY - 1 }
                    // Folder tabs are wide and short: two rows of one up to the capacity, a row past it.
                    let block = id != .cabinetFile ? ArtSize(3, 3) : ArtSize(8, n <= id.spec.capacity ? 2 : 1)
                    let missing = Self.unreachable(n, in: visible, block: block) { p in
                        order.last { rects[$0].contains(p) }
                    }
                    #expect(missing.isEmpty, "\(id) n=\(n) seed=\(seed): \(missing) have no 3×3 block")
                }
            }
        }
    }

    @Test("Every cubby item keeps a 3×3 block in the slot; three or more stand in two staggered rows")
    func cubbyReach() {
        let slot = ArtRect(origin: .zero, size: CoreLayout.riserCubby.size)
        for n in 1...ContainerSpec.cubby.hardCap {
            let rects = InteriorRaster.cubbyRects(count: n)
            let order = InteriorRaster.drawOrder(n, open: true, marks: .none) { rects[$0].maxY }
            let missing = Self.unreachable(n, in: slot) { p in order.last { rects[$0].contains(p) } }
            #expect(missing.isEmpty, "n=\(n): \(missing) have no 3×3 block")
            #expect(rects.allSatisfy { $0.minY >= 0 && $0.minX >= 0 && $0.maxX <= slot.maxX }, "n=\(n)")
            if n >= 3 {
                #expect(rects.indices.allSatisfy { i in
                    (rects[i].maxY > slot.maxY) == !InteriorRaster.cubbyIsBack(i, count: n)
                }, "the front row sinks behind the lip")
            }
        }
    }

    @Test("Selected and hovered minis draw on top, the hovered one over the selection; hit tests keep the plain order")
    func drawTiers() {
        let order = InteriorRaster.drawOrder(5, open: true, marks: .init(selected: [1], hovered: [3])) { _ in 0 }
        #expect(order == [0, 2, 4, 1, 3])
        #expect(InteriorRaster.drawOrder(5, open: false, marks: .init(hovered: [3])) { _ in 0 } == Array(0..<5))
        // A hovered mini shows whole: its rect holds its own icon's pixels wherever the icon has any.
        let items = Self.items(14, seed: 3)
        let id = ContainerID.riserLeft
        let hovered = InteriorRaster.drawerContents(id, items: items, opening: 10, marks: .init(hovered: [6]))
        let r = InteriorRaster.itemRects(id, items: items)[6]
        let icon = KindIcons.icon(InteriorRaster.iconKind(items[6].kind), size: InteriorRaster.miniSize).image
        for y in max(r.minY, 0)..<r.maxY {
            for x in r.minX..<r.maxX where icon.pixel(x - r.x, y - r.y).a != 0 {
                #expect(hovered.pixel(x, y) == icon.pixel(x - r.x, y - r.y))
            }
        }
        // A selected mini wears a light ring over its own edge, so it shows even where the backdrop is cropped.
        let selected = InteriorRaster.drawerContents(id, items: items, opening: 10, marks: .init(selected: [6]))
        let ring = InteriorRaster.selectionMark.color
        #expect(selected.pixel(r.minX, r.maxY - 2) == ring && selected.pixel(r.maxX - 1, r.maxY - 2) == ring)
        #expect(ring != Role.selection.color)
    }

    @Test("The phone's selection frame stays on the glass")
    func phoneFrame() {
        for i in 0..<ContainerSpec.phone.capacity {
            let r = InteriorRaster.phoneSelectionRect(i)
            #expect(InteriorRaster.phoneGlass.contains(r.origin) && r.maxX <= InteriorRaster.phoneGlass.maxX)
            #expect(r.intersection(InteriorRaster.phoneMiniRect(i)) == InteriorRaster.phoneMiniRect(i))
        }
    }

    @Test("The cabinet's pull follows its wiggle")
    func cabinetPullWiggle() {
        let still = InteriorRaster.cabinet(p: [0, 0, 0], items: [[], [], []]).image
        let wiggled = InteriorRaster.cabinet(p: [0, 0, 0], items: [[], [], []], pullDX: [0, 1, 0]).image
        #expect(still != wiggled)
        let middle = CoreLayout.cabinetFront(1)
            .offsetBy(-CoreLayout.cabinet.x, -CoreLayout.cabinet.y + StorageArt.cabinetTopFace)
        for y in 0..<still.height where !(middle.minY..<middle.maxY).contains(y) {
            for x in 0..<still.width { #expect(still.pixel(x, y) == wiggled.pixel(x, y), "(\(x),\(y))") }
        }
    }

    // MARK: Drawer sim

    @Test("A chomp or a peek on an overfull drawer gapes at most to 7 px and never reveals its contents")
    func concealedGape() {
        for id in [ContainerID.riserLeft, .cabinetMiddle] {
            for n in id.spec.capacity...id.spec.hardCap {
                var chomp = DrawerSim(id, count: n)
                let accepted = chomp.chomp()
                #expect(accepted == (n < id.spec.hardCap))
                var widest: Float = 0
                for _ in 0..<120 where chomp.needsFrames {
                    _ = chomp.step(Self.dt)
                    widest = max(widest, chomp.p)
                    #expect(!chomp.isRevealed, "\(id) n=\(n) chomp at \(chomp.p)")
                }
                #expect(widest < Visibility.drawerOpen && chomp.p == chomp.closedLimit)
                var peek = DrawerSim(id, count: n)
                widest = 0
                for f in 0..<120 where peek.needsFrames || f == 0 {
                    if f < 30 { peek.peek(peek.params.peekMax) }
                    _ = peek.step(Self.dt)
                    widest = max(widest, peek.p)
                    #expect(!peek.isRevealed, "\(id) n=\(n) peek at \(peek.p)")
                }
                #expect(widest < Visibility.drawerOpen && peek.p == peek.closedLimit)
            }
        }
    }

    @Test("Hard sleep mid-chomp ends it shut (at the gap) and still owes the swallow")
    func chompHardSleep() {
        var sim = DrawerSim(.riserLeft, count: 10)
        _ = sim.chomp()
        for _ in 0..<6 { _ = sim.step(Self.dt) }
        #expect(sim.p > sim.closedLimit + 1)
        let events = sim.forceRest()
        #expect(sim.p == 2 && events.last == .settled(2) && !sim.isRevealed && !sim.needsFrames)
    }

    @Test("A drawer resting at its jam gap closes to the new gap when items leave; an open one stays open")
    func emptiedCloses() {
        var jammed = DrawerSim(.riserLeft, count: 14)
        #expect(jammed.p == 6)
        jammed.setCount(0)
        let events = runDrawer(&jammed)
        #expect(jammed.p == 0 && events.last == .settled(0) && !jammed.isRevealed)
        var fewer = DrawerSim(.cabinetTop, count: 14)
        fewer.setCount(12)
        _ = runDrawer(&fewer)
        #expect(fewer.p == 4)
        var open = DrawerSim(.riserLeft, p: 10, count: 14)
        open.setCount(0)
        #expect(!open.needsFrames && open.p == 10)
    }

    // MARK: Menus

    @Test("Move to ▸ ticks and disables the container the tokens are all in; a mixed selection may still go there")
    func moveToHere() {
        var s = ContainerReducerTests.desk(8)
        for i in 1...5 { s.tokens.move(ModelFixture.key(UInt64(i)), to: .container(.penCup, order: 9)) }
        let inside = MenuSpec.token([ModelFixture.key(1)], s)
        #expect(inside.item("moveTo.penCup")?.isEnabled == false && inside.item("moveTo.penCup")?.isChecked == true)
        #expect(inside.item("moveTo.phone")?.isEnabled == true && inside.item("moveTo.phone")?.isChecked == false)
        // Two pens, one already inside: five stay, so they fit six (the movers are not counted twice).
        let mixed = MenuSpec.token([ModelFixture.key(5), ModelFixture.key(6)], s)
        #expect(mixed.item("moveTo.penCup")?.isEnabled == true && mixed.item("moveTo.penCup")?.isChecked == false)
    }
}

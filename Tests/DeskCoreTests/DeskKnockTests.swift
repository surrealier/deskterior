import Foundation
import Testing
@testable import DeskCore

/// A random but valid desk: tokens on screen cells, in containers (up to their hard caps), in piles and on the
/// floor; random drawer openings, phone, cup and basket states.
func randomDesk(_ seed: UInt64) -> DeskState {
    var rng = SplitMix64(seed: seed)
    var s = DeskState()
    let kinds = FileKind.allCases
    let n = rng.nextInt(in: 0...90)
    for i in 0..<n {
        let key = TokenKey(volume: "V", inode: UInt64(i + 1))
        let meta = TokenMeta(name: "file\(i).txt", kind: kinds[rng.nextInt(below: kinds.count)])
        let loc: Location
        switch rng.nextInt(below: 4) {
        case 0: loc = .screen(page: rng.nextInt(below: 2), col: rng.nextInt(below: 9), row: rng.nextInt(below: 5))
        case 1:
            let id = ContainerID.allCases[rng.nextInt(below: ContainerID.allCases.count)]
            loc = .container(id, order: rng.nextInt(below: 30))
        case 2:
            let pile = PileID("P\(rng.nextInt(in: 1...6))")
            if s.piles[pile] == nil {
                s.piles[pile] = SIMD2(Float(rng.nextInt(in: 20...490)), Float(rng.nextInt(in: 5...120)))
            }
            loc = .desk(pile: pile, order: rng.nextInt(below: 4))
        default: loc = .floor(x: rng.nextInt(in: 0...496))
        }
        if !s.tokens.insert(key, meta: meta, at: loc) {
            s.tokens.insert(key, meta: meta, at: .floor(x: i))
        }
    }
    for p in s.piles.keys where s.tokens.members(of: p).isEmpty { s.piles[p] = nil }
    for id in ContainerID.allCases where id.isDrawer {
        let travel = Int(id.spec.travel ?? 1)
        s.drawers[id] = DrawerState(p: max(Float(rng.nextInt(in: 0...travel)), id.spec.closedLimit(count: s.tokens.count(in: id))))
    }
    s.phone.faceDown = rng.nextBool()
    s.penCup = PenCupState(state: rng.nextBool() ? "upright" : "lyingRight", pos: [Float(rng.nextInt(in: 40...470)), 60])
    s.wastebasket = BasketState(state: rng.nextBool(probability: 0.8) ? "upright" : "tippedLeft", swishes: rng.nextInt(below: 9))
    return s
}

@Suite("DeskKnock")
struct DeskKnockTests {
    static let dt: Float = 1.0 / 60
    static let env = ReduceEnv(now: Date(timeIntervalSince1970: 0))

    @Test("A knock never changes where a token lives (random desks, plan + every sim it drives)")
    func neverChangesMembership() {
        for seed in UInt64(0)..<60 {
            let before = randomDesk(seed)
            #expect(before.violations().isEmpty, "fixture \(seed): \(before.violations())")
            var after = before
            let plan = DeskKnock.plan(for: after, origin: SIMD2(256, 0), strength: 1, seed: seed)
            for action in DeskKnock.actions(plan, state: before) { _ = reduce(&after, action, Self.env) }
            #expect(after.tokens == before.tokens)
            #expect(after.piles == before.piles)
            #expect(after.violations().isEmpty)

            // Drive the sims the plan touches and check none of them asks for a membership change.
            for id in ContainerID.allCases where id.isDrawer {
                let count = before.tokens.count(in: id)
                var drawer = DrawerSim(id, p: before.drawerOpening(id), count: count)
                let p0 = drawer.p
                let closes = drawer.knock()
                #expect(closes == plan.drawerCloses.contains(id))
                var events: [DrawerSim.Event] = []
                for _ in 0..<240 where drawer.needsFrames { events += drawer.step(Self.dt) }
                #expect(!events.contains(.chompSwallow))
                #expect(drawer.p <= p0, "a knock never opens a drawer")
                if drawer.isJammed { #expect(drawer.p == p0, "jammed drawers stay put") }
                if closes { #expect(drawer.p == DeskKnock.drawerTargets(plan, state: before)[id]) }
                #expect(after.drawerOpening(id) == drawer.p)
            }
            var cup = PenCupMachine(before.penCup)
            var cupEvents = cup.knock(strength: 1)
            for _ in 0..<120 { cupEvents += cup.step(Self.dt) }
            #expect(!cupEvents.contains { if case .spill = $0 { true } else { false } })
            #expect(cup.state.state == before.penCup.state)
            var basket = WastebasketMachine(before.wastebasket)
            var basketEvents = basket.knock()
            for _ in 0..<120 { basketEvents += basket.step(Self.dt) }
            #expect(!basketEvents.contains { if case .spill = $0 { true } else { false } })
            #expect(basket.state == before.wastebasket)
        }
    }

    @Test("Ajar non-jammed drawers within 3 px snap shut; open and jammed ones do not")
    func drawerSelection() {
        var s = DeskState()
        s.drawers[.riserLeft] = DrawerState(p: 2)
        s.drawers[.riserRight] = DrawerState(p: 9)
        s.drawers[.cabinetTop] = DrawerState(p: 6)
        for i in 0..<14 {
            s.tokens.insert(TokenKey(volume: "V", inode: UInt64(i + 1)), meta: TokenMeta(name: "\(i)", kind: .doc),
                            at: .container(.cabinetTop, order: i))
        }
        let plan = DeskKnock.plan(for: s, origin: SIMD2(100, 0), seed: 1)
        #expect(plan.drawerCloses == [.riserLeft])
        #expect(plan.drawerJostle == [.cabinetTop])
        let actions = DeskKnock.actions(plan, state: s)
        #expect(actions.count == 1)
        for action in actions { _ = reduce(&s, action, Self.env) }
        #expect(s.drawerOpening(.riserLeft) == 0 && s.drawerOpening(.riserRight) == 9 && s.drawerOpening(.cabinetTop) == 6)
    }

    @Test("Live sims decide: a held or chomping drawer is left alone, a drawer ajar right now snaps shut")
    func liveDrawers() {
        var s = DeskState()
        s.drawers[.riserLeft] = DrawerState(p: 2)
        s.drawers[.riserRight] = DrawerState(p: 2)
        s.drawers[.cabinetTop] = DrawerState(p: 0)
        var held = DrawerSim(.riserLeft, p: 2)
        held.beginDrag()
        var chomping = DrawerSim(.riserRight, p: 0)
        _ = chomping.chomp()
        for _ in 0..<3 { _ = chomping.step(Self.dt) }
        #expect(chomping.p > 0 && chomping.p <= 3)
        var ajar = DrawerSim(.cabinetTop, p: 0)
        ajar.setTarget(3)
        for _ in 0..<60 { _ = ajar.step(Self.dt) }
        let live: [ContainerID: DrawerSim] = [.riserLeft: held, .riserRight: chomping, .cabinetTop: ajar]
        let plan = DeskKnock.plan(for: s, drawers: live, origin: SIMD2(256, 0), seed: 3)
        #expect(plan.drawerCloses == [.cabinetTop])
        var knock = DeskKnock()
        #expect(knock.knock(s, drawers: live, at: 0, origin: SIMD2(256, 0), seed: 3) == plan)
        // The live sims agree when the scene knocks them.
        let heldCloses = held.knock(), chompCloses = chomping.knock(), ajarCloses = ajar.knock()
        #expect(!heldCloses && !chompCloses && ajarCloses)
    }

    @Test("Cooldown: one knock per second")
    func cooldown() {
        var knock = DeskKnock()
        let s = DeskState()
        let first = knock.knock(s, at: 10, origin: SIMD2(256, 0), seed: 1) != nil
        #expect(first)
        let tooSoon = knock.knock(s, at: 10.5, origin: SIMD2(256, 0), seed: 2) == nil
        #expect(tooSoon)
        let afterCooldown = knock.knock(s, at: 11, origin: SIMD2(256, 0), seed: 3) != nil
        #expect(afterCooldown)
    }

    @Test("Hops spread out from the origin, stay within 2 px and end; plans are deterministic")
    func hops() {
        var s = DeskState()
        s.piles = ["P1": SIMD2(40, 50), "P2": SIMD2(450, 50)]
        s.tokens.insert(TokenKey(volume: "V", inode: 1), meta: TokenMeta(name: "a", kind: .pdf), at: .desk(pile: "P1", order: 0))
        s.tokens.insert(TokenKey(volume: "V", inode: 2), meta: TokenMeta(name: "b", kind: .pdf), at: .desk(pile: "P2", order: 0))
        s.tokens.insert(TokenKey(volume: "V", inode: 3), meta: TokenMeta(name: "c", kind: .pdf), at: .floor(x: 30))
        let plan = DeskKnock.plan(for: s, origin: SIMD2(40, 0), seed: 5)
        #expect(plan == DeskKnock.plan(for: s, origin: SIMD2(40, 0), seed: 5))
        let near = plan.pileHops["P1"]!, far = plan.pileHops["P2"]!
        #expect(near.delay < far.delay)
        #expect(plan.floorHops.count == 1 && plan.wobbles.count == DeskKnock.Wobbler.allCases.count)
        for hop in plan.pileHops.values {
            let offsets = (0...plan.frames).map(hop.offset(atFrame:))
            #expect(offsets.max() == 2 && offsets.min() == 0)
            #expect(hop.offset(atFrame: hop.endFrame) == 0)
        }
        for w in plan.wobbles.values {
            #expect((0...plan.frames).allSatisfy { abs(w.lean(atFrame: $0)) <= 1 })
        }
        #expect(DeskKnock.slamStrength(600) == 1 && DeskKnock.slamStrength(30) == 0.25)
    }
}

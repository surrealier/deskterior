import Foundation
import simd
import Testing
@testable import DeskCore

/// A busy desk: tokens 1–2 in a pile left of the mat, 3 in a pile right of it, 4 already under it, 5–6 on the floor
/// (one stack at x 120, one at x 330), 7 in the open left riser drawer, 8 on the face-up phone, the rest on screen.
private func busyDesk() -> DeskState {
    var s = ModelFixture.mirrored((1...12).map { "f\($0).txt" })
    let k = ModelFixture.key
    s.tokens.move(k(1), to: .desk(pile: "P1", order: 0))
    s.tokens.move(k(2), to: .desk(pile: "P1", order: 1))
    s.piles["P1"] = [100, 36]
    s.tokens.move(k(3), to: .desk(pile: "P2", order: 0))
    s.piles["P2"] = [420, 30]
    s.tokens.move(k(4), to: .desk(pile: "P3", order: 0))
    s.piles["P3"] = [180, 40]
    s.tokens.move(k(5), to: .floor(x: 120))
    s.tokens.move(k(6), to: .floor(x: 330))
    s.tokens.move(k(7), to: .container(.riserLeft, order: 0))
    s.drawers[.riserLeft] = DrawerState(p: 10)
    s.tokens.move(k(8), to: .container(.phone, order: 0))
    return s
}

@Suite("Clear the Desk plan")
struct ClearDeskPlanTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    @Test("Loose piles and floor stacks go under the mat where the cloth covers them whole; covered ones stay")
    func targets() {
        let s = busyDesk()
        let plan = ClearDeskPlan.make(s)
        let mat = MatFootprint(s.mat)
        #expect(plan.powerOff && plan.phoneDown && plan.shutDrawers == [.riserLeft: 0])
        #expect(plan.sweeps.map(\.pile).sorted() == ["P1", "P2"], "P3 is under the mat already")
        #expect(plan.tucks.map(\.floorX) == [120, 330] && plan.tucks.map(\.keys) == [[F.key(5)], [F.key(6)]])
        let keyboard = s.mat.keyboardFootprint
        for to in plan.sweeps.map(\.to) + plan.tucks.map(\.to) {
            #expect(mat.coveredSamples(at: to) == 5, "\(to) is not covered whole")
            #expect(mat.isInside(to, inset: ClearDeskPlan.tuckInset - 0.01))
            #expect(!keyboard.contains(to))
        }
        // Each sweep crosses the edge on its way, nearest side first.
        for sweep in plan.sweeps {
            #expect(mat.isInside(sweep.edge, inset: -0.5) && !mat.isInside(sweep.from))
            #expect(sweep.contact < sweep.atEdge && sweep.atEdge < sweep.under)
        }
        #expect(plan.sweeps.first { $0.pile == "P1" }!.to.x < 200 && plan.sweeps.first { $0.pile == "P2" }!.to.x > 300)
        // New piles for the floor stacks, never an id in use.
        #expect(Set(plan.tucks.map(\.pile)).isDisjoint(with: Set(s.piles.keys)))
        #expect(plan.duration > plan.sweeps.map(\.under).max()! && plan.duration < 4)
    }

    @Test("The brush pass leaves from the brush's spot, goes round the mat and comes back; pushes move with it")
    func brushPass() throws {
        let s = busyDesk()
        let plan = ClearDeskPlan.make(s)
        let mat = MatFootprint(s.mat)
        #expect(plan.brush.first?.at == s.brush.pos && plan.brush.last?.at == s.brush.pos)
        #expect(zip(plan.brush, plan.brush.dropFirst()).allSatisfy { $0.t <= $1.t })
        #expect(plan.brush.last!.t <= 2.4 + 1e-3)
        // Never across the mat (only into its edge, to push).
        for t in stride(from: Float(0), through: plan.brush.last!.t, by: 0.01) {
            let p = try #require(plan.brushPosition(at: t))
            #expect(!mat.isInside(p, inset: 2), "brush over the mat at \(t): \(p)")
        }
        // A swept pile rests where it lay until the brush reaches it, and is under at the end.
        for sweep in plan.sweeps {
            #expect(ClearDeskPlan.position(of: sweep, at: 0) == sweep.from)
            #expect(ClearDeskPlan.position(of: sweep, at: sweep.under) == sweep.to)
            #expect(simd_distance(ClearDeskPlan.position(of: sweep, at: sweep.atEdge), sweep.edge) < 0.01)
        }
    }

    @Test("Applying the plan hides every token; one undo restores the layout exactly")
    func applyAndUndo() {
        var s = busyDesk()
        let before = s
        var journal = UndoJournal()
        let effects = Reducer.reduce(&s, journal: &journal, .clearDesk, env)
        #expect(effects.first == .play(.crtOff, .monitor) && effects.contains(.persist))
        #expect(journal.undoLabel == "Clear the Desk" && s.violations().isEmpty)
        #expect(s.monitor.power == .off && s.phone.faceDown && s.drawerOpening(.riserLeft) == 0)
        #expect(s.tokens.keys { if case .floor = $0 { true } else { false } }.isEmpty)
        // Under the mat (as the model's mat lies) or hidden in a container or the dark monitor.
        let mat = MatFootprint(s.mat)
        var covered = Set<PileID>()
        for id in s.tokens.piles where mat.coveredSamples(at: s.piles[id]!) >= 3 { covered.insert(id) }
        #expect(covered == Set(s.tokens.piles))
        let coverage = Visibility.Coverage(coveredPiles: covered)
        for k in s.tokens.sortedKeys {
            #expect(Visibility.of(s.tokens.location(of: k)!, s, coverage).isHidden, "\(k) still on show")
        }
        _ = Reducer.reduce(&s, journal: &journal, .undo, env)
        #expect(s.tokens == before.tokens && s.piles == before.piles && s.monitor == before.monitor)
        #expect(s.phone == before.phone && s.drawers == before.drawers)
        _ = Reducer.reduce(&s, journal: &journal, .redo, env)
        #expect(s.monitor.power == .off && covered == Set(s.tokens.piles))
    }

    @Test("A tidy desk changes nothing (no undo step) but still plays; a pile the mat cannot cover stays put")
    func tidyAlready() {
        var s = F.mirrored(["a.txt"])
        s.monitor.power = .off
        s.phone.faceDown = true
        let before = s
        var journal = UndoJournal()
        let effects = Reducer.reduce(&s, journal: &journal, .clearDesk, env)
        #expect(s == before && journal.undoLabel == nil)
        #expect(effects == [.play(.clearDesk, .clearDesk(ClearDeskPlan.make(before))), .wakeLoop])
        // A mat folded small (all its cloth piled at one corner) has nowhere to tuck a pile.
        var crumpled = busyDesk()
        crumpled.mat.size = [96, 48]
        let plan = ClearDeskPlan.make(crumpled)
        #expect(plan.sweeps.allSatisfy { MatFootprint(crumpled.mat).coveredSamples(at: $0.to) == 5 })
    }

    @Test("Deterministic: the same desk makes the same plan")
    func deterministic() {
        #expect(ClearDeskPlan.make(busyDesk()) == ClearDeskPlan.make(busyDesk()))
    }

    @Test("Bigger stacks rest further in, so their bumps clear the hem")
    func insets() {
        #expect(ClearDeskPlan.inset(count: 1) == ClearDeskPlan.tuckInset)
        #expect((1...9).map { ClearDeskPlan.inset(count: $0) } == (1...9).map { ClearDeskPlan.inset(count: $0) }.sorted())
        #expect(ClearDeskPlan.inset(count: 8) >= BumpField.extent(count: 8) + 6)
    }

    @Test("Piles that will share a bump rest as far in as the shared bump needs, clear of the hem")
    func sharedBumps() {
        var s = busyDesk()
        // Another floor stack beside the one at x 120 and a pile beside P1: they go under near the front-left, where
        // their shared bump comes to take in P3 (already under the mat), which is nudged in with them.
        s.tokens.move(F.key(9), to: .floor(x: 128))
        s.tokens.move(F.key(11), to: .desk(pile: "P4", order: 0))
        s.tokens.move(F.key(12), to: .desk(pile: "P4", order: 1))
        s.piles["P4"] = [104, 30]
        let plan = ClearDeskPlan.make(s)
        let mat = MatFootprint(s.mat)
        var after = s
        plan.apply(to: &after)
        let piles = after.tokens.piles.compactMap { id in
            after.piles[id].map { PileInput(id: after.tokens.piles.firstIndex(of: id)!, position: $0,
                                            count: after.tokens.members(of: id).count) }
        }
        let groups = PileClusterer.groups(piles)
        #expect(groups.contains { $0.ids.count > 1 }, "some piles share a bump")
        #expect(plan.nudges.keys.sorted() == ["P3"] && after.piles["P3"] == plan.nudges["P3"])
        // One undo of the whole change puts P3 back too.
        var journal = UndoJournal()
        var undone = s
        _ = Reducer.reduce(&undone, journal: &journal, .clearDesk, env)
        _ = Reducer.reduce(&undone, journal: &journal, .undo, env)
        #expect(undone.piles["P3"] == s.piles["P3"] && undone.tokens == s.tokens)
        for g in groups {
            let need = ClearDeskPlan.inset(count: g.count) - 0.01
            for id in g.ids {
                let p = piles.first { $0.id == id }!.position
                #expect(mat.isInside(p, inset: need), "a pile of a \(g.count)-token bump at \(p) is within \(need) px of an edge")
            }
        }
    }
}

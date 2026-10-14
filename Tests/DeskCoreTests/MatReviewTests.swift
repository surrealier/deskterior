import Foundation
import simd
import Testing
@testable import DeskCore

/// The M9 review's fixes in the core: tuck spots, the journaled join, the cloth's carry, peel, peek and settle, saved
/// particles, and the bumps as drawn.
@Suite("Desk mat review (M9 core)")
struct MatReviewTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    // MARK: Tuck spots and the journal

    @Test("A tuck spot is deep enough inside for its stack and never under the keyboard")
    func tuckSpots() throws {
        let mat = MatFootprint(MatState())
        let keyboard = MatState().keyboardFootprint, keep = ClearDeskPlan.keyboardClearance(keyboard)
        // On the keyboard: beside it, still under the mat.
        let beside = try #require(ClearDeskPlan.tuckSpot(near: keyboard.center, count: 1, mat: mat, keyboard: keyboard))
        #expect(!keep.contains(beside) && mat.coveredSamples(at: beside) == 5, "\(beside)")
        // A tall stack set down by the edge rests as deep as its bump needs.
        for n in [1, 3, 6] {
            let p = try #require(ClearDeskPlan.tuckSpot(near: SIMD2(180, 10), count: n, mat: mat, keyboard: keyboard))
            #expect(mat.isInside(p, inset: ClearDeskPlan.inset(count: n) - 0.01) && !keep.contains(p), "\(n): \(p)")
        }
    }

    @Test("tuckUnderMat: the drop and the joined pile's slide in are one move, and one undo")
    func tuckUnderMat() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt"])
        _ = reduce(&s, .dropOnDesk([F.key(1), F.key(2)], pile: "P1", at: [300, 30]), env)
        let before = s
        var journal = UndoJournal()
        let effects = Reducer.reduce(&s, journal: &journal, .tuckUnderMat([F.key(3)], pile: "P1", at: [300, 40]), env)
        #expect(effects == [.persist, .wakeLoop])
        #expect(s.tokens.members(of: "P1") == [F.key(1), F.key(2), F.key(3)] && s.piles["P1"] == [300, 40])
        #expect(journal.undoLabel == "Move")
        _ = Reducer.reduce(&s, journal: &journal, .undo, env)
        #expect(s.piles == before.piles && s.tokens == before.tokens)
        // Off the desk: refused like any drop.
        #expect(reduce(&s, .tuckUnderMat([F.key(3)], pile: "P1", at: [900, 40]), env).isEmpty)
    }

    // MARK: The cloth

    @Test("A flick carries heavy felt: the patch follows at its speed, catches up after the release, folds nothing")
    func flickCarry() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let before = cloth.centroid
        ClothFixtures.drag(&cloth, cloth.index(col: 10, row: 7), by: SIMD2(40, -6), frames: 4)
        #expect(cloth.grabMode == .carry, "the release waits for the patch to catch up")
        ClothFixtures.run(&cloth, 300)
        #expect(cloth.grabMode == nil && cloth.isAsleep)
        #expect(ClothMetrics.foldedCount(cloth) == 0)
        #expect(cloth.centroid.x - before.x > 30, "it went where the pointer let go: \(cloth.centroid - before)")
        // Esc or a menu ends it at once.
        var other = ClothSim()
        ClothFixtures.run(&other, 5)
        ClothFixtures.drag(&other, other.index(col: 10, row: 7), by: SIMD2(40, 0), frames: 3, release: false)
        other.endGrab(immediately: true)
        #expect(other.grabMode == nil)
    }

    @Test("Whatever a carry flipped over lays back on release; a deliberate fold stays")
    func carryUnflips() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let i = cloth.index(col: 17, row: 7)
        ClothFixtures.drag(&cloth, i, by: SIMD2(30, 0), frames: 10, release: false)
        // Fold the front-left corner over by hand, as a whip would.
        for k in [cloth.cornerIndices[0], cloth.cornerIndices[0] + 1, cloth.cornerIndices[0] + cloth.cols] {
            cloth.parts[k].x.y += 14
            cloth.parts[k].x.z = 3
        }
        cloth.updateLayering()
        #expect(ClothMetrics.foldedCount(cloth) > 0)
        cloth.endGrab(immediately: true)
        ClothFixtures.run(&cloth, 120)
        #expect(ClothMetrics.foldedCount(cloth) == 0)
        var dogEar = ClothFixtures.dogEar()
        ClothFixtures.run(&dogEar, 60)
        #expect(ClothMetrics.foldedCount(dogEar) > 0, "a peel past the middle still folds")
    }

    @Test("A peel held still before letting go stays propped, then lays back slowly; a moving release lays back now")
    func proppedPeel() {
        func peel(holdStill: Int) -> ClothSim {
            var cloth = ClothSim()
            ClothFixtures.run(&cloth, 5)
            ClothFixtures.drag(&cloth, cloth.index(col: 17, row: 0), by: SIMD2(0, -24), frames: 12, hold: holdStill)
            return cloth
        }
        /// The highest the front edge stands off the desk.
        func edgeLift(_ c: ClothSim) -> Float { (0..<c.cols).map { c.lift(c.index(col: $0, row: 0)) }.max() ?? 0 }
        var held = peel(holdStill: 24)
        ClothFixtures.run(&held, 60)
        #expect(held.isScriptRunning && edgeLift(held) > 4, "still propped after 1 s")
        ClothFixtures.run(&held, 200)
        #expect(!held.isScriptRunning && edgeLift(held) < 0.3 && ClothMetrics.foldedCount(held) == 0)
        var quick = peel(holdStill: 0)
        ClothFixtures.run(&quick, 30)
        #expect(!quick.isScriptRunning, "a release on the move lays back within its 16 frames")
    }

    @Test("Peek Under turns a rounded tongue up off the pile, holds it, and lays it back flat where it lay")
    func peekTongue() {
        var cloth = ClothSim()
        cloth.setKeyboard(MatState().keyboardFootprint)
        ClothFixtures.run(&cloth, 5)
        let start = cloth.positions
        let pile = CoveragePile(id: 1, position: SIMD2(300, 26), radius: 6)
        cloth.peekUnder(pile.position, seconds: 1)
        ClothFixtures.run(&cloth, 30)
        #expect(ClothTriangleIndex(cloth).coveredSamples(pile) <= 1)
        let lifted = (0..<cloth.count).filter { cloth.lift($0) > 2 }
        #expect(lifted.count > 12, "a patch, not one edge row: \(lifted.count)")
        #expect(lifted.allSatisfy { !cloth.isWeighted($0) })
        ClothFixtures.run(&cloth, 200)
        #expect(!cloth.isScriptRunning && ClothMetrics.foldedCount(cloth) == 0)
        let drift = zip(cloth.positions, start).map { simd_distance($0, $1) }.max() ?? 0
        #expect(drift < 2, "the edge lies back where it was: \(drift)")
        #expect(ClothMetrics.maxLift(cloth) < 0.3, "flat again: no steps or notches")
        #expect(ClothTriangleIndex(cloth).coveredSamples(pile) == 5)
    }

    @Test("Peek Under next to the keyboard reaches less far rather than drag the keyboard's cloth along")
    func peekSparesKeyboard() throws {
        var cloth = ClothSim()
        cloth.setKeyboard(MatState().keyboardFootprint)
        ClothFixtures.run(&cloth, 5)
        let kb = try #require(cloth.keyboardCenter)
        cloth.peekUnder(SIMD2(254, 30))
        for _ in 0..<40 {
            cloth.step()
            for i in 0..<cloth.count where cloth.isWeighted(i) { #expect(cloth.lift(i) < 0.01) }
        }
        let moved = try #require(cloth.keyboardCenter)
        #expect(simd_distance(moved, kb) < 1.5, "\(kb) → \(moved)")
    }

    @Test("Settling mid-motion ends at rest: a peek lies back, a resize reaches its size, a peel falls")
    func settleNow() {
        var peek = ClothSim()
        ClothFixtures.run(&peek, 5)
        peek.peekUnder(SIMD2(300, 20))
        ClothFixtures.run(&peek, 20)
        #expect(ClothMetrics.maxLift(peek) > 8)
        peek.settleNow()
        #expect(peek.isAsleep && !peek.isScriptRunning && ClothMetrics.maxLift(peek) < 1)

        var resize = ClothSim()
        ClothFixtures.run(&resize, 5)
        resize.transform(size: SIMD2(270, 102), angle: 0)
        ClothFixtures.run(&resize, 5)
        resize.settleNow()
        let fit = resize.restSize
        #expect(!resize.isTransforming && resize.isAsleep)
        #expect(fit.x.truncatingRemainder(dividingBy: 6) == 0 && fit.y.truncatingRemainder(dividingBy: 6) == 0, "\(fit)")

        var peel = ClothSim()
        ClothFixtures.run(&peel, 5)
        ClothFixtures.drag(&peel, peel.index(col: 17, row: 0), by: SIMD2(0, -20), frames: 10, release: false)
        peel.settleNow()
        let edge = (0..<peel.cols).map { peel.lift(peel.index(col: $0, row: 0)) }.max() ?? 0
        #expect(peel.grabMode == nil && peel.isAsleep && edge < 0.3 && ClothMetrics.foldedCount(peel) == 0)
    }

    @Test("Saved particles no mat could have are malformed: a fresh mat is laid instead")
    func implausibleParticles() {
        var m = ClothSim().matState()
        #expect(ClothSim(state: m) != nil)
        var wild = ClothSim().positions
        for i in wild.indices { wild[i] = SIMD3(-1e30, wild[i].y, 1e30) }
        m.particles = MatState.encodeParticles(wild)
        #expect(ClothSim(state: m) == nil)
        var collapsed = ClothSim().positions
        for i in collapsed.indices { collapsed[i] = SIMD3(200, 40, 1) }
        m.particles = MatState.encodeParticles(collapsed)
        #expect(ClothSim(state: m) == nil)
        var torn = ClothSim().positions
        torn[100].x += 40
        m.particles = MatState.encodeParticles(torn)
        #expect(ClothSim(state: m) == nil)
        #expect(MatFootprint(m).size == MatState().size, "the model's mat falls back to a flat one")
        // A wrinkled or folded mat is fine.
        #expect(ClothSim(state: ClothFixtures.dogEar().matState()) != nil)
        #expect(ClothSim(state: ClothFixtures.wrinkled().matState()) != nil)
    }

    @Test("A menu turn counts only when it moves a corner 2 px")
    func visibleTurns() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let size = cloth.restSize, radius = simd_length(size) / 2
        #expect(!cloth.canTransform(size: size, angle: 1.5 / radius))
        #expect(cloth.canTransform(size: size, angle: 3 / radius))
    }

    @Test("A ⌥⇧ corner drag keeps snapping to 15° though later events lose ⇧")
    func shiftLatched() {
        var cloth = ClothSim(size: SIMD2(120, 48))
        ClothFixtures.run(&cloth, 5)
        let corner = cloth.cornerIndices[2]
        let c0 = ClothFixtures.screen(cloth, corner)
        cloth.beginGrab(particle: corner, cursor: c0, modifiers: [.option, .shift])
        for f in 1...10 {
            cloth.moveGrab(to: c0 + SIMD2(-Float(f), -Float(f) * 1.2), modifiers: [.option])
            cloth.step()
        }
        cloth.endGrab()
        ClothFixtures.run(&cloth, 60)
        let degrees = cloth.matFrame().angle * 180 / .pi
        #expect(abs(degrees) > 10 && abs(degrees - (degrees / 15).rounded() * 15) < 0.5, "\(degrees)°")
    }

    @Test("A hem lift rides the edge up near a point and lets it fall back")
    func hemLift() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let edge = cloth.position(cloth.index(col: 17, row: 0))
        cloth.liftHem(near: SIMD2(edge.x, edge.y), height: 3)
        #expect(cloth.lift(cloth.index(col: 17, row: 0)) > 2.5 && cloth.lift(cloth.index(col: 17, row: 7)) < 0.01)
        #expect(cloth.lift(cloth.index(col: 5, row: 0)) < 0.01)
        ClothFixtures.run(&cloth, 60)
        #expect(ClothMetrics.maxLift(cloth) < 0.3)
    }

    // MARK: Bumps

    @Test("A scaled pile raises its bump in proportion; a sliding-in pile grows its own")
    func scaledBumps() {
        var field = BumpField()
        field.setCoveredPiles([PileInput(id: 0, position: [200, 40], count: 3, scale: 0.5)], animated: false)
        #expect(abs(field.maxHeight - BumpField.bumpHeight(count: 3) / 2) < 0.01)
        field.setCoveredPiles([PileInput(id: 0, position: [200, 40], count: 3)], animated: false)
        #expect(abs(field.maxHeight - BumpField.bumpHeight(count: 3)) < 0.01)
    }

    @Test("A lone token's bump is one mound: an unbroken back rim, a contact line, the crest lit, the right flank dark")
    func bumpShape() throws {
        var bumps = BumpField()
        bumps.setCoveredPiles([PileInput(id: 0, position: [250, 40], count: 1)], animated: false)
        var shading = BumpShading()
        shading.update(bumps, projection: .standard)
        let r = shading.rect
        #expect(!r.isEmpty)
        var rim: [(x: Int, y: Int)] = [], contact = 0, lit = 0, dark = 0
        for y in r.minY..<r.maxY {
            for x in r.minX..<r.maxX {
                guard let s = shading.at(x, y) else { continue }
                if s.flags & BumpShading.rim != 0 { rim.append((x, y)) }
                if s.flags & BumpShading.contact != 0 { contact += 1 }
                if s.flags & BumpShading.rim == 0 && s.level >= 3 * 1024 { lit += 1 }
                if s.flags & BumpShading.contact == 0 && s.level <= 1024 { dark += 1 }
            }
        }
        #expect(rim.count >= 10 && contact >= 8 && lit >= 8 && dark >= 4, "rim \(rim.count) contact \(contact) lit \(lit) dark \(dark)")
        // The rim joins up: each rim pixel has another within one pixel (8-connected), and it spans the bump.
        for p in rim {
            #expect(rim.contains { ($0.x != p.x || $0.y != p.y) && abs($0.x - p.x) <= 1 && abs($0.y - p.y) <= 1 })
        }
        let xs = rim.map(\.x)
        #expect((xs.max() ?? 0) - (xs.min() ?? 0) >= 10)
        // Whole levels, so a flat face is one colour.
        for y in r.minY..<r.maxY {
            for x in r.minX..<r.maxX { if let s = shading.at(x, y) { #expect(s.level & 1023 == 0) } }
        }
    }
}

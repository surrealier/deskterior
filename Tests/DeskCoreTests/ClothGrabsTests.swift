import Foundation
import Testing
@testable import DeskCore

@Suite("ClothGrabs")
struct ClothGrabsTests {
    /// The mode a grab of particle `i` settles on after moving the cursor by `delta`.
    static func mode(_ cloth: ClothSim, _ i: Int, _ delta: SIMD2<Float>,
                     _ modifiers: ClothGrabModifiers = []) -> ClothGrabMode? {
        var cloth = cloth
        let c0 = ClothFixtures.screen(cloth, i)
        cloth.beginGrab(particle: i, cursor: c0, modifiers: modifiers)
        cloth.moveGrab(to: c0 + delta, modifiers: modifiers)
        return cloth.grabMode
    }

    @Test("Grab modes come from the hit region, ⌥ and the first 4 px of motion")
    func modeDecisions() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let centre = cloth.index(col: 17, row: 7), front = cloth.index(col: 17, row: 0)
        let corner = cloth.cornerIndices[1]  // front-right
        #expect(Self.mode(cloth, centre, .zero) == .carry)
        #expect(Self.mode(cloth, centre, .zero, .option) == .slide)
        #expect(Self.mode(cloth, corner, .zero, .option) == .transform)
        #expect(Self.mode(cloth, corner, SIMD2(2, 0)) == .pending)
        #expect(Self.mode(cloth, corner, SIMD2(6, 1)) == .tug)       // outward
        #expect(Self.mode(cloth, corner, SIMD2(-6, -3)) == .peel)    // inward and up
        #expect(Self.mode(cloth, front, SIMD2(0, -6)) == .peel)      // inward
        #expect(Self.mode(cloth, front, SIMD2(0, 6)) == .carry)      // outward edge drag moves the mat
        cloth.setKeyboard(DeskPlaneRect(x: 230, d: 0, width: 50, depth: 20))
        #expect(cloth.isWeighted(front))
        #expect(Self.mode(cloth, front, SIMD2(0, -6)) == .carry)     // the keyboard region cannot be peeled
    }

    @Test("Carry moves the mat as a whole; release keeps 40% of the velocity")
    func carry() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let before = cloth.centroid
        let i = cloth.index(col: 17, row: 7)
        ClothFixtures.drag(&cloth, i, by: SIMD2(40, 0), frames: 20, hold: 20, release: false)
        let held = cloth.velocities
        cloth.endGrab()
        for (v, h) in zip(cloth.velocities, held) { #expect(v == h * 0.4) }
        ClothFixtures.run(&cloth, 60)
        let moved = cloth.centroid - before
        #expect(abs(moved.x - 40) < 4 && abs(moved.y) < 3)
        #expect(abs(cloth.matFrame().angle) < 0.03)
        #expect(ClothMetrics.inBounds(cloth))
    }

    @Test("A fast carry leaves wrinkles that persist")
    func carryWrinkles() {
        var cloth = ClothFixtures.wrinkled()
        let w = ClothMetrics.wrinkle(cloth)
        #expect(w > 0.1)
        ClothFixtures.run(&cloth, 300)
        #expect(ClothMetrics.wrinkle(cloth) > w * 0.8)
    }

    @Test("⌥ slide translates rigidly without wrinkles and stops at the desk bounds")
    func slide() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let before = cloth.positions
        ClothFixtures.drag(&cloth, cloth.index(col: 17, row: 7), by: SIMD2(30, -5), frames: 6, modifiers: .option)
        for (a, b) in zip(cloth.positions, before) {
            #expect(abs(a.x - b.x - 30) < 1e-3 && abs(a.y - b.y - 10) < 1e-3)
        }
        #expect(ClothMetrics.wrinkle(cloth) < 1e-3)
        ClothFixtures.drag(&cloth, cloth.index(col: 17, row: 7), by: SIMD2(0, -40), frames: 6, modifiers: .option)
        #expect(abs((cloth.positions.map(\.y).max() ?? 0) - 104) < 1e-3)
    }

    @Test("A tug cuts the wrinkle metric W by more than 60%")
    func tugSmooths() {
        var cloth = ClothFixtures.wrinkled()
        let w0 = ClothMetrics.wrinkle(cloth)
        ClothFixtures.drag(&cloth, cloth.cornerIndices[1], by: SIMD2(24, 4), frames: 20)
        ClothFixtures.run(&cloth, 60)
        let w1 = ClothMetrics.wrinkle(cloth)
        #expect(w0 > 0.1)
        #expect(w1 < w0 * 0.4, "W \(w0) → \(w1)")
    }

    @Test("Smooth Mat cuts W by more than 60%")
    func smoothSmooths() {
        var cloth = ClothFixtures.wrinkled()
        let w0 = ClothMetrics.wrinkle(cloth)
        cloth.smooth()
        #expect(cloth.isScriptRunning)
        ClothFixtures.run(&cloth, 60)
        #expect(!cloth.isScriptRunning)
        #expect(ClothMetrics.wrinkle(cloth) < w0 * 0.4)
    }

    @Test("A fold persists for 300 steps")
    func foldPersists() {
        var cloth = ClothFixtures.dogEar()
        let folded = ClothMetrics.foldedCount(cloth)
        #expect(folded >= 20)
        let flap = (0..<cloth.count).filter { cloth.normal($0).z < 0 }
        #expect(flap.count >= 20)
        let before = flap.map { cloth.position($0) }
        ClothFixtures.run(&cloth, 300)
        #expect(ClothMetrics.foldedCount(cloth) >= folded * 9 / 10)
        for (k, i) in flap.enumerated() {
            let d = cloth.position(i) - before[k]
            #expect((d.x * d.x + d.y * d.y).squareRoot() < 2)
        }
        #expect(ClothMetrics.inBounds(cloth))
    }

    @Test("Unfold lays a flap back flat")
    func unfold() {
        var cloth = ClothFixtures.dogEar()
        cloth.unfold()
        #expect(cloth.isScriptRunning)
        ClothFixtures.run(&cloth, 90)
        #expect(ClothMetrics.foldedCount(cloth) == 0)
        #expect(abs(ClothMetrics.area(cloth) - 204 * 84) < 204 * 84 * 0.02)
        #expect(ClothMetrics.maxLift(cloth) < 1.5)
    }

    @Test("A peek (corner lifted and released) lays back flat")
    func peekLaysBack() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        ClothFixtures.drag(&cloth, cloth.cornerIndices[0], by: SIMD2(6, -12), frames: 12, hold: 10)
        ClothFixtures.run(&cloth, 90)
        #expect(ClothMetrics.foldedCount(cloth) == 0)
        #expect(ClothMetrics.maxLift(cloth) < 1)
    }

    @Test("⌥-corner transform keeps the opposite corner, snaps size to 6 px and keeps area within 3%")
    func transformGrab() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let anchor = cloth.position(cloth.cornerIndices[0])
        // Drag the back-right corner in toward the anchor: a uniform shrink to ~75%.
        ClothFixtures.drag(&cloth, cloth.cornerIndices[2], by: SIMD2(-51, 10.5), frames: 10, modifiers: .option)
        ClothFixtures.run(&cloth, 30)
        #expect(!cloth.isTransforming)
        let size = cloth.restSize
        #expect(size.x.truncatingRemainder(dividingBy: 6) == 0 && size.y.truncatingRemainder(dividingBy: 6) == 0)
        #expect((96...300).contains(size.x) && (48...104).contains(size.y))
        #expect(abs(size.x - 153) <= 6 && abs(size.y - 63) <= 6)
        let area = ClothMetrics.area(cloth)
        #expect(abs(area - size.x * size.y) < size.x * size.y * 0.03)
        let a = cloth.position(cloth.cornerIndices[0])
        #expect(abs(a.x - anchor.x) < 1 && abs(a.y - anchor.y) < 1)
        // uv rescales with the size, so the pattern never stretches.
        #expect(cloth.uv[cloth.count - 1] == size)
    }

    @Test("⇧ snaps the transform angle to 15°; menu transforms keep area within 3%")
    func transformAngle() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        cloth.transform(size: SIMD2(150, 60), angle: 10 * .pi / 180)
        ClothFixtures.run(&cloth, 30)
        #expect(abs(cloth.matFrame().angle - 10 * .pi / 180) < 0.01)
        #expect(abs(ClothMetrics.area(cloth) - 150 * 60) < 150 * 60 * 0.03)

        var snapped = ClothSim()
        ClothFixtures.run(&snapped, 5)
        // Halve the diagonal and swing it 12° about the front-left anchor: ⇧ rounds the angle to 15°.
        let c = snapped.cornerIndices[2]
        ClothFixtures.drag(&snapped, c, by: SIMD2(-113, 10.85), frames: 8, modifiers: [.option, .shift])
        ClothFixtures.run(&snapped, 30)
        #expect(snapped.restSize == SIMD2(102, 48))
        let degrees = snapped.matFrame().angle * 180 / .pi
        #expect(abs(degrees - 15) < 0.5, "angle \(degrees)°")
        #expect(abs(ClothMetrics.area(snapped) - 102 * 48) < 102 * 48 * 0.03)
    }

    @Test("The keyboard weighs its region to the floor and rides along with a carry")
    func keyboard() throws {
        var cloth = ClothSim()
        let footprint = DeskPlaneRect(x: 206, d: 40, width: 96, depth: 24)
        cloth.setKeyboard(footprint)
        let start = try #require(cloth.keyboardCenter)
        #expect(abs(start.x - footprint.center.x) < 1e-3 && abs(start.y - footprint.center.y) < 1e-3)
        let weighted = (0..<cloth.count).filter { cloth.isWeighted($0) }
        #expect(weighted.count == 16 * 4)
        ClothFixtures.drag(&cloth, cloth.index(col: 6, row: 7), by: SIMD2(30, 0), frames: 15, hold: 5,
                           release: false)
        for i in weighted { #expect(abs(cloth.lift(i)) < 1e-4) }
        cloth.endGrab()
        ClothFixtures.run(&cloth, 40)
        let end = try #require(cloth.keyboardCenter)
        #expect(end.x - start.x > 20)
        cloth.setKeyboard(nil)
        #expect(cloth.keyboardCenter == nil)
    }

    @Test("Peek Under lifts the nearest edge off a pile, then lays it back")
    func peekUnder() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let pile = CoveragePile(id: 1, position: SIMD2(256, 16), radius: 5)
        #expect(ClothTriangleIndex(cloth).coveredSamples(pile) == 5)
        cloth.peekUnder(pile.position)
        ClothFixtures.run(&cloth, 30)
        #expect(ClothTriangleIndex(cloth).coveredSamples(pile) <= 1)
        ClothFixtures.run(&cloth, 150)
        #expect(!cloth.isScriptRunning)
        #expect(ClothTriangleIndex(cloth).coveredSamples(pile) >= 4)
    }

    // MARK: - Review fixes

    @Test("Menu rotations turn only as far as the mat fits the desk; nothing buckles or folds")
    func rotateFitsDesk() {
        for degrees: Float in [15, -15, 30] {
            var cloth = ClothSim()
            ClothFixtures.run(&cloth, 5)
            let angle = degrees * .pi / 180
            #expect(cloth.canTransform(size: cloth.restSize, angle: angle))
            let fit = cloth.fittedTransform(size: cloth.restSize, angle: angle)
            #expect(abs(fit.angle) > 4 * .pi / 180 && abs(fit.angle) < 7 * .pi / 180, "fitted \(fit.angle * 180 / .pi)°")
            #expect((fit.angle > 0) == (degrees > 0) && fit.size == cloth.restSize)
            cloth.transform(size: cloth.restSize, angle: angle)
            ClothFixtures.run(&cloth, 120)
            #expect(ClothMetrics.foldedCount(cloth) == 0)
            #expect(ClothMetrics.wrinkle(cloth) < 0.01)
            #expect(abs(cloth.matFrame().angle - fit.angle) < 0.01)
            #expect(abs(ClothMetrics.area(cloth) - 204 * 84) < 204 * 84 * 0.01)
            // At the limit the item has nothing left to do (the menu disables it).
            #expect(!cloth.canTransform(size: cloth.restSize, angle: fit.angle + (degrees > 0 ? 1 : -1) * .pi / 12))
        }
        // A smaller mat fits the full turn.
        var small = ClothSim()
        ClothFixtures.run(&small, 5)
        small.transform(size: SIMD2(120, 48), angle: .pi / 12)
        ClothFixtures.run(&small, 60)
        #expect(abs(small.matFrame().angle - .pi / 12) < 0.01)
        #expect(ClothMetrics.foldedCount(small) == 0)
    }

    @Test("A ⌥-corner drag that would push the mat off the desk stops at the edge; nothing flips")
    func transformGrabStopsAtEdge() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let anchor = cloth.position(cloth.cornerIndices[3])
        ClothFixtures.drag(&cloth, cloth.cornerIndices[1], by: SIMD2(0, -30), frames: 10, modifiers: .option)
        ClothFixtures.run(&cloth, 60)
        #expect(ClothMetrics.foldedCount(cloth) == 0)
        #expect(ClothMetrics.wrinkle(cloth) < 0.02)
        let size = cloth.restSize
        #expect(abs(ClothMetrics.area(cloth) - size.x * size.y) < size.x * size.y * 0.02)
        let a = cloth.position(cloth.cornerIndices[3])
        #expect(abs(a.x - anchor.x) < 1 && abs(a.y - anchor.y) < 1)
        #expect(cloth.positions.allSatisfy { $0.y > 0.2 && $0.y < 103.8 })
    }

    /// A corner peel up and in by `length` px held over a pile at `pile`, then released. Returns whether the pile
    /// was revealed while held, and the scene after release.
    static func peelOverPile(_ pile: SIMD2<Float>, length: Float) -> (revealed: Bool, scene: ClothScene) {
        var s = ClothScene(piles: [PileInput(id: 0, position: pile, count: 2)])
        s.frames(30)
        let corner = s.cloth.cornerIndices[0]
        let c0 = ClothFixtures.screen(s.cloth, corner)
        let dir = SIMD2<Float>(0.7, -0.75) / (0.7 * 0.7 + 0.75 * 0.75).squareRoot()
        s.cloth.beginGrab(particle: corner, cursor: c0)
        var revealed = false
        for f in 1...20 {
            s.cloth.moveGrab(to: c0 + dir * length * Float(f) / 20)
            s.frames(1)
            revealed = revealed || !s.coverage.isCovered(0)
        }
        s.frames(10)
        revealed = revealed || !s.coverage.isCovered(0)
        s.cloth.endGrab()
        s.frames(90)
        return (revealed, s)
    }

    @Test("Lifting part of the mat to reach a pile lays back on release (O7)")
    func peelToRevealLaysBack() {
        for (pile, length) in [(SIMD2<Float>(166, 18), Float(32)), (SIMD2(166, 18), 40), (SIMD2(162, 14), 24),
                               (SIMD2(162, 14), 32)] {
            let (revealed, s) = Self.peelOverPile(pile, length: length)
            #expect(revealed, "pile \(pile) drag \(length): never revealed")
            #expect(ClothMetrics.foldedCount(s.cloth) == 0, "pile \(pile) drag \(length): left folded")
            #expect(ClothMetrics.maxLift(s.cloth) < 1)
            #expect(s.coverage.isCovered(0))
        }
        // The front edge lifted 16 px lays back too.
        var edge = ClothSim()
        ClothFixtures.run(&edge, 5)
        ClothFixtures.drag(&edge, edge.index(col: 17, row: 0), by: SIMD2(0, -16), frames: 20)
        ClothFixtures.run(&edge, 60)
        #expect(ClothMetrics.foldedCount(edge) == 0)
    }

    @Test("A fold stays only when carried past the middle (O8)")
    func foldNeedsMiddle() {
        // The front edge carried back 18 px of depth: short of the middle (42), lays back.
        var short = ClothSim()
        ClothFixtures.run(&short, 5)
        ClothFixtures.drag(&short, short.index(col: 17, row: 0), by: SIMD2(0, -21), frames: 20)
        ClothFixtures.run(&short, 60)
        #expect(ClothMetrics.foldedCount(short) == 0)
        // Carried back 56: stays folded, a straight strip across the front.
        var past = ClothSim()
        ClothFixtures.run(&past, 5)
        ClothFixtures.drag(&past, past.index(col: 17, row: 0), by: SIMD2(0, -40), frames: 40)
        ClothFixtures.run(&past, 120)
        #expect(ClothMetrics.foldedCount(past) >= 100)
        let row0 = (0..<past.cols).map { past.isFolded(past.index(col: $0, row: 0)) }
        #expect(row0.filter { $0 }.count >= 31, "front row folded: \(row0.filter { $0 }.count) of 35")
        #expect(past.isAsleep)
    }

    @Test("Pulling one point of an edge lifts a tongue, not the whole edge")
    func edgePullIsLocal() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let i = cloth.index(col: 17, row: 0)
        let c0 = ClothFixtures.screen(cloth, i)
        cloth.beginGrab(particle: i, cursor: c0)
        for f in 1...24 {
            cloth.moveGrab(to: c0 + SIMD2(0, -Float(f)))
            cloth.step()
        }
        let lifts = (0..<cloth.cols).map { cloth.lift(cloth.index(col: $0, row: 0)) }
        #expect(lifts[17] > 8, "centre lift \(lifts[17])")
        #expect(lifts[0] < lifts[17] * 0.25 && lifts[34] < lifts[17] * 0.25, "end lifts \(lifts[0]), \(lifts[34])")
        #expect(lifts[5] < lifts[17] * 0.6 && lifts[29] < lifts[17] * 0.6, "lifts \(lifts)")
    }

    @Test("Dragging a dog-ear's tip back opens it flat; letting go short of halfway folds it back down")
    func unpeelByHand() {
        let rest = SIMD3<Float>(358, 92, 1)
        for lift: Float in [0, 12] {
            var cloth = ClothFixtures.dogEar()
            let tip = cloth.cornerIndices[2]
            #expect(cloth.isFolded(tip))
            let from = ClothFixtures.screen(cloth, tip), to = cloth.params.projection.project(rest)
            cloth.beginGrab(particle: tip, cursor: from)
            for f in 1...30 {
                let t = Float(f) / 30
                cloth.moveGrab(to: from + (to - from) * t + SIMD2(0, -lift * sin(t * .pi)))
                cloth.step()
                if f == 10 { #expect(cloth.grabMode == .unpeel) }
            }
            cloth.endGrab()
            ClothFixtures.run(&cloth, 120)
            #expect(ClothMetrics.foldedCount(cloth) == 0, "lift \(lift): \(ClothMetrics.foldedCount(cloth)) folded")
            #expect(ClothMetrics.wrinkle(cloth) < 0.02)
            #expect(abs(ClothMetrics.area(cloth) - 204 * 84) < 204 * 84 * 0.01)
            #expect(ClothMetrics.maxLift(cloth) < 1)
        }
        var partial = ClothFixtures.dogEar()
        let folded = ClothMetrics.foldedCount(partial)
        let tip = partial.cornerIndices[2]
        let from = ClothFixtures.screen(partial, tip), to = partial.params.projection.project(rest)
        ClothFixtures.drag(&partial, tip, by: (to - from) * 0.3, frames: 10)
        ClothFixtures.run(&partial, 120)
        #expect(ClothMetrics.foldedCount(partial) >= folded * 9 / 10)
        // Dragging the flap away from its flat place handles it as plain cloth.
        var away = ClothFixtures.dogEar()
        let c0 = ClothFixtures.screen(away, tip)
        away.beginGrab(particle: tip, cursor: c0)
        away.moveGrab(to: c0 - (to - from) / length2(to - from) * 6)
        #expect(away.grabMode != .unpeel && away.grabMode != .pending)
    }

    @Test("Smooth Mat leaves a dog-ear folded and flat")
    func smoothKeepsFold() {
        var cloth = ClothFixtures.dogEar()
        let folded = ClothMetrics.foldedCount(cloth)
        cloth.smooth()
        ClothFixtures.run(&cloth, 120)
        #expect(ClothMetrics.foldedCount(cloth) >= folded * 9 / 10)
        #expect(ClothMetrics.maxLift(cloth) < 1)
    }

    @Test("The keyboard anchors its region: a tug moves the mat less with it than without")
    func keyboardAnchors() {
        var moved: [Float] = []
        for weighed in [false, true] {
            var cloth = ClothFixtures.wrinkled()
            if weighed { cloth.setKeyboard(DeskPlaneRect(x: 180, d: 30, width: 96, depth: 24)) }
            let c0 = cloth.centroid
            ClothFixtures.drag(&cloth, cloth.cornerIndices[1], by: SIMD2(24, 4), frames: 20)
            ClothFixtures.run(&cloth, 120)
            moved.append(length2(cloth.centroid - c0))
        }
        #expect(moved[1] < moved[0] * 0.9, "moved \(moved)")
    }

    @Test("Clicks without motion leave the mat as it was")
    func clicksAreInert() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 60)
        let before = cloth.positions
        for k in 0..<10 {
            let j = cloth.index(col: 5 + k * 3, row: 3 + (k % 3) * 4)
            cloth.beginGrab(particle: j, cursor: ClothFixtures.screen(cloth, j))
            ClothFixtures.run(&cloth, 8)
            #expect(ClothMetrics.maxLift(cloth) < 0.1)
            cloth.endGrab()
            ClothFixtures.run(&cloth, 20)
        }
        ClothFixtures.run(&cloth, 300)
        #expect(ClothMetrics.wrinkle(cloth) < 0.005)
        let shift = zip(cloth.positions, before).map { length2(SIMD2($0.x - $1.x, $0.y - $1.y)) }.max() ?? 0
        #expect(shift < 0.1)
    }

    @Test("Flat mode keeps the mat on the desk: no peel, carry lift or Peek Under")
    func flatMode() {
        var params = ClothParams.standard
        params.flatMode = true
        var cloth = ClothSim(params: params)
        ClothFixtures.run(&cloth, 5)
        let front = cloth.index(col: 17, row: 0), corner = cloth.cornerIndices[1]
        #expect(Self.mode(cloth, front, SIMD2(0, -6)) == .carry)
        #expect(Self.mode(cloth, corner, SIMD2(-6, -3)) == .carry)
        #expect(Self.mode(cloth, corner, SIMD2(6, 1)) == .tug)
        var carried = cloth
        let i = carried.index(col: 17, row: 7)
        let c0 = ClothFixtures.screen(carried, i)
        carried.beginGrab(particle: i, cursor: c0)
        for f in 1...6 {
            carried.moveGrab(to: c0 + SIMD2(Float(f), 0))
            carried.step()
        }
        #expect(ClothMetrics.maxLift(carried) < 0.5)
        cloth.peekUnder(SIMD2(256, 16))
        #expect(!cloth.isScriptRunning)
    }

    @Test("A desk knock hops the cloth, which settles back where it was")
    func knock() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 60)
        #expect(cloth.isAsleep)
        let before = cloth.positions
        cloth.knock(from: SIMD2(256, 0))
        #expect(!cloth.isAsleep)
        ClothFixtures.run(&cloth, 3)
        #expect(ClothMetrics.maxLift(cloth) > 0.3)
        ClothFixtures.run(&cloth, 120)
        #expect(cloth.isAsleep && ClothMetrics.wrinkle(cloth) < 0.005)
        let shift = zip(cloth.positions, before).map { length2(SIMD2($0.x - $1.x, $0.y - $1.y)) }.max() ?? 0
        #expect(shift < 0.1)
    }
}

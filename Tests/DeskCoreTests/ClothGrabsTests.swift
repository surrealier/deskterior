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
        let pile = CoveragePile(id: 1, position: SIMD2(256, 16), radius: 5, top: 3)
        #expect(ClothTriangleIndex(cloth).coveredSamples(pile) == 5)
        cloth.peekUnder(pile.position)
        ClothFixtures.run(&cloth, 30)
        #expect(ClothTriangleIndex(cloth).coveredSamples(pile) <= 1)
        ClothFixtures.run(&cloth, 150)
        #expect(!cloth.isScriptRunning)
        #expect(ClothTriangleIndex(cloth).coveredSamples(pile) >= 4)
    }
}

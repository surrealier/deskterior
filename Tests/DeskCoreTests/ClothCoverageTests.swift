import Testing
@testable import DeskCore

@Suite("ClothCoverage")
struct ClothCoverageTests {
    @Test("Hysteresis: ≥3/5 for 6 frames covers, ≤1/5 reveals at once, 2/5 holds")
    func hysteresis() {
        var t = CoverageTracker()
        for frame in 1...5 {
            #expect(t.update(samples: [(id: 1, covered: 3)]).isEmpty, "frame \(frame)")
            #expect(!t.isCovered(1))
        }
        #expect(t.update(samples: [(id: 1, covered: 4)]).map(\.covered) == [true])
        #expect(t.isCovered(1))
        // 2/5 is in the dead band: stays covered.
        for _ in 0..<10 { #expect(t.update(samples: [(id: 1, covered: 2)]).isEmpty) }
        #expect(t.isCovered(1))
        #expect(t.update(samples: [(id: 1, covered: 1)]).map(\.covered) == [false])
        #expect(!t.isCovered(1))
        // A dip below 3 restarts the streak.
        for _ in 0..<5 { t.update(samples: [(id: 1, covered: 5)]) }
        t.update(samples: [(id: 1, covered: 2)])
        for _ in 0..<5 { t.update(samples: [(id: 1, covered: 5)]) }
        #expect(!t.isCovered(1))
        t.update(samples: [(id: 1, covered: 5)])
        #expect(t.isCovered(1))
        // Piles that disappear are forgotten.
        t.update(samples: [(id: 2, covered: 0)])
        #expect(!t.isCovered(1) && t.covered[1] == nil)
        t.setCovered(3, true)
        #expect(t.isCovered(3))
    }

    @Test("Under a real mat: covered after 6 frames; revealed when the mat slides off")
    func coverageWithCloth() {
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 5)
        let pile = CoveragePile(id: 7, position: SIMD2(256, 50), radius: 5)
        let outside = CoveragePile(id: 8, position: SIMD2(100, 50), radius: 5)
        #expect(ClothTriangleIndex(cloth).coveredSamples(pile) == 5)
        #expect(ClothTriangleIndex(cloth).coveredSamples(outside) == 0)
        var t = CoverageTracker()
        for _ in 0..<5 { t.update(piles: [pile, outside], cloth: cloth) }
        #expect(!t.isCovered(7))
        #expect(t.update(piles: [pile, outside], cloth: cloth).map(\.id) == [7])
        #expect(t.isCovered(7) && !t.isCovered(8))
        // ⌥-slide the mat away to the right: the pile is revealed at once.
        ClothFixtures.drag(&cloth, cloth.index(col: 17, row: 7), by: SIMD2(120, 0), frames: 4, modifiers: .option)
        #expect(t.update(piles: [pile, outside], cloth: cloth).map(\.covered) == [false])
    }

    @Test("Clustered piles under a resting mat stay covered and the cloth sleeps: no cover/reveal loop")
    func clusteredPilesSettle() {
        for (a, b, gap) in [(3, 3, Float(8)), (2, 5, 9), (1, 1, 8), (4, 4, 12)] {
            var s = ClothScene(piles: [PileInput(id: 0, position: SIMD2(250, 50), count: a),
                                       PileInput(id: 1, position: SIMD2(250 + gap, 50), count: b)])
            var flips = 0, asleep = 0
            var last = [s.coverage.isCovered(0), s.coverage.isCovered(1)]
            for _ in 0..<600 {
                s.frames(1)
                let now = [s.coverage.isCovered(0), s.coverage.isCovered(1)]
                if now != last { flips += 1 }
                last = now
                if s.cloth.isAsleep { asleep += 1 }
            }
            #expect(flips == 0, "piles \(a)+\(b), \(gap) px apart: \(flips) coverage flips")
            #expect(last == [true, true])
            #expect(asleep > 500, "piles \(a)+\(b): asleep \(asleep) of 600 frames")
        }
    }

    @Test("A tall single pile with default footprints stays covered and still")
    func tallPileSettles() {
        for n in [4, 7] {
            let pile = PileInput(id: 0, position: SIMD2(256, 50), count: n)
            var cloth = ClothSim()
            var bumps = BumpField(), cov = CoverageTracker()
            cov.setCovered(0, true)
            bumps.setCoveredPiles([pile], animated: false)
            var changes = 0
            for _ in 0..<300 {
                changes += cov.update(piles: [CoveragePile(id: 0, position: pile.position)], cloth: cloth).count
                bumps.setCoveredPiles(cov.isCovered(0) ? [pile] : [])
                bumps.advance()
                cloth.step(bumps: bumps)
            }
            #expect(changes == 0 && cov.isCovered(0) && cloth.isAsleep, "n=\(n): \(changes) changes")
        }
    }

    @Test("Coverage measures from the bump floor: a lifted edge reveals, a resting fold still covers")
    func clearanceFromFloor() {
        var cloth = ClothSim()
        var bumps = BumpField()
        bumps.setCoveredPiles([PileInput(id: 0, position: SIMD2(256, 50), count: 7)], animated: false)
        ClothFixtures.run(&cloth, 60, bumps: bumps)
        let index = ClothTriangleIndex(cloth)
        // 16 px up on the bump, the cloth is still 1 px above its floor.
        #expect(abs((index.clearance(at: SIMD2(256, 50)) ?? 0) - 1) < 0.1)
        #expect(index.coveredSamples(CoveragePile(id: 0, position: SIMD2(256, 50), radius: 5)) == 5)
        #expect(index.clearance(at: SIMD2(100, 50)) == nil)
        var peek = ClothSim()
        ClothFixtures.run(&peek, 5)
        peek.peekUnder(SIMD2(256, 16))
        ClothFixtures.run(&peek, 30)
        #expect(ClothTriangleIndex(peek).coveredSamples(CoveragePile(id: 1, position: SIMD2(256, 12), radius: 5)) <= 1)
        // A resting dog-ear lies 2 px above the floor (on the base layer or the desk): it covers.
        let dogEar = ClothFixtures.dogEar()
        let folded = ClothTriangleIndex(dogEar)
        for i in 0..<dogEar.count where dogEar.isFolded(i) && dogEar.lift(i) < 1 {
            let p = dogEar.position(i)
            #expect((folded.clearance(at: SIMD2(p.x, p.y)) ?? 9) < 2.5)
            #expect(folded.isCovered(SIMD2(p.x, p.y)))
        }
    }

    @Test("A fold puts two layers over the desk")
    func layers() {
        let cloth = ClothFixtures.dogEar()
        let index = ClothTriangleIndex(cloth)
        let flap = (0..<cloth.count).first { cloth.normal($0).z < 0 && cloth.lift($0) < 1 }!
        let p = cloth.position(flap)
        let layers = index.layers(at: SIMD2(p.x, p.y))
        #expect(layers.count >= 2)
        #expect(layers == layers.sorted())
    }

    @Test("PileClusterer joins piles within 10 px, transitively")
    func clusterer() {
        let piles = [
            PileInput(id: 4, position: SIMD2(0, 0), count: 2),
            PileInput(id: 2, position: SIMD2(9, 0), count: 1),
            PileInput(id: 9, position: SIMD2(18, 0), count: 3),   // chained through id 2
            PileInput(id: 1, position: SIMD2(40, 0), count: 1),
            PileInput(id: 5, position: SIMD2(40, 10), count: 1),  // exactly 10 apart
            PileInput(id: 6, position: SIMD2(80, 0), count: 0),   // an empty pile still counts as one token
        ]
        let groups = PileClusterer.groups(piles)
        #expect(groups.map(\.ids) == [[2, 4, 9], [1, 5], [6]])
        #expect(groups.map(\.count) == [6, 2, 1])
        #expect(groups[0].minPosition == SIMD2(0, 0) && groups[0].maxPosition == SIMD2(18, 0))
        #expect(PileClusterer.groups([]).isEmpty)
    }

    @Test("BumpField stamps rounded boxes and eases changes in over 15 frames")
    func bumpField() {
        var field = BumpField()
        #expect(field.maxHeight == 0 && !field.isEasing)
        field.setCoveredPiles([PileInput(id: 0, position: SIMD2(100, 40), count: 3)])
        #expect(field.isEasing && field.revision == 0 && field.maxHeight == 0)
        var revisions: [UInt64] = []
        for _ in 0..<15 {
            field.advance()
            revisions.append(field.revision)
        }
        #expect(revisions == Array(1...15))
        #expect(!field.isEasing)
        #expect(field.height(x: 100, d: 40) == 7)                  // h = 3 + 2·(3−1)
        #expect(field.height(x: 100 + 4, d: 40) == 7)              // inside the plateau (r/2 = 5)
        #expect(field.height(x: 100 + 10, d: 40) == 0)             // r = 7 + 3
        #expect(field.height(x: 100 + 7, d: 40) > 0 && field.height(x: 100 + 7, d: 40) < 7)
        field.advance()
        #expect(field.revision == 15)                               // settled: no more revisions
        // Same piles again: nothing to do.
        field.setCoveredPiles([PileInput(id: 0, position: SIMD2(100, 40), count: 3)])
        #expect(!field.isEasing)
        // Halfway through an ease the height is in between.
        field.setCoveredPiles([PileInput(id: 0, position: SIMD2(100, 40), count: 7)])
        for _ in 0..<7 { field.advance() }
        let mid = field.height(x: 100, d: 40)
        #expect(mid > 7 && mid < 15)
        // Instant changes (restoring a layout) bump the revision once.
        field.setCoveredPiles([], animated: false)
        #expect(field.maxHeight == 0 && field.revision == 23 && field.groups.isEmpty)
    }
}

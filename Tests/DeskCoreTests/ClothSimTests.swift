import Foundation
import Testing
@testable import DeskCore

/// Shared cloth scenarios for the cloth suites.
enum ClothFixtures {
    /// Core art point of particle `i` (where a cursor grabbing it would be).
    static func screen(_ cloth: ClothSim, _ i: Int) -> SIMD2<Float> {
        cloth.params.projection.project(cloth.position(i))
    }

    static func run(_ cloth: inout ClothSim, _ frames: Int, bumps: BumpField? = nil) {
        for _ in 0..<frames { cloth.step(bumps: bumps) }
    }

    /// Drags particle `i` by `delta` (core px) in `frames` equal moves, then holds `hold` frames.
    static func drag(_ cloth: inout ClothSim, _ i: Int, by delta: SIMD2<Float>, frames: Int, hold: Int = 0,
                     modifiers: ClothGrabModifiers = [], release: Bool = true, bumps: BumpField? = nil) {
        let c0 = screen(cloth, i)
        cloth.beginGrab(particle: i, cursor: c0, modifiers: modifiers)
        for f in 1...frames {
            cloth.moveGrab(to: c0 + delta * (Float(f) / Float(frames)), modifiers: modifiers)
            cloth.step(bumps: bumps)
        }
        run(&cloth, hold, bumps: bumps)
        if release { cloth.endGrab() }
    }

    /// A quick carry to the left leaves a ridge across the mat (W ≈ 0.27).
    static func wrinkled() -> ClothSim {
        var cloth = ClothSim()
        run(&cloth, 10)
        drag(&cloth, cloth.index(col: 24, row: 7), by: SIMD2(-72, 0), frames: 12)
        run(&cloth, 60)
        return cloth
    }

    /// The back-right corner peeled in over the mat and released: a dog-ear lying underside-up.
    static func dogEar() -> ClothSim {
        var cloth = ClothSim()
        run(&cloth, 10)
        drag(&cloth, cloth.cornerIndices[2], by: SIMD2(-60, 18), frames: 30)
        run(&cloth, 30)
        return cloth
    }

    /// A 10×12 paper-icon pile sprite (outline + white).
    static let pileSprite: PixelBuffer = {
        var c = PixelCanvas(width: 10, height: 12, fill: .neutral9)
        c.stroke(c.bounds, Role.outline)
        c.hline(x: 2, y: 4, length: 6, .neutral6)
        c.hline(x: 2, y: 7, length: 6, .neutral6)
        return c.buffer
    }()
}

@Suite("ClothSim")
struct ClothSimTests {
    @Test("A fresh mat settles flat and falls asleep")
    func settlesFlat() {
        var cloth = ClothSim()
        #expect(cloth.count == 525 && cloth.cols == 35 && cloth.rows == 15)
        ClothFixtures.run(&cloth, 120)
        #expect(cloth.isAsleep)
        let z = cloth.positions.map(\.z)
        #expect(z.allSatisfy { abs($0 - 1) < 0.02 })
        #expect(ClothMetrics.wrinkle(cloth) < 0.005)
        let frame = cloth.matFrame()
        #expect(abs(frame.origin.x - 154) < 0.01 && abs(frame.origin.y - 8) < 0.01 && abs(frame.angle) < 1e-4)
        #expect(abs(ClothMetrics.area(cloth) - 204 * 84) < 1)
        // Asleep: further steps change nothing.
        let hash = ClothMetrics.stateHash(cloth)
        ClothFixtures.run(&cloth, 10)
        #expect(ClothMetrics.stateHash(cloth) == hash)
    }

    @Test("Rest material coordinates tile the 204×84 mat at 6 px")
    func restGrid() {
        let cloth = ClothSim()
        #expect(cloth.uv[1] == SIMD2(6, 0))
        #expect(cloth.uv[cloth.index(col: 34, row: 14)] == SIMD2(204, 84))
        #expect(cloth.position(cloth.cornerIndices[2]).x == 358)
        #expect(cloth.position(cloth.cornerIndices[2]).y == 92)
        #expect(cloth.region(of: 0) == .corner(0))
        #expect(cloth.region(of: cloth.index(col: 17, row: 0)) == .edge(inward: SIMD2(0, 1)))
        #expect(cloth.region(of: cloth.index(col: 34, row: 7)) == .edge(inward: SIMD2(-1, 0)))
        #expect(cloth.region(of: cloth.index(col: 17, row: 7)) == .interior)
    }

    @Test("Bump height grows with the pile's token count")
    func bumpHeightGrowsWithCount() {
        #expect((1...8).map { BumpField.bumpHeight(count: $0) } == [3, 5, 7, 9, 11, 13, 15, 15])
        #expect((1...9).map { BumpField.bumpRadius(count: $0) } == [8, 9, 10, 11, 12, 13, 14, 15, 15])
        var last: Float = 0
        for n in [1, 2, 3, 5, 7] {
            var bumps = BumpField()
            bumps.setCoveredPiles([PileInput(id: 0, position: SIMD2(256, 50), count: n)], animated: false)
            var cloth = ClothSim()
            ClothFixtures.run(&cloth, 60, bumps: bumps)
            let top = ClothMetrics.maxZ(cloth)
            #expect(top > last + 1, "n=\(n): mat top \(top) should rise above \(last)")
            #expect(abs(top - (BumpField.bumpHeight(count: n) + 1)) < 1.5)
            // Draping never steals material: the mat keeps its footprint.
            #expect(abs(ClothMetrics.area(cloth) - 204 * 84) < 1)
            last = top
        }
    }

    /// Carry, peel, tug and smooth, driven identically.
    static func scripted(seed: UInt64) -> ClothSim {
        var cloth = ClothSim(seed: seed)
        var bumps = BumpField()
        bumps.setCoveredPiles([PileInput(id: 0, position: SIMD2(300, 40), count: 3)])
        for _ in 0..<20 {
            bumps.advance()
            cloth.step(bumps: bumps)
        }
        ClothFixtures.drag(&cloth, cloth.index(col: 12, row: 6), by: SIMD2(30, 4), frames: 10, bumps: bumps)
        ClothFixtures.drag(&cloth, cloth.cornerIndices[3], by: SIMD2(20, 14), frames: 15, bumps: bumps)
        ClothFixtures.drag(&cloth, cloth.cornerIndices[1], by: SIMD2(10, 0), frames: 8, bumps: bumps)
        cloth.smooth()
        ClothFixtures.run(&cloth, 40, bumps: bumps)
        return cloth
    }

    @Test("Two seeded runs are bit-identical; another seed differs")
    func deterministic() {
        let a = Self.scripted(seed: 7), b = Self.scripted(seed: 7), c = Self.scripted(seed: 8)
        #expect(ClothMetrics.stateHash(a) == ClothMetrics.stateHash(b))
        #expect(a.positions.map(\.x.bitPattern) == b.positions.map(\.x.bitPattern))
        #expect(a.positions.map(\.z.bitPattern) == b.positions.map(\.z.bitPattern))
        #expect(ClothMetrics.stateHash(a) != ClothMetrics.stateHash(c))
    }

    @Test("10k-step seeded fuzz of random grabs: no NaN, always in bounds")
    func fuzz() {
        var rng = SplitMix64(seed: 0xC10_7)
        var cloth = ClothSim(seed: 3)
        var bumps = BumpField()
        let modifierSets: [ClothGrabModifiers] = [[], [], [], [.option], [.option, .shift], [.shift]]
        var cursor = SIMD2<Float>.zero, velocity = SIMD2<Float>.zero, grabFrames = 0
        for step in 0..<10_000 {
            if grabFrames > 0 {
                velocity += SIMD2(rng.nextFloat01() - 0.5, rng.nextFloat01() - 0.5) * 3
                velocity = pointwiseMin(pointwiseMax(velocity, SIMD2(repeating: -12)), SIMD2(repeating: 12))
                cursor += velocity
                cloth.moveGrab(to: cursor, modifiers: modifierSets[rng.nextInt(below: modifierSets.count)])
                grabFrames -= 1
                if grabFrames == 0 { cloth.endGrab() }
            } else if rng.nextInt(below: 12) == 0 {
                switch rng.nextInt(below: 10) {
                case 0: cloth.smooth()
                case 1: cloth.unfold()
                case 2: cloth.peekUnder(SIMD2(150 + rng.nextFloat01() * 220, rng.nextFloat01() * 104))
                case 3:
                    let on = rng.nextBool()
                    cloth.setKeyboard(on ? DeskPlaneRect(x: 206, d: 40, width: 96, depth: 24) : nil)
                case 4:
                    let n = rng.nextInt(below: 4)
                    bumps.setCoveredPiles((0..<n).map {
                        PileInput(id: $0, position: SIMD2(160 + rng.nextFloat01() * 200, rng.nextFloat01() * 100),
                                  count: 1 + rng.nextInt(below: 9))
                    })
                case 5:
                    cloth.transform(size: SIMD2(90 + rng.nextFloat01() * 220, 40 + rng.nextFloat01() * 70),
                                    angle: (rng.nextFloat01() - 0.5) * 1.2)
                default:
                    let i = rng.nextInt(below: cloth.count)
                    cursor = ClothFixtures.screen(cloth, i)
                    velocity = .zero
                    cloth.beginGrab(particle: i, cursor: cursor,
                                    modifiers: modifierSets[rng.nextInt(below: modifierSets.count)])
                    grabFrames = 4 + rng.nextInt(below: 60)
                }
            }
            if step % 997 == 0 { cloth.forceSleep() }
            bumps.advance()
            cloth.step(bumps: bumps)
            if step % 50 == 0 || step == 9_999 {
                #expect(!ClothMetrics.hasNonFinite(cloth), "NaN at step \(step)")
                #expect(ClothMetrics.inBounds(cloth), "out of bounds at step \(step)")
                if ClothMetrics.hasNonFinite(cloth) || !ClothMetrics.inBounds(cloth) { return }
            }
        }
    }

    @Test("Sleep: forceSleep accepts the pose; bumps and input wake it")
    func sleepAndWake() {
        var cloth = ClothFixtures.wrinkled()
        cloth.forceSleep()
        #expect(cloth.isAsleep && cloth.velocities.allSatisfy { $0 == .zero })
        let hash = ClothMetrics.stateHash(cloth)
        ClothFixtures.run(&cloth, 5)
        #expect(ClothMetrics.stateHash(cloth) == hash)
        var bumps = BumpField()
        cloth.step(bumps: bumps)  // first sight of a field with revision 0: still asleep
        #expect(cloth.isAsleep)
        bumps.setCoveredPiles([PileInput(id: 0, position: SIMD2(220, 50), count: 2)])
        bumps.advance()
        cloth.step(bumps: bumps)
        #expect(!cloth.isAsleep)
        cloth.forceSleep()
        cloth.beginGrab(particle: cloth.index(col: 17, row: 7), cursor: SIMD2(256, 200))
        #expect(!cloth.isAsleep)
        cloth.endGrab()
        // A grab blocks forceSleep.
        cloth.beginGrab(particle: 0, cursor: SIMD2(154, 227))
        cloth.forceSleep()
        #expect(!cloth.isAsleep)
    }

    @Test("MatState round-trips through JSON bit-exactly and rejects corrupt data")
    func matStateRoundTrip() throws {
        let cloth = ClothFixtures.dogEar()
        let state = cloth.matState()
        #expect(state.grid == [35, 15] && state.size == [204, 84] && state.pattern == "felt" && state.mode == "cloth")
        let json = try JSONEncoder().encode(state)
        let text = String(decoding: json, as: UTF8.self)
        for key in ["\"origin\"", "\"size\"", "\"angle\"", "\"grid\"", "\"particles\"", "\"pattern\""] {
            #expect(text.contains(key))
        }
        let decoded = try JSONDecoder().decode(MatState.self, from: json)
        #expect(decoded == state)
        let restored = try #require(ClothSim(state: decoded))
        #expect(restored.isAsleep)
        #expect(restored.positions.map(\.x.bitPattern) == cloth.positions.map(\.x.bitPattern))
        #expect(restored.positions.map(\.y.bitPattern) == cloth.positions.map(\.y.bitPattern))
        #expect(restored.positions.map(\.z.bitPattern) == cloth.positions.map(\.z.bitPattern))
        #expect(MatState.encodeParticles(restored.positions) == state.particles)
        // About 8 KB of base64 for 525 particles.
        #expect(state.particles.utf8.count == (525 * 12 + 2) / 3 * 4)

        var bad = state
        bad.particles = "not base64!"
        #expect(ClothSim(state: bad) == nil)
        bad.particles = MatState.encodeParticles(Array(cloth.positions.dropLast()))
        #expect(ClothSim(state: bad) == nil)
        var nan = cloth.positions
        nan[3].z = .nan
        bad.particles = MatState.encodeParticles(nan)
        #expect(ClothSim(state: bad) == nil)
        bad = state
        bad.grid = [35]
        #expect(ClothSim(state: bad) == nil)
        // Older files without pattern/mode decode with defaults.
        let legacy = text.replacingOccurrences(of: "\"pattern\":\"felt\",", with: "")
            .replacingOccurrences(of: ",\"pattern\":\"felt\"", with: "")
        let old = try JSONDecoder().decode(MatState.self, from: Data(legacy.utf8))
        #expect(old.pattern == "felt")
    }

    @Test("Restoring over bumps keeps the absolute pose")
    func restoreOverBumps() throws {
        var bumps = BumpField()
        bumps.setCoveredPiles([PileInput(id: 0, position: SIMD2(256, 50), count: 4)], animated: false)
        var cloth = ClothSim()
        ClothFixtures.run(&cloth, 60, bumps: bumps)
        let restored = try #require(ClothSim(state: cloth.matState(), bumps: bumps))
        for (a, b) in zip(restored.positions, cloth.positions) { #expect(abs(a.z - b.z) < 1e-3) }
    }
}

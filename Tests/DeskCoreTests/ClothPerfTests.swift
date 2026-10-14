import Foundation
import Testing
@testable import DeskCore

/// Release benchmark (DESIGN §5, M8 accept): `scripts/swift-test.sh -c release --filter ClothPerf`.
/// Budgets are asserted only in optimized builds; debug runs just report.
@Suite("ClothPerf")
struct ClothPerfTests {
    #if DEBUG
    static let optimized = false
    #else
    static let optimized = true
    #endif

    /// Median of `runs` timings (ms) of `body`.
    static func median(_ runs: Int, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// An awake mat being carried over three bumps, with a revealed pile, as in a busy frame.
    static func busyScene() -> (ClothSim, BumpField, [PileBillboard]) {
        var cloth = ClothSim()
        var bumps = BumpField()
        bumps.setCoveredPiles([
            PileInput(id: 0, position: SIMD2(190, 40), count: 1),
            PileInput(id: 1, position: SIMD2(252, 52), count: 3),
            PileInput(id: 2, position: SIMD2(318, 44), count: 7),
        ], animated: false)
        let grab = cloth.index(col: 10, row: 7)
        let c0 = cloth.params.projection.project(cloth.position(grab))
        cloth.beginGrab(particle: grab, cursor: c0)
        for f in 1...20 {
            cloth.moveGrab(to: c0 + SIMD2(Float(f) * 2, 0))
            cloth.step(bumps: bumps)
        }
        let sprite = PixelBuffer(width: 12, height: 14, fill: Ink.neutral9.color)
        return (cloth, bumps, [PileBillboard(id: 0, sprite: sprite, position: SIMD3(140, 30, 0))].compactMap { $0 })
    }

    @Test("step and raster fit the 0.6 ms budgets")
    func budgets() {
        var (cloth, bumps, piles) = Self.busyScene()
        let grab = cloth.grabbedParticle ?? 0
        let c0 = cloth.params.projection.project(cloth.position(grab))
        var f: Float = 0
        let step = Self.median(201) {
            f += 1
            cloth.moveGrab(to: c0 + SIMD2(sin(f * 0.1) * 20, 0))
            cloth.step(bumps: bumps)
        }
        var raster = DeskSurfaceRaster()
        let render = Self.median(201) { raster.render(cloth: cloth, piles: piles, bumps: bumps) }
        var tracker = CoverageTracker()
        let coverPiles = (0..<12).map {
            CoveragePile(id: $0, position: SIMD2(170 + Float($0) * 15, 20 + Float($0 % 4) * 18))
        }
        let coverage = Self.median(101) { tracker.update(piles: coverPiles, cloth: cloth) }
        // A held edge fold (guided flap) and the raster of it.
        var fold = ClothSim()
        let edge = fold.index(col: 17, row: 0)
        let e0 = fold.params.projection.project(fold.position(edge))
        fold.beginGrab(particle: edge, cursor: e0)
        for f in 1...30 {
            fold.moveGrab(to: e0 + SIMD2(0, -Float(f)))
            fold.step()
        }
        var g: Float = 0
        let foldStep = Self.median(201) {
            g += 1
            fold.moveGrab(to: e0 + SIMD2(sin(g * 0.1) * 4, -30))
            fold.step()
        }
        let foldRender = Self.median(101) { raster.render(cloth: fold) }
        print(String(format: "ClothPerf (%@): step %.3f ms, raster %.3f ms, coverage(12 piles) %.3f ms, "
                     + "fold step %.3f ms, fold raster %.3f ms",
                     Self.optimized ? "release" : "debug", step, render, coverage, foldStep, foldRender))
        bumps.advance()
        if Self.optimized {
            #expect(step <= 0.6)
            #expect(render <= 0.6)
            #expect(foldStep <= 0.6)
            #expect(foldRender <= 0.6)
        }
    }
}

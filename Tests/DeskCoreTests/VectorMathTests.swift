import Testing
@testable import DeskCore
#if canImport(simd)
import simd
#endif

@Suite("VectorMath")
struct VectorMathTests {
    static func samples(_ count: Int) -> [(SIMD2<Double>, SIMD2<Double>)] {
        var rng = SplitMix64(seed: 42)
        func value() -> Double {
            // Wide magnitudes, both signs, some exact integers (pixel coordinates).
            let r = Double(rng.next() >> 11) / Double(1 << 53)
            switch rng.next() % 4 {
            case 0: return (r - 0.5) * 2e3
            case 1: return (r - 0.5) * 1e-3
            case 2: return Double(Int(r * 600) - 300)
            default: return (r - 0.5) * 16
            }
        }
        return (0..<count).map { _ in (SIMD2(value(), value()), SIMD2(value(), value())) }
    }

    @Test("Known values")
    func known() {
        #expect(VectorMath.dot(SIMD2<Float>(1, 2), SIMD2<Float>(3, 4)) == 11)
        #expect(VectorMath.length(SIMD2<Double>(3, 4)) == 5)
        #expect(VectorMath.distance(SIMD2<Float>(1, 1), SIMD2<Float>(4, 5)) == 5)
        #expect(VectorMath.dot(SIMD3<Double>(1, 2, 3), SIMD3<Double>(4, 5, 6)) == 32)
        let n = VectorMath.normalize(SIMD2<Double>(0, 2))
        #expect(n == SIMD2<Double>(0, 1))
    }

    #if canImport(simd)
    @Test("Bit for bit the same as simd (Float and Double)")
    func matchesSimd() {
        for (a, b) in Self.samples(10_000) {
            let fa = SIMD2<Float>(a), fb = SIMD2<Float>(b)
            #expect(VectorMath.dot(a, b).bitPattern == simd_dot(a, b).bitPattern)
            #expect(VectorMath.dot(fa, fb).bitPattern == simd_dot(fa, fb).bitPattern)
            #expect(VectorMath.length(a).bitPattern == simd_length(a).bitPattern)
            #expect(VectorMath.length(fa).bitPattern == simd_length(fa).bitPattern)
            #expect(VectorMath.distance(a, b).bitPattern == simd_distance(a, b).bitPattern)
            #expect(VectorMath.distance(fa, fb).bitPattern == simd_distance(fa, fb).bitPattern)
            if VectorMath.length(a) > 0 {
                let mine = VectorMath.normalize(a), theirs = simd_normalize(a)
                #expect(mine.x.bitPattern == theirs.x.bitPattern && mine.y.bitPattern == theirs.y.bitPattern)
            }
            let a3 = SIMD3<Double>(a.x, a.y, b.x), b3 = SIMD3<Double>(b.y, a.x, b.x)
            #expect(VectorMath.dot(a3, b3).bitPattern == simd_dot(a3, b3).bitPattern)
        }
        // The one constant the art uses.
        let lamp = SIMD2<Double>(1, 0.72)
        #expect(VectorMath.normalize(lamp) == simd_normalize(lamp))
    }
    #endif
}

#if canImport(simd)
import simd
#endif

/// The few `simd` vector functions Deskterior uses, written in plain Swift so DeskCore builds where the `simd` module
/// does not exist (Linux, Windows). Each follows the `simd` header's own formula (an element-wise product reduced by
/// addition; a square root of that; normalisation by multiplying with the reciprocal square root), so the results
/// match bit for bit: `VectorMathTests` compares them against `simd` on Apple platforms.
public enum VectorMath {
    @inlinable public static func dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a * b).sum() }
    @inlinable public static func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a * b).sum() }
    @inlinable public static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let p = a * b
        return p.x + p.y + p.z
    }
    @inlinable public static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let p = a * b
        return p.x + p.y + p.z
    }

    @inlinable public static func length(_ v: SIMD2<Float>) -> Float { dot(v, v).squareRoot() }
    @inlinable public static func length(_ v: SIMD2<Double>) -> Double { dot(v, v).squareRoot() }
    @inlinable public static func length(_ v: SIMD3<Float>) -> Float { dot(v, v).squareRoot() }
    @inlinable public static func length(_ v: SIMD3<Double>) -> Double { dot(v, v).squareRoot() }

    @inlinable public static func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { length(a - b) }
    @inlinable public static func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { length(a - b) }
    @inlinable public static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { length(a - b) }
    @inlinable public static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { length(a - b) }

    @inlinable public static func normalize(_ v: SIMD2<Float>) -> SIMD2<Float> { v * (1 / dot(v, v).squareRoot()) }
    @inlinable public static func normalize(_ v: SIMD2<Double>) -> SIMD2<Double> { v * (1 / dot(v, v).squareRoot()) }
    @inlinable public static func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { v * (1 / dot(v, v).squareRoot()) }
    @inlinable public static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> { v * (1 / dot(v, v).squareRoot()) }
}

#if !canImport(simd)
// Where `simd` is missing, the same names call `VectorMath`, so code written against `simd` builds unchanged.
@inlinable public func simd_dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { VectorMath.dot(a, b) }
@inlinable public func simd_dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { VectorMath.dot(a, b) }
@inlinable public func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { VectorMath.dot(a, b) }
@inlinable public func simd_dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { VectorMath.dot(a, b) }
@inlinable public func simd_length(_ v: SIMD2<Float>) -> Float { VectorMath.length(v) }
@inlinable public func simd_length(_ v: SIMD2<Double>) -> Double { VectorMath.length(v) }
@inlinable public func simd_length(_ v: SIMD3<Float>) -> Float { VectorMath.length(v) }
@inlinable public func simd_length(_ v: SIMD3<Double>) -> Double { VectorMath.length(v) }
@inlinable public func simd_distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { VectorMath.distance(a, b) }
@inlinable public func simd_distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { VectorMath.distance(a, b) }
@inlinable public func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { VectorMath.distance(a, b) }
@inlinable public func simd_distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { VectorMath.distance(a, b) }
@inlinable public func simd_normalize(_ v: SIMD2<Float>) -> SIMD2<Float> { VectorMath.normalize(v) }
@inlinable public func simd_normalize(_ v: SIMD2<Double>) -> SIMD2<Double> { VectorMath.normalize(v) }
@inlinable public func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { VectorMath.normalize(v) }
@inlinable public func simd_normalize(_ v: SIMD3<Double>) -> SIMD3<Double> { VectorMath.normalize(v) }
#endif

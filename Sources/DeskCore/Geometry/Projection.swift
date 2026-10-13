import simd

/// Oblique desk-plane projection (docs/DESIGN.md §1.3) between desk space and core art px.
///
/// Desk space is `(x, d, z)` in art px: `x` runs left → right, `d` is depth measured back from the desk's front
/// edge (`d = 0`), `z` is height above the desk top. Core art space is `(X, Y)`, y-down:
/// ```
/// X = x
/// Y = frontY − d·k − z          (defaults: frontY = 232, k = 0.5 → "2:1 oblique")
/// ```
/// Depth key = `z`. Every point on one view ray (fixed `X`, `Y`) satisfies `d·k + z = frontY − Y`, so along a
/// ray a **larger z means smaller d, i.e. nearer the front edge and the viewer**: draw larger keys on top.
public struct DeskProjection: Hashable, Sendable, Codable {
    /// Core Y of the desk's front edge (`d = 0`, `z = 0`).
    public var frontY: Float
    /// Screen rows per unit of depth.
    public var k: Float

    public init(frontY: Float = 232, k: Float = 0.5) {
        precondition(k > 0, "projection depth factor must be positive")
        self.frontY = frontY
        self.k = k
    }

    /// The §1.3 desk: front edge at Y 232, depth halved.
    public static let standard = DeskProjection()

    private enum CodingKeys: String, CodingKey {
        case frontY, k
    }

    /// Decodes and validates like `init(frontY:k:)`: `k` must be positive, and both values finite.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let frontY = try c.decode(Float.self, forKey: .frontY)
        let k = try c.decode(Float.self, forKey: .k)
        guard frontY.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .frontY, in: c, debugDescription: "frontY must be finite")
        }
        guard k > 0, k.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .k, in: c, debugDescription: "k must be positive and finite, got \(k)")
        }
        self.init(frontY: frontY, k: k)
    }

    /// Desk `(x, d, z)` → core art `(X, Y)`.
    @inlinable
    public func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(p.x, frontY - p.y * k - p.z)
    }

    /// Core art `(X, Y)` → desk `(x, d, z)` on the plane at height `z` (`d = (frontY − Y − z) / k`).
    @inlinable
    public func unproject(_ q: SIMD2<Float>, z: Float = 0) -> SIMD3<Float> {
        SIMD3(q.x, (frontY - q.y - z) / k, z)
    }

    /// Draw-order key for a desk point: its height `z` (larger is nearer along any view ray).
    @inlinable
    public func depthKey(_ p: SIMD3<Float>) -> Float { p.z }

    /// `project` followed by `snap`: the core art pixel a desk point lands on.
    public func projectToPixel(_ p: SIMD3<Float>) -> ArtPoint {
        Self.snap(project(p))
    }

    /// Rounds to the nearest integer art pixel, **halves away from zero** (`0.5 → 1`, `−0.5 → −1`), so results
    /// are symmetric about 0 and independent of the FPU rounding mode. Non-finite inputs give 0.
    public static func snap(_ v: Float) -> Int {
        guard v.isFinite else { return 0 }
        return Int(max(-1e9, min(1e9, v.rounded(.toNearestOrAwayFromZero))))
    }

    /// `snap` per component.
    public static func snap(_ v: SIMD2<Float>) -> ArtPoint {
        ArtPoint(snap(v.x), snap(v.y))
    }
}

/// Measurements of a cloth pose, for tests, tuning and the review tool.
public enum ClothMetrics {
    /// Wrinkle metric W: mean height above the floor of the face-up particles (px). A flat mat is ≈ 0;
    /// bumps do not count (they are part of the floor), folded flaps are excluded.
    public static func wrinkle(_ cloth: ClothSim) -> Float {
        var sum: Float = 0, n = 0
        for p in cloth.parts where p.floorOffset == cloth.params.thickness && p.w > 0 {
            sum += max(0, p.x.z - p.floorOffset)
            n += 1
        }
        return n > 0 ? sum / Float(n) : 0
    }

    /// The highest crease: the most any face-up particle stands off its floor (px; folds and bumps excluded).
    public static func maxCrease(_ cloth: ClothSim) -> Float {
        var top: Float = 0
        for p in cloth.parts where p.floorOffset == cloth.params.thickness && p.w > 0 { top = max(top, p.x.z - p.floorOffset) }
        return top
    }

    /// Area covered in the desk plane: sum of the absolute xy areas of every triangle (folded layers count twice).
    public static func area(_ cloth: ClothSim) -> Float {
        var total: Float = 0
        let P = cloth.parts
        for r in 0..<(cloth.rows - 1) {
            for c in 0..<(cloth.cols - 1) {
                let i = r * cloth.cols + c
                let a = P[i].x, b = P[i + 1].x, d = P[i + cloth.cols].x, e = P[i + cloth.cols + 1].x
                total += abs(cross2(b - a, e - a)) / 2 + abs(cross2(e - a, d - a)) / 2
            }
        }
        return total
    }

    /// Highest particle z.
    public static func maxZ(_ cloth: ClothSim) -> Float { cloth.parts.map { $0.x.z + $0.ground }.max() ?? 0 }

    /// Highest lift above the floor.
    public static func maxLift(_ cloth: ClothSim) -> Float { cloth.parts.map { $0.x.z - $0.floorOffset }.max() ?? 0 }

    /// Particles lying underside-up (normal z < 0).
    public static func foldedCount(_ cloth: ClothSim) -> Int {
        cloth.parts.filter { $0.floorOffset != cloth.params.thickness }.count
    }

    /// Whether any position or velocity is NaN or infinite.
    public static func hasNonFinite(_ cloth: ClothSim) -> Bool {
        cloth.parts.contains { p in
            !(p.x.x.isFinite && p.x.y.isFinite && p.x.z.isFinite && p.v.x.isFinite && p.v.y.isFinite
                && p.v.z.isFinite)
        }
    }

    /// Whether every particle lies within the desk bounds (`xRange`, `dRange`, absolute z ≥ 0, height above the
    /// bump floor ≤ `zMax`).
    public static func inBounds(_ cloth: ClothSim) -> Bool {
        let q = cloth.params
        return cloth.parts.allSatisfy { p in
            q.xRange.contains(p.x.x) && q.dRange.contains(p.x.y) && p.x.z + p.ground >= 0 && p.x.z <= q.zMax
        }
    }

    /// FNV-1a over the bit patterns of every position and velocity: equal hashes ⇔ bit-identical states.
    public static func stateHash(_ cloth: ClothSim) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ f: Float) {
            h ^= UInt64(f.bitPattern)
            h &*= 0x0000_0100_0000_01B3
        }
        for p in cloth.parts {
            mix(p.x.x); mix(p.x.y); mix(p.x.z)
            mix(p.v.x); mix(p.v.y); mix(p.v.z)
        }
        return h
    }

    @inline(__always)
    private static func cross2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.y - a.y * b.x }
}

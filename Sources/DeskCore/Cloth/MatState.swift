import Foundation

/// The persisted desk mat (`desk.json` → `"mat"`, DESIGN §13): frame, pattern, grid and every particle position
/// as base64 Float32 little-endian `x, d, z` triples.
public struct MatState: Codable, Hashable, Sendable {
    public var pattern: String
    public var mode: String
    /// Desk-plane `[x, d]` of the mat's uv (0, 0) corner (best-fit frame).
    public var origin: [Float]
    /// Rest `[width, depth]`.
    public var size: [Float]
    /// Radians, counter-clockwise in the x/d plane.
    public var angle: Float
    /// `[cols, rows]`.
    public var grid: [Int]
    public var particles: String

    public init(pattern: String = "felt", mode: String = "cloth", origin: [Float], size: [Float], angle: Float,
                grid: [Int], particles: String) {
        self.pattern = pattern
        self.mode = mode
        self.origin = origin
        self.size = size
        self.angle = angle
        self.grid = grid
        self.particles = particles
    }

    public enum CodingKeys: String, CodingKey {
        case pattern, mode, origin, size, angle, grid, particles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? "felt"
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "cloth"
        origin = try c.decode([Float].self, forKey: .origin)
        size = try c.decode([Float].self, forKey: .size)
        angle = try c.decode(Float.self, forKey: .angle)
        grid = try c.decode([Int].self, forKey: .grid)
        particles = try c.decode(String.self, forKey: .particles)
    }

    /// Packs positions as Float32 LE `x, d, z` and base64-encodes them.
    public static func encodeParticles(_ positions: [SIMD3<Float>]) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(positions.count * 12)
        for p in positions {
            for f in [p.x, p.y, p.z] {
                let b = f.bitPattern.littleEndian
                bytes.append(UInt8(truncatingIfNeeded: b))
                bytes.append(UInt8(truncatingIfNeeded: b >> 8))
                bytes.append(UInt8(truncatingIfNeeded: b >> 16))
                bytes.append(UInt8(truncatingIfNeeded: b >> 24))
            }
        }
        return Data(bytes).base64EncodedString()
    }

    /// Decodes positions; nil on malformed base64, a wrong length or any non-finite value.
    public static func decodeParticles(_ s: String, count: Int) -> [SIMD3<Float>]? {
        guard let data = Data(base64Encoded: s), data.count == count * 12 else { return nil }
        let bytes = [UInt8](data)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        func float(_ o: Int) -> Float {
            Float(bitPattern: UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16
                | UInt32(bytes[o + 3]) << 24)
        }
        for k in 0..<count {
            let p = SIMD3(float(k * 12), float(k * 12 + 4), float(k * 12 + 8))
            guard p.x.isFinite && p.y.isFinite && p.z.isFinite else { return nil }
            out.append(p)
        }
        return out
    }
}

extension ClothSim {
    /// The persisted form of this mat.
    public func matState(pattern: String = "felt", mode: String = "cloth") -> MatState {
        let f = matFrame()
        return MatState(
            pattern: pattern, mode: mode, origin: [f.origin.x, f.origin.y], size: [restSize.x, restSize.y],
            angle: f.angle, grid: [cols, rows], particles: MatState.encodeParticles(positions)
        )
    }

    /// Restores a mat (asleep) from its persisted form over the current bump field; nil when the state is
    /// malformed. Positions are clamped to the desk bounds.
    public init?(state: MatState, bumps: BumpField? = nil, params: ClothParams = .standard) {
        guard state.grid.count == 2, state.size.count == 2 else { return nil }
        let cols = state.grid[0], rows = state.grid[1]
        guard cols >= 3, rows >= 3, cols * rows <= 4096,
              state.size[0].isFinite, state.size[1].isFinite, state.size[0] > 0, state.size[1] > 0,
              var pos = MatState.decodeParticles(state.particles, count: cols * rows)
        else { return nil }
        for i in pos.indices {
            pos[i].x = min(max(pos[i].x, params.xRange.lowerBound), params.xRange.upperBound)
            pos[i].y = min(max(pos[i].y, params.dRange.lowerBound), params.dRange.upperBound)
            pos[i].z = min(max(pos[i].z, 0), params.zMax)
        }
        self.init(positions: pos, cols: cols, rows: rows, size: SIMD2(state.size[0], state.size[1]), bumps: bumps,
                  params: params)
    }
}

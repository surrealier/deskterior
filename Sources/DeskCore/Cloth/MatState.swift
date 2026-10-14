import Foundation

extension MatState {
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

/// A restored mat with the floor and coverage derived from it.
public struct RestoredMat: Sendable {
    public var cloth: ClothSim
    public var bumps: BumpField
    public var coverage: CoverageTracker
}

extension ClothSim {
    /// The persisted form of this mat.
    public func matState(pattern: String = "felt", mode: String = "cloth") -> MatState {
        let f = matFrame()
        return MatState(
            pattern: pattern, mode: mode, origin: f.origin, size: restSize,
            angle: f.angle, grid: [cols, rows], particles: MatState.encodeParticles(positions),
            keyboard: keyboardCenter
        )
    }

    /// Restores a saved mat with what it derives, in the one order that keeps its saved pose exactly: coverage
    /// (piles the saved cloth lies on, measured over the floor their own bumps make), then those bumps at once,
    /// then the cloth over them. With `keyboardSize` the keyboard is weighed again at its saved centre. `pileRadius`
    /// is the footprint radius the scene's coverage uses. Nil when the state is malformed.
    public static func restore(state: MatState, piles: [PileInput], pileRadius: Float = 6,
                               keyboardSize: SIMD2<Float>? = nil, params: ClothParams = .standard) -> RestoredMat? {
        guard var cloth = ClothSim(state: state, params: params) else { return nil }
        var index = ClothTriangleIndex(cloth)
        var covered = Set(piles.filter { index.clearance(at: $0.position) != nil }.map(\.id))
        var bumps = BumpField()
        for attempt in 0..<4 {
            bumps.setCoveredPiles(piles.filter { covered.contains($0.id) }, animated: false)
            guard let c = ClothSim(state: state, bumps: bumps, params: params) else { return nil }
            cloth = c
            index.update(cloth)
            var next = Set<Int>()
            for p in piles {
                let k = index.coveredSamples(CoveragePile(id: p.id, position: p.position, radius: pileRadius))
                if k >= 3 || (k == 2 && covered.contains(p.id)) { next.insert(p.id) }
            }
            if next == covered || attempt == 3 { break }
            covered = next
        }
        var coverage = CoverageTracker()
        for p in piles { coverage.setCovered(p.id, covered.contains(p.id)) }
        if let size = keyboardSize, let k = state.keyboard, k.isFinite {
            cloth.setKeyboard(DeskPlaneRect(x: k[0] - size.x / 2, d: k[1] - size.y / 2, width: size.x, depth: size.y))
            cloth.forceSleep()
        }
        return RestoredMat(cloth: cloth, bumps: bumps, coverage: coverage)
    }

    /// Restores the cloth alone (asleep) from its persisted form over `bumps`, which must already hold the bumps of
    /// the piles it covers (prefer `restore(state:piles:)`); nil when the state is malformed or has no particles yet.
    /// Positions are clamped to the desk bounds. Particles no saved mat could have (`isPlausible`: far off the desk,
    /// or a mesh torn apart or collapsed) are malformed too, so a damaged file lays a fresh mat, never a wreck.
    public init?(state: MatState, bumps: BumpField? = nil, params: ClothParams = .standard) {
        guard state.grid.count == 2, let particles = state.particles else { return nil }
        let cols = state.grid[0], rows = state.grid[1]
        guard cols >= 3, rows >= 3, cols <= 4096, rows <= 4096, cols * rows <= 4096,
              state.size[0].isFinite, state.size[1].isFinite, state.size[0] > 0, state.size[1] > 0,
              var pos = MatState.decodeParticles(particles, count: cols * rows),
              Self.isPlausible(pos, cols: cols, rows: rows, size: SIMD2(state.size[0], state.size[1]), params: params)
        else { return nil }
        for i in pos.indices {
            pos[i].x = min(max(pos[i].x, params.xRange.lowerBound), params.xRange.upperBound)
            pos[i].y = min(max(pos[i].y, params.dRange.lowerBound), params.dRange.upperBound)
            pos[i].z = min(max(pos[i].z, 0), params.zMax)
        }
        self.init(positions: pos, cols: cols, rows: rows, size: SIMD2(state.size[0], state.size[1]), bumps: bumps,
                  params: params)
    }

    /// Whether saved particle positions can be a mat: every one within 24 px of the desk bounds (z within the
    /// height limit), no grid edge stretched past 1.5× its rest length, and at most a quarter of them squeezed below
    /// half of it (folds and wrinkles squeeze a few; a collapsed mesh squeezes them all).
    static func isPlausible(_ pos: [SIMD3<Float>], cols: Int, rows: Int, size: SIMD2<Float>,
                            params: ClothParams) -> Bool {
        let slack: Float = 24, xr = params.xRange, dr = params.dRange
        for p in pos {
            guard p.x >= xr.lowerBound - slack, p.x <= xr.upperBound + slack, p.y >= dr.lowerBound - slack,
                  p.y <= dr.upperBound + slack, p.z >= -slack, p.z <= params.zMax + slack else { return false }
        }
        let su = size.x / Float(cols - 1), sv = size.y / Float(rows - 1)
        var squeezed = 0, edges = 0
        func check(_ a: Int, _ b: Int, _ rest: Float) -> Bool {
            let l = length3(pos[a] - pos[b])
            if l < rest / 2 { squeezed += 1 }
            edges += 1
            return l <= rest * 1.5 + 1
        }
        for r in 0..<rows {
            for c in 0..<cols {
                let i = r * cols + c
                if c + 1 < cols, !check(i, i + 1, su) { return false }
                if r + 1 < rows, !check(i, i + cols, sv) { return false }
            }
        }
        return squeezed * 4 <= edges
    }
}

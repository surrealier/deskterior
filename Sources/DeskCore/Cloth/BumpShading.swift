/// The bumps as the 2:1 view sees them (M9 review): the 6-px cloth mesh is far coarser than a small stack's bump (a
/// lone token's mound is 16 px across), so where felt rests on a bump the raster draws the bump itself. Each screen
/// column is marched front to back over the `BumpField` (felt at `H + 1`), which finds the desk point every pixel shows
/// and where the bump hides the felt behind it. Each bump then reads as one mound:
///
/// - the crest (the plateau) lit a level up, the left flank lit, the front slope felt-coloured and only the right flank
///   dark — whole levels, dithered only in a narrow band where one turns into the next;
/// - an unbroken 1-px outline along the back rim, where the mound stands against the felt behind it;
/// - a 1-px contact line along its front base.
///
/// Every pixel within a bump's reach is flagged (`region`): there the bump's light wins over the mesh's and the mesh
/// draws no creases, so the coarse triangles never show through as smudges, dashes or stalks. Rebuilt only when the
/// field changes (`revision`); pure and deterministic.
struct BumpShading {
    static let flat: Int32 = 2048
    /// Pixel flags: within a bump's reach; the back rim's outline; the front base's contact line.
    static let region: UInt8 = 1
    static let rim: UInt8 = 2
    static let contact: UInt8 = 4

    /// The felt counts as raised from this height (px).
    static let present: Float = 0.5
    /// The crest: at least this high, and flatter than `crestSlope`.
    static let crestHeight: Float = 1.5
    static let crestSlope: Float = 0.35
    /// Depth step of the column march (px).
    static let step: Float = 0.25
    /// The flagged region reaches this far (px) past the raised area: the mesh cell next to a bump still tilts.
    static let margin = 6
    /// Half-width of the dither band between two levels (levels · 1024 around the half-way point).
    static let ditherBand = 72

    /// Buffer rect the arrays cover (empty: no bumps).
    private(set) var rect = ArtRect.zero
    /// Whole shading level · 1024 per pixel of `rect` (row-major).
    private(set) var level: [Int32] = []
    private(set) var flags: [UInt8] = []
    private var revision: UInt64?

    init() {}

    /// The level and flags at buffer pixel `(x, y)`, nil outside every bump's reach.
    @inline(__always)
    func at(_ x: Int, _ y: Int) -> (level: Int32, flags: UInt8)? {
        guard x >= rect.minX, x < rect.maxX, y >= rect.minY, y < rect.maxY else { return nil }
        let i = (y - rect.minY) * rect.w + (x - rect.minX)
        let f = flags[i]
        return f == 0 ? nil : (level[i], f)
    }

    /// Recomputes from `bumps` (eased heights included) when the field changed; nil turns it off.
    mutating func update(_ bumps: BumpField?, projection proj: DeskProjection) {
        guard let bumps else {
            rect = .zero
            revision = nil
            return
        }
        guard bumps.revision != revision else { return }
        revision = bumps.revision
        let cols = BumpField.cols, rows = BumpField.rows, cell = BumpField.cell, o = BumpField.origin
        // Per node column, the raised node rows.
        var spans = [(lo: Int, hi: Int)?](repeating: nil, count: cols)
        bumps.heights.withUnsafeBufferPointer { H in
            for i in 0..<cols {
                var lo = Int.max, hi = Int.min
                for j in 0..<rows where H[j * cols + i] > 0.05 {
                    lo = min(lo, j)
                    hi = max(hi, j)
                }
                if lo <= hi { spans[i] = (lo, hi) }
            }
        }
        // Buffer columns and rows the raised area can reach on screen.
        let ox = DeskSurfaceRaster.origin.x, oy = Float(DeskSurfaceRaster.origin.y)
        let w = DeskSurfaceRaster.width, h = DeskSurfaceRaster.height
        var x0 = Int.max, x1 = Int.min, y0 = Int.max, y1 = Int.min
        var maxH: Float = 0
        bumps.heights.withUnsafeBufferPointer { H in for v in H where v > maxH { maxH = v } }
        let m = Self.margin, mf = Float(Self.margin)
        for (i, s) in spans.enumerated() {
            guard let s else { continue }
            let x = o.x + Float(i) * cell
            x0 = min(x0, Int((x - mf).rounded(.down)) - ox)
            x1 = max(x1, Int((x + mf).rounded(.up)) - ox)
            let dLo = o.y + Float(s.lo) * cell - mf, dHi = o.y + Float(s.hi) * cell + mf
            y0 = min(y0, Int((proj.frontY - dHi * proj.k - 1 - maxH - oy).rounded(.down)) - 1)
            y1 = max(y1, Int((proj.frontY - dLo * proj.k - 1 - oy).rounded(.up)) + 1)
        }
        x0 = max(x0, 0)
        x1 = min(x1, w - 1)
        y0 = max(y0, 0)
        y1 = min(y1, h - 1)
        guard x0 <= x1, y0 <= y1 else {
            rect = .zero
            return
        }
        rect = ArtRect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
        let rw = rect.w, n = rw * rect.h
        if level.count < n {
            level = Array(repeating: Self.flat, count: n)
            flags = Array(repeating: 0, count: n)
        }
        // What each pixel shows: its height, slope and whether it lies just behind a bump that hides felt.
        var height = [Float](repeating: 0, count: n)
        var behind = [Bool](repeating: false, count: n)
        var seen = [Bool](repeating: false, count: n)
        bumps.withSampler { S in
            level.withUnsafeMutableBufferPointer { L in
                flags.withUnsafeMutableBufferPointer { F in
                    for k in 0..<n {
                        L[k] = Self.flat
                        F[k] = 0
                    }
                    for bx in x0...x1 {
                        let x = Float(bx + ox) + 0.5
                        // The raised span under this column (the two node columns around it), with a margin.
                        let gi = Int(((x - o.x) / cell).rounded(.down)), reach = m / Int(cell)
                        var lo = Int.max, hi = Int.min
                        for i in (gi - reach)...(gi + 1 + reach) where i >= 0 && i < cols {
                            if let s = spans[i] {
                                lo = min(lo, s.lo)
                                hi = max(hi, s.hi)
                            }
                        }
                        guard lo <= hi else { continue }
                        let dStart = o.y + Float(lo) * cell - mf, dEnd = o.y + Float(hi) * cell + mf
                        func screenY(_ d: Float, _ z: Float) -> Float { proj.frontY - d * proj.k - 1 - z - oy }
                        var next = Int((screenY(dStart, S.height(x, dStart)) - 0.5).rounded(.up)) - 1
                        var horizon = Float.infinity
                        var hidden = false
                        var d = dStart
                        while d <= dEnd && next >= y0 {
                            let z = S.height(x, d)
                            let y = screenY(d, z)
                            if y > horizon + 0.01 { hidden = true }
                            horizon = min(horizon, y)
                            while next >= y0 && Float(next) + 0.5 >= y {
                                if next <= y1 {
                                    let k = (next - y0) * rw + (bx - x0)
                                    height[k] = z
                                    behind[k] = hidden
                                    seen[k] = true
                                    F[k] = Self.region
                                    // The slope at what this pixel shows (central differences over 1 px).
                                    let hx = (S.height(x + 1, d) - S.height(x - 1, d)) / 2
                                    let hd = (S.height(x, d + 1) - S.height(x, d - 1)) / 2
                                    L[k] = z < Self.present ? Self.flat
                                        : Self.shade(z, hx, hd, x: bx + ox, y: next + Int(oy))
                                }
                                hidden = false
                                next -= 1
                            }
                            d += Self.step
                        }
                    }
                    // Outlines: the back rim (raised, under a pixel that is not, or that shows felt the bump hides
                    // behind it), joined up column to column; the contact line under the front base.
                    let present = Self.present
                    var rimRow = [Int](repeating: -1, count: rw)
                    for c in 0..<rw {
                        for r in 0..<rect.h {
                            let k = r * rw + c
                            guard seen[k], height[k] >= present else { continue }
                            let up = r > 0 ? k - rw : -1
                            if up < 0 || !seen[up] || height[up] < present || behind[up] {
                                F[k] |= Self.rim
                                if rimRow[c] < 0 { rimRow[c] = r }
                            }
                            let down = r + 1 < rect.h ? k + rw : -1
                            if down >= 0, seen[down], height[down] < present, !behind[k] {
                                F[down] |= Self.contact
                                L[down] = 1024
                            }
                        }
                    }
                    // Steps of more than a pixel between neighbouring columns' rims are closed down the higher column.
                    for c in 0..<rw where rimRow[c] >= 0 {
                        var bottom = rimRow[c]
                        for nc in [c - 1, c + 1] where nc >= 0 && nc < rw && rimRow[nc] >= 0 {
                            bottom = max(bottom, rimRow[nc] - 1)
                        }
                        guard bottom > rimRow[c] else { continue }
                        for r in (rimRow[c] + 1)...bottom {
                            let k = r * rw + c
                            guard seen[k], height[k] >= present else { break }
                            F[k] |= Self.rim
                        }
                    }
                }
            }
        }
    }

    /// The whole level (· 1024) of felt at height `z` with slope `(hx, hd)`, at absolute art pixel `(x, y)`: lit by
    /// the raster's light, a level up on the crest, rounded to a whole level except in a narrow Bayer band.
    @inline(__always)
    static func shade(_ z: Float, _ hx: Float, _ hd: Float, x: Int, y: Int) -> Int32 {
        let len = (hx * hx + hd * hd + 1).squareRoot()
        var l = Int(DeskSurfaceRaster.shadeLevel(-hx / len, -hd / len, 1 / len))
        if z >= crestHeight && hx * hx + hd * hd < crestSlope * crestSlope { l += 1024 }
        l = min(max(l, 0), 4 * 1024 + 1023)
        let whole = l >> 10, frac = (l & 1023) - 512
        var up = frac >= 0
        if abs(frac) < ditherBand {
            let ramp16 = (frac + ditherBand) * 16 / (2 * ditherBand)
            up = Dither.bayer4(x: x, y: y) < ramp16
        }
        return Int32((whole + (up ? 1 : 0)) << 10)
    }
}

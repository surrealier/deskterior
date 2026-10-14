/// Per-pixel light for felt lying on the bumps (M9): the 6-px cloth mesh is far coarser than a small stack's bump
/// (a lone token's mound is 16 px across), so felt resting on a bump takes its shading from the bump field's own
/// slope instead of the mesh's. A grid of shading levels (the raster's `light`, levels · 1024, flat = 2048) over the
/// `BumpField` nodes, filled only where the field is raised and sampled bilinearly in integers, so the raster stays
/// bit-exact.
struct BumpShading {
    static let flat: Int32 = 2048

    /// Shading level per bump node (`BumpField.cols × rows`); flat outside `box`.
    private(set) var light: [Int32]
    /// The nodes filled by the last update (inclusive), nil when the field is flat.
    private(set) var box: (i0: Int, i1: Int, j0: Int, j1: Int)?

    init() {
        light = Array(repeating: Self.flat, count: BumpField.cols * BumpField.rows)
    }

    /// Recomputes the grid from `bumps` (eased heights included); nil or a flat field turns it off.
    mutating func update(_ bumps: BumpField?) {
        let cols = BumpField.cols, rows = BumpField.rows
        if let b = box {
            light.withUnsafeMutableBufferPointer { L in
                for j in b.j0...b.j1 { for i in b.i0...b.i1 { L[j * cols + i] = Self.flat } }
            }
            box = nil
        }
        guard let bumps else { return }
        var i0 = Int.max, i1 = Int.min, j0 = Int.max, j1 = Int.min
        bumps.heights.withUnsafeBufferPointer { H in
            for j in 0..<rows {
                for i in 0..<cols where H[j * cols + i] > 0 {
                    i0 = min(i0, i)
                    i1 = max(i1, i)
                    j0 = min(j0, j)
                    j1 = max(j1, j)
                }
            }
        }
        guard i0 <= i1 else { return }
        // One node of margin: the slope is felt a node beyond the last raised one.
        let b = (i0: max(i0 - 1, 0), i1: min(i1 + 1, cols - 1), j0: max(j0 - 1, 0), j1: min(j1 + 1, rows - 1))
        let inv = 1 / (2 * BumpField.cell)
        bumps.heights.withUnsafeBufferPointer { H in
            light.withUnsafeMutableBufferPointer { L in
                for j in b.j0...b.j1 {
                    let jm = max(j - 1, 0) * cols, jp = min(j + 1, rows - 1) * cols, row = j * cols
                    for i in b.i0...b.i1 {
                        let hx = (H[row + min(i + 1, cols - 1)] - H[row + max(i - 1, 0)]) * inv
                        let hd = (H[jp + i] - H[jm + i]) * inv
                        // The surface z = H(x, d) has normal (−∂H/∂x, −∂H/∂d, 1).
                        let len = (hx * hx + hd * hd + 1).squareRoot()
                        L[row + i] = DeskSurfaceRaster.shadeLevel(-hx / len, -hd / len, 1 / len)
                    }
                }
            }
        }
        box = b
    }

    /// The level at desk point `(x, d)` given in 1/16 px, or nil off the filled nodes.
    @inline(__always)
    func sample(x16: Int, d16: Int) -> Int32? {
        guard let b = box else { return nil }
        // Node coordinates in 1/16 node (2 px per node, so halve; origin x 12, d 0).
        let gx = (x16 - Int(BumpField.origin.x) * 16) >> 1
        let gd = (d16 - Int(BumpField.origin.y) * 16) >> 1
        let i = gx >> 4, j = gd >> 4
        guard i >= b.i0, i < b.i1, j >= b.j0, j < b.j1 else { return nil }
        let fx = gx & 15, fd = gd & 15, cols = BumpField.cols
        let k = j * cols + i
        let l00 = Int(light[k]), l10 = Int(light[k + 1]), l01 = Int(light[k + cols]), l11 = Int(light[k + cols + 1])
        let top = l00 * (16 - fx) + l10 * fx, bottom = l01 * (16 - fx) + l11 * fx
        return Int32((top * (16 - fd) + bottom * fd) >> 8)
    }
}

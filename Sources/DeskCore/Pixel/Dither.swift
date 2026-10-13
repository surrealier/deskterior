/// Ordered dithering with the 4×4 Bayer matrix.
///
/// Every function takes **absolute art coordinates** (not sprite-local ones), so patterns line up
/// across adjacent objects and across sub-canvases placed at different origins. Negative coordinates
/// wrap exactly like positive ones (the pattern tiles the whole plane).
///
/// `cell` coarsens the pattern: with `cell: 2` each threshold covers a 2×2 block, which survives the
/// resampling of scaled display modes better than a 1-px checker on large flat areas (DESIGN §1.2).
public enum Dither {
    /// The standard 4×4 Bayer index matrix, `bayer4Matrix[y][x]`, values 0…15.
    public static let bayer4Matrix: [[Int]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
    ]

    private static let flat: [Int] = bayer4Matrix.flatMap { $0 }

    /// Bayer index (0…15) at absolute art coordinates.
    public static func bayer4(x: Int, y: Int) -> Int {
        flat[(y & 3) << 2 | (x & 3)]
    }

    /// Threshold in `(0, 1)`: `(bayer4 + 0.5) / 16`, at absolute art coordinates.
    public static func threshold(x: Int, y: Int, cell: Int = 1) -> Double {
        (Double(bayer4(x: floorDiv(x, cell), y: floorDiv(y, cell))) + 0.5) / 16
    }

    /// Whether the pixel at absolute `(x, y)` takes the **second** colour of a two-colour mix that is
    /// `fraction` second colour. `fraction <= 0` never picks it, `>= 1` always does, and `k/16` picks
    /// exactly `k` pixels of every 4×4 window.
    public static func pick(x: Int, y: Int, fraction: Double, cell: Int = 1) -> Bool {
        fraction > threshold(x: x, y: y, cell: cell)
    }

    /// Integer form of `pick(x:y:fraction:)`: true for `sixteenths` of every 4×4 window (0…16).
    public static func pick(x: Int, y: Int, sixteenths: Int, cell: Int = 1) -> Bool {
        bayer4(x: floorDiv(x, cell), y: floorDiv(y, cell)) < sixteenths
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        precondition(b >= 1, "dither cell must be >= 1")
        if b == 1 { return a }
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }
}

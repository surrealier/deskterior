import Foundation

/// A colour in Björn Ottosson's OKLab space (https://bottosson.github.io/posts/oklab/).
///
/// `L` is perceptual lightness (0 = black, ≈1 = white); `a` (green→red) and `b` (blue→yellow) are the
/// opponent axes. Euclidean distance approximates perceived colour difference, so palette snapping,
/// light ramps and quantization all measure in this space.
public struct OKLab: Sendable, Equatable, CustomStringConvertible {
    public var L: Double
    public var a: Double
    public var b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }

    /// Converts an 8-bit sRGB colour (alpha is ignored).
    public init(_ c: RGBA8) {
        let t = OKLab.srgb8ToLinear
        self.init(linearR: t[Int(c.r)], g: t[Int(c.g)], b: t[Int(c.b)])
    }

    /// Converts linear-light sRGB components (nominally 0…1).
    public init(linearR r: Double, g: Double, b: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// Linear-light sRGB components; may fall outside 0…1 for out-of-gamut colours.
    public var linearSRGB: (r: Double, g: Double, b: Double) {
        let l1 = L + 0.3963377774 * a + 0.2158037573 * b
        let m1 = L - 0.1055613458 * a - 0.0638541728 * b
        let s1 = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l1 * l1 * l1, m = m1 * m1 * m1, s = s1 * s1 * s1
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// The nearest opaque 8-bit sRGB colour (channels clamped to the gamut, then rounded).
    public var rgba8: RGBA8 {
        let lin = linearSRGB
        return RGBA8(OKLab.encode8(lin.r), OKLab.encode8(lin.g), OKLab.encode8(lin.b))
    }

    /// Chroma (distance from the neutral axis).
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// Squared Euclidean distance; cheaper when only comparing.
    @inlinable
    public func distanceSquared(to o: OKLab) -> Double {
        let dL = L - o.L, da = a - o.a, db = b - o.b
        return dL * dL + da * da + db * db
    }

    /// Euclidean distance (ΔE_OK).
    @inlinable
    public func distance(to o: OKLab) -> Double { distanceSquared(to: o).squareRoot() }

    public var description: String {
        String(format: "OKLab(%.4f, %.4f, %.4f)", L, a, b)
    }

    // MARK: sRGB transfer

    /// sRGB decoding: encoded 0…1 → linear 0…1.
    public static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// sRGB encoding: linear 0…1 → encoded 0…1.
    public static func linearToSRGB(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Linear value of each 8-bit encoded level (256 entries).
    public static let srgb8ToLinear: [Double] = (0..<256).map { srgbToLinear(Double($0) / 255) }

    /// Encodes a linear value to an 8-bit level, clamping to 0…255.
    public static func encode8(_ linear: Double) -> UInt8 {
        let v = linearToSRGB(min(max(linear, 0), 1)) * 255
        return UInt8(min(max(v.rounded(), 0), 255))
    }
}

extension Apollo {
    /// `colors` in OKLab; `oklab[i]` is palette index `i`.
    public static let oklab: [OKLab] = colors.map { OKLab($0) }

    /// Nearest palette index (OKLab) to an sRGB colour; alpha is ignored. Exact Apollo colours map to
    /// themselves.
    public static func nearestIndex(to c: RGBA8) -> Int {
        if let i = index(of: RGBA8(c.r, c.g, c.b, 255)) { return i }
        return nearestIndex(to: OKLab(c))
    }

    /// Nearest palette index (OKLab) among `candidates` (default: the whole palette). Ties go to the
    /// lowest index, so the result is deterministic.
    public static func nearestIndex(to lab: OKLab, among candidates: [Int]? = nil) -> Int {
        nearestTwo(to: lab, among: candidates).first
    }

    /// The two nearest palette indices among `candidates` with their squared distances. With a single
    /// candidate, `second` repeats `first`. Ties go to the lowest index.
    static func nearestTwo(to lab: OKLab, among candidates: [Int]? = nil)
        -> (first: Int, d0: Double, second: Int, d1: Double)
    {
        var i0 = -1, i1 = -1
        var d0 = Double.infinity, d1 = Double.infinity
        func consider(_ i: Int) {
            precondition(i >= 0 && i < count, "palette index out of range: \(i)")
            let d = lab.distanceSquared(to: oklab[i])
            if d < d0 || (d == d0 && i < i0) {
                if i0 >= 0 && i0 != i { (i1, d1) = (i0, d0) }
                (i0, d0) = (i, d)
            } else if i != i0 && (d < d1 || (d == d1 && i < i1)) {
                (i1, d1) = (i, d)
            }
        }
        if let candidates {
            precondition(!candidates.isEmpty, "nearestIndex needs at least one candidate")
            for i in candidates { consider(i) }
        } else {
            for i in 0..<count { consider(i) }
        }
        if i1 < 0 { (i1, d1) = (i0, d0) }
        return (i0, d0, i1, d1)
    }
}

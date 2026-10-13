/// An 8-bit-per-channel colour, laid out in memory as R, G, B, A (4 bytes, no padding).
///
/// Art rule: alpha is **binary** (0 or 255). A transparent pixel is always `.clear` (all zero) so the
/// same bytes are valid as premultiplied RGBA for CoreGraphics / Metal.
@frozen
public struct RGBA8: Hashable, Sendable, Codable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    @inlinable
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `0xRRGGBB`, opaque.
    @inlinable
    public init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF), 255)
    }

    /// Parses `"rrggbb"` or `"#rrggbb"`; returns nil on malformed input.
    public init?(hexString: String) {
        var s = Substring(hexString)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    public static let clear = RGBA8(0, 0, 0, 0)
    public static let black = RGBA8(0, 0, 0)
    public static let white = RGBA8(255, 255, 255)

    @inlinable public var isOpaque: Bool { a == 255 }
    @inlinable public var isTransparent: Bool { a == 0 }

    /// `0xRRGGBB` (alpha dropped).
    @inlinable public var rgbHex: UInt32 { (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b) }

    public var hexString: String {
        let s = String(rgbHex, radix: 16)
        return String(repeating: "0", count: 6 - s.count) + s
    }

    public var description: String { a == 255 ? "#\(hexString)" : "#\(hexString)@\(a)" }
}

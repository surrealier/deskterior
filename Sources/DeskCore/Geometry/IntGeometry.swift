// Integer art-space geometry.
//
// CONVENTION (whole project): art space is integer pixels, **y-down**, origin top-left — the same
// orientation as PixelBuffer rows and PNG files. SpriteKit (y-up) conversion happens only in DeskScene.

/// A point in art pixels (y-down).
public struct ArtPoint: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Int
    public var y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    public static let zero = ArtPoint(0, 0)

    public static func + (a: ArtPoint, b: ArtPoint) -> ArtPoint { ArtPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: ArtPoint, b: ArtPoint) -> ArtPoint { ArtPoint(a.x - b.x, a.y - b.y) }

    public var description: String { "(\(x),\(y))" }
}

/// A size in art pixels.
public struct ArtSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var w: Int
    public var h: Int

    public init(_ w: Int, _ h: Int) {
        self.w = w
        self.h = h
    }

    public static let zero = ArtSize(0, 0)
    public var area: Int { max(0, w) * max(0, h) }
    public var description: String { "\(w)x\(h)" }
}

/// An axis-aligned rectangle in art pixels (y-down). `maxX`/`maxY` are exclusive.
public struct ArtRect: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public init(origin: ArtPoint, size: ArtSize) {
        self.init(origin.x, origin.y, size.w, size.h)
    }

    public static let zero = ArtRect(0, 0, 0, 0)

    public var origin: ArtPoint { ArtPoint(x, y) }
    public var size: ArtSize { ArtSize(w, h) }
    public var minX: Int { x }
    public var minY: Int { y }
    /// Exclusive.
    public var maxX: Int { x + w }
    /// Exclusive.
    public var maxY: Int { y + h }
    public var midX: Int { x + w / 2 }
    public var midY: Int { y + h / 2 }
    public var center: ArtPoint { ArtPoint(midX, midY) }
    public var isEmpty: Bool { w <= 0 || h <= 0 }

    public func contains(_ p: ArtPoint) -> Bool {
        p.x >= x && p.x < maxX && p.y >= y && p.y < maxY
    }

    public func contains(_ r: ArtRect) -> Bool {
        !r.isEmpty && r.x >= x && r.y >= y && r.maxX <= maxX && r.maxY <= maxY
    }

    public func intersects(_ r: ArtRect) -> Bool {
        !intersection(r).isEmpty
    }

    /// Returns `.zero`-sized rect (at the clamped origin) when there is no overlap.
    public func intersection(_ r: ArtRect) -> ArtRect {
        let nx = max(x, r.x), ny = max(y, r.y)
        let mx = min(maxX, r.maxX), my = min(maxY, r.maxY)
        if mx <= nx || my <= ny { return ArtRect(nx, ny, 0, 0) }
        return ArtRect(nx, ny, mx - nx, my - ny)
    }

    public func union(_ r: ArtRect) -> ArtRect {
        if isEmpty { return r }
        if r.isEmpty { return self }
        let nx = min(x, r.x), ny = min(y, r.y)
        return ArtRect(nx, ny, max(maxX, r.maxX) - nx, max(maxY, r.maxY) - ny)
    }

    public func offsetBy(_ dx: Int, _ dy: Int) -> ArtRect { ArtRect(x + dx, y + dy, w, h) }

    /// Positive insets shrink the rect on every side.
    public func insetBy(_ dx: Int, _ dy: Int) -> ArtRect { ArtRect(x + dx, y + dy, w - 2 * dx, h - 2 * dy) }

    /// Converts this y-down rect to y-up coordinates inside a canvas of the given height.
    public func flippedY(canvasHeight: Int) -> ArtRect { ArtRect(x, canvasHeight - maxY, w, h) }

    public var description: String { "[\(x),\(y) \(w)x\(h)]" }
}

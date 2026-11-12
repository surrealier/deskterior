/// One textured rectangle of a scene, flattened for `SoftRaster` (docs/WINDOWS.md, WP2).
public struct DrawItem: Sendable {
    /// The rectangle in scene units (y up, `SoftRaster.unitsPerPixel` units per art px); may be fractional.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// The texture, row 0 = top. Binary alpha: 0 skips, 255 covers.
    public var pixels: PixelBuffer
    /// Accumulated z (the node's `zPosition` plus its ancestors').
    public var z: Double
    /// Depth-first visit order: a parent before its children, siblings in array order.
    public var order: Int

    public init(x: Double, y: Double, width: Double, height: Double, pixels: PixelBuffer, z: Double, order: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixels = pixels
        self.z = z
        self.order = order
    }
}

/// The art pass without a GPU: draws a scene's flattened sprites into an art-size buffer the way SpriteKit's
/// renderer does for Deskterior's scenes (`SoftRasterParityTests` compares the two on macOS).
///
/// - Order: by accumulated z, then depth-first order (`SKView.ignoresSiblingOrder = false`).
/// - Coverage: a pixel is drawn when its centre lies inside the rectangle, left and top edges included.
/// - Sampling: nearest texel at the pixel centre, clamped to the texture.
/// - Blending: binary alpha, so a texel is copied (alpha 255) or skipped (alpha 0); nothing else occurs in
///   Deskterior's art (DESIGN §1.1), and partial alpha is treated as opaque when at least half.
public enum SoftRaster {
    public static let unitsPerPixel = 4.0

    /// A `canvas`-size opaque frame: `clear` everywhere, then `items` drawn in order.
    public static func composite(_ items: [DrawItem], canvas: ArtSize, clear: RGBA8) -> PixelBuffer {
        var out = PixelBuffer(width: canvas.w, height: canvas.h, fill: clear)
        draw(items, into: &out)
        return out
    }

    /// Clears `out` to `clear`, then draws `items` (reuses `out`'s storage).
    public static func composite(_ items: [DrawItem], clear: RGBA8, into out: inout PixelBuffer) {
        out.fillAll(clear)
        draw(items, into: &out)
    }

    /// Draws `items` over what `out` holds.
    public static func draw(_ items: [DrawItem], into out: inout PixelBuffer) {
        let sorted = items.sorted { $0.z != $1.z ? $0.z < $1.z : $0.order < $1.order }
        let canvasH = Double(out.height)
        let w = out.width, h = out.height
        out.withUnsafeMutablePixels { dst in
            for item in sorted {
                let tex = item.pixels
                guard tex.width > 0, tex.height > 0, item.width > 0, item.height > 0 else { continue }
                // Scene rectangle → art pixels, y down.
                let ax0 = item.x / unitsPerPixel, ax1 = (item.x + item.width) / unitsPerPixel
                let ay0 = canvasH - (item.y + item.height) / unitsPerPixel, ay1 = canvasH - item.y / unitsPerPixel
                // Pixels whose centre is inside: first = ceil(edge − 0.5); the far edge is exclusive.
                let px0 = max(0, Int((ax0 - 0.5).rounded(.up))), px1 = min(w, Int((ax1 - 0.5).rounded(.up)))
                let py0 = max(0, Int((ay0 - 0.5).rounded(.up))), py1 = min(h, Int((ay1 - 0.5).rounded(.up)))
                guard px0 < px1, py0 < py1 else { continue }
                let tw = tex.width, th = tex.height
                let sx = Double(tw) / (ax1 - ax0), sy = Double(th) / (ay1 - ay0)
                // A rectangle on the pixel grid at its texture's size: a straight copy.
                let aligned = ax0 == ax0.rounded() && ay0 == ay0.rounded() && sx == 1 && sy == 1
                tex.withUnsafePixels { src in
                    if aligned {
                        let ox = Int(ax0), oy = Int(ay0)
                        for py in py0..<py1 {
                            let srow = (py - oy) * tw - ox, drow = py * w
                            for px in px0..<px1 {
                                let c = src[srow + px]
                                if c.a >= 128 { dst[drow + px] = c }
                            }
                        }
                        return
                    }
                    if tw == 1 && th == 1 {
                        let c = src[0]
                        guard c.a >= 128 else { return }
                        for py in py0..<py1 {
                            for px in px0..<px1 { dst[py * w + px] = c }
                        }
                        return
                    }
                    var columns = [Int](repeating: 0, count: px1 - px0)
                    for px in px0..<px1 {
                        columns[px - px0] = min(tw - 1, max(0, Int(((Double(px) + 0.5 - ax0) * sx).rounded(.down))))
                    }
                    for py in py0..<py1 {
                        let v = min(th - 1, max(0, Int(((Double(py) + 0.5 - ay0) * sy).rounded(.down))))
                        let srow = v * tw, drow = py * w
                        for px in px0..<px1 {
                            let c = src[srow + columns[px - px0]]
                            if c.a >= 128 { dst[drow + px] = c }
                        }
                    }
                }
            }
        }
    }
}

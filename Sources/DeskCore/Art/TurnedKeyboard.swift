import Foundation

/// The keyboard as it lies on a turned desk mat (Errata 26): `PropArt.keyboard()`'s top face turned in the desk plane
/// and seen in the 2:1 view, then given its sides again.
///
/// In the view a turn by θ is the area-preserving map (x, y) → (x cos θ + 2y sin θ, −x sin θ / 2 + y cos θ) of the top
/// face. Every view pixel inside the turned face takes the face pixel its centre maps back onto (nearest neighbour):
/// at the turns a mat takes, each step across the view moves less than a pixel across the face, so no key, gap or row
/// is skipped (a few draw a pixel wider), and the key rows and gaps stay regular stairs; a spur pixel off the outline
/// is dropped. The sides are the face's lowest pixel in each column extruded two rows down (the front's greys under the
/// front edge, darker under an end), with the status LED on the front. Past ±90° the keyboard shows its far side: the
/// face is spun half round and turned the rest of the way.
public struct TurnedKeyboard: Equatable, Sendable {
    /// The turn drawn, in whole degrees (counterclockwise seen from above: the right end goes back).
    public let degrees: Int
    public let image: PixelBuffer
    /// The image's top-left relative to the upright sprite's: the top face keeps its centre.
    public let offset: ArtPoint
    /// For each image pixel, the upright sprite's pixel the top face shows there (`y · width + x`), or −1.
    public let source: [Int32]

    /// The key drawn at image-local `p` (`PropArt.keyboardKey` of the pixel the face shows there), if any.
    public func key(at p: ArtPoint) -> (row: Int, col: Int)? {
        guard image.inBounds(p.x, p.y) else { return nil }
        let s = Int(source[p.y * image.width + p.x])
        guard s >= 0 else { return nil }
        let w = CoreLayout.keyboard.w
        return PropArt.keyboardKey(at: ArtPoint(s % w, s / w))
    }

    /// Rows of `PropArt.keyboard()` that are its top face (the rest is its front).
    public static let faceRows = 12
    /// The face's fixed point: the pixel that stays put as it turns.
    static let centre = ArtPoint(CoreLayout.keyboard.w / 2, faceRows / 2)

    /// `upright` (a `PropArt.keyboard` image) turned by `degrees`; 0 gives the sprite itself.
    public init(_ upright: PixelBuffer, degrees: Int) {
        let d = ((degrees % 360) + 540) % 360 - 180
        self.degrees = d
        let w = upright.width
        guard d != 0 else {
            image = upright
            offset = .zero
            source = (0..<(upright.width * upright.height)).map { Int32($0) }
            return
        }
        var theta = Double(d) * .pi / 180
        // Past a quarter turn the face is spun half round first (its far side toward the viewer).
        let spun = abs(theta) > .pi / 2
        if spun { theta -= theta > 0 ? .pi : -.pi }
        let cs = cos(theta), sn = sin(theta)
        let c = Self.centre
        // The face's corners in the view, then every view pixel inside them sampled back onto the face (nearest).
        var xs: [Double] = [], ys: [Double] = []
        for (u, v) in [(-c.x, -c.y), (w - c.x, -c.y), (-c.x, Self.faceRows - c.y), (w - c.x, Self.faceRows - c.y)] {
            let du = Double(u), dv = Double(v)
            xs.append(du * cs + 2 * dv * sn)
            ys.append(-du * sn / 2 + dv * cs)
        }
        let x0 = Int(xs.min()!.rounded(.down)), x1 = Int(xs.max()!.rounded(.up))
        let y0 = Int(ys.min()!.rounded(.down)), y1 = Int(ys.max()!.rounded(.up))
        var faces: [(p: ArtPoint, s: Int32, ink: RGBA8)] = []
        for vy in y0..<y1 {
            for vx in x0..<x1 {
                let X = Double(vx) + 0.5, Y = Double(vy) + 0.5
                var u = X * cs - 2 * Y * sn, v = X * sn / 2 + Y * cs
                if spun { (u, v) = (-u, -v) }
                let sx = Int((u + Double(c.x)).rounded(.down)), sy = Int((v + Double(c.y)).rounded(.down))
                guard sx >= 0, sy >= 0, sx < w, sy < Self.faceRows, upright[sx, sy].a != 0 else { continue }
                faces.append((ArtPoint(vx, vy), Int32(sy * w + sx), upright[sx, sy]))
            }
        }
        // A face pixel touching the face on one side only is a spur off its outline (a corner the sampling clipped
        // to a single pixel): it goes, so the outline stays a clean stair.
        let filled = Set(faces.map(\.p))
        faces.removeAll { f in
            let n = [ArtPoint(1, 0), ArtPoint(-1, 0), ArtPoint(0, 1), ArtPoint(0, -1)].filter { filled.contains(f.p + $0) }
            return n.count <= 1
        }
        let minX = faces.map(\.p.x).min()!, maxX = faces.map(\.p.x).max()!
        let minY = faces.map(\.p.y).min()!, maxY = faces.map(\.p.y).max()!
        let side = upright.height - Self.faceRows
        var out = PixelBuffer(width: maxX - minX + 1, height: maxY - minY + 1 + side)
        var src = [Int32](repeating: -1, count: out.width * out.height)
        // The lowest face pixel in each column and the face row it shows.
        var lowest = [Int](repeating: -1, count: out.width), lowestRow = [Int](repeating: 0, count: out.width)
        for f in faces {
            let x = f.p.x - minX, y = f.p.y - minY
            out[x, y] = f.ink
            src[y * out.width + x] = f.s
            if y > lowest[x] {
                lowest[x] = y
                lowestRow[x] = Int(f.s) / w
            }
        }
        // The sides: under the front edge the front's greys, under an end the shaded end; the LED on the front.
        let front = spun ? 0 : Self.faceRows - 1
        let led = spun ? nil : faces.first { Int($0.s) == front * w + w - 6 }.map { $0.p.x - minX }
        let columns = lowest.indices.filter { lowest[$0] >= 0 }
        for x in columns where side > 0 {
            let underFront = lowestRow[x] == front
            let inks: [Ink] = underFront ? [.neutral5, .neutral3] : [.neutral4, .neutral3]
            for k in 0..<side where k < inks.count {
                // The bottom row rounds off at the keyboard's two ends, as the upright sprite's does.
                if k == side - 1, x == columns.first || x == columns.last { continue }
                out[x, lowest[x] + 1 + k] = inks[k].color
            }
            if x == led { out[x, lowest[x] + side] = Ink.green4.color }
        }
        image = out
        offset = ArtPoint(minX + c.x, minY + c.y)
        source = src
    }
}

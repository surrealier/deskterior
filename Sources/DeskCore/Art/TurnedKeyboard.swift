import Foundation

/// The keyboard as it lies on a turned desk mat (Errata 26): `PropArt.keyboard()`'s top face turned in the desk
/// plane and seen in the 2:1 view, with its sides.
///
/// In the view a turn by θ maps the face as (x, y) → (x cos θ + 2y sin θ, −x sin θ / 2 + y cos θ). At the turns a
/// mat takes (up to `bandedWithin`) the keyboard is rebuilt from bands, one per key row (the back edge with the
/// first, the front with the last): each band slides sideways as the turn shears it, its keys, gaps and margins keep
/// their upright columns (squeezed by cos θ, never a gap), and each piece sits on the slope as a whole, so the stairs
/// fall between keys and every key keeps its cap, face and side rows; a key wide enough to rise a pixel or more along
/// it follows the slope column by column, its rows stepping together, never within two columns of its ends. Where two
/// bands' stairs miss by a row, the row above keeps its side and a row left open fills from below, so the rows
/// between keys stay one pixel. Under an end the turn brings forward, the end's side shows two rows deep. Further
/// round the face is sampled back pixel by pixel (nearest neighbour; past ±90° the face is spun half round first).
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
        let banded = !spun && abs(d) <= Self.bandedWithin
        let placed = banded ? Self.banded(upright, theta) : Self.sampled(upright, theta, spun: spun)
        // The sides: under an end the turn brings forward, the end's shaded side two rows deep (the banded front
        // already has its own); the sampled face also gets the front's greys and the LED.
        let w = upright.width
        let side = upright.height - Self.faceRows
        let minX = placed.keys.map(\.x).min()!, maxX = placed.keys.map(\.x).max()!
        let minY = placed.keys.map(\.y).min()!, maxY = placed.keys.map(\.y).max()!
        var out = PixelBuffer(width: maxX - minX + 1, height: maxY - minY + 1 + side)
        var src = [Int32](repeating: -1, count: out.width * out.height)
        var lowest = [Int](repeating: -1, count: out.width), lowestRow = [Int](repeating: 0, count: out.width)
        for (p, f) in placed {
            let x = p.x - minX, y = p.y - minY
            out[x, y] = f.ink
            src[y * out.width + x] = f.s
            if y > lowest[x] {
                lowest[x] = y
                lowestRow[x] = f.s >= 0 ? Int(f.s) / w : 0
            }
        }
        let front = spun ? 0 : Self.faceRows - 1
        let led = spun ? nil : placed.first { Int($0.value.s) == front * w + w - 6 }.map { $0.key.x - minX }
        let columns = lowest.indices.filter { lowest[$0] >= 0 }
        let ends = banded ? Self.bands[3].lowerBound : Self.faceRows
        for x in columns where side > 0 && lowestRow[x] < ends {
            let underFront = lowestRow[x] == front
            let inks: [Ink] = underFront ? [.neutral5, .neutral3] : [.neutral4, .neutral3]
            for k in 0..<side where k < inks.count {
                // The bottom row rounds off at the keyboard's two ends, as the upright sprite's does.
                if k == side - 1, x == columns.first || x == columns.last { continue }
                out[x, lowest[x] + 1 + k] = inks[k].color
            }
            if x == led { out[x, lowest[x] + side] = Ink.green4.color }
        }
        // Trim rows nothing reached.
        var rows = out.height
        while rows > 1, (0..<out.width).allSatisfy({ out[$0, rows - 1].a == 0 }) { rows -= 1 }
        let c = Self.centre
        image = out.cropped(to: ArtRect(0, 0, out.width, rows))
        offset = ArtPoint(minX + c.x, minY + c.y)
        source = Array(src[0..<(out.width * rows)])
    }

    /// A view pixel of the turned face: its ink and the upright pixel it shows (`y · width + x`, −1 for none).
    typealias Placed = [ArtPoint: (ink: RGBA8, s: Int32)]

    /// Turns up to this many degrees (either way) are built from bands; further round the face is sampled.
    public static let bandedWithin = 30

    /// The face rows of each band: a key row, the back edge with the first and the front with the last.
    static let bands: [Range<Int>] = [0..<4, 4..<7, 7..<10, 10..<14]

    /// One band's run of pieces left to right: the margins, the keys and the 1-px gaps between them (upright columns).
    static func pieces(row: Int, width w: Int) -> [(u: Range<Int>, gap: Bool)] {
        var out: [(u: Range<Int>, gap: Bool)] = [(0..<3, false)]
        let keys = PropArt.keyboardKeys.filter { $0.row == row }
        for (i, k) in keys.enumerated() {
            if i > 0 { out.append(((k.rect.minX - 1)..<k.rect.minX, true)) }
            out.append((k.rect.minX..<k.rect.maxX, false))
        }
        out.append(((keys.last?.rect.maxX ?? 3)..<w, false))
        return out
    }

    /// The banded keyboard (view px relative to the face's centre; the type's doc says how).
    static func banded(_ upright: PixelBuffer, _ theta: Double) -> Placed {
        let w = upright.width
        let cs = cos(theta), sn = sin(theta), slope = tan(theta) / 2
        let c = centre
        // Each band's pixels by view point, with the band and the row within it.
        var drawn: [ArtPoint: (ink: RGBA8, s: Int32, band: Int, row: Int)] = [:]
        for (b, rows) in bands.enumerated() {
            // The band slides as the turn shears its middle row; its pieces keep their order and gaps.
            let mid = 2.5 + 3 * Double(b) - Double(c.y)
            func x(_ u: Int) -> Double { Double(u - c.x) * cs + 2 * mid * sn }
            // Each piece's columns (from the cursor) and the rise of each: a piece the slope would raise by less than
            // a pixel along it sits level, as a whole; a gap sits with the key on its left and a margin with its key.
            var cursor = Int(x(0).rounded())
            var laid: [(piece: (u: Range<Int>, gap: Bool), x0: Int, dys: [Int])] = []
            for piece in pieces(row: b, width: w) {
                let width = piece.gap ? 1 : max(1, Int(x(piece.u.upperBound).rounded()) - cursor)
                let level = Double(width) * abs(slope) < 1
                let levelDY = Int((-slope * (Double(cursor) + Double(width) / 2)).rounded())
                var dys = (0..<width).map { level ? levelDY : Int((-slope * (Double(cursor + $0) + 0.5)).rounded()) }
                // A sloping key steps no closer than two columns to its ends (no one-pixel stub at a corner).
                if !level, width >= 6 {
                    for j in 0..<2 { dys[j] = dys[2] }
                    for j in (width - 2)..<width { dys[j] = dys[width - 3] }
                }
                laid.append((piece, cursor, dys))
                cursor += width
            }
            for i in laid.indices {
                if laid[i].piece.gap, i > 0 { laid[i].dys = [laid[i - 1].dys.last!] }
            }
            if laid.count > 2 {
                laid[0].dys = laid[0].dys.map { _ in laid[1].dys.first! }
                let n = laid.count
                laid[n - 1].dys = laid[n - 1].dys.map { _ in laid[n - 2].dys.last! }
            }
            for (piece, x0, dys) in laid {
                let n = piece.u.count, width = dys.count
                for j in 0..<width {
                    let vx = x0 + j
                    let u = j == width - 1 ? piece.u.upperBound - 1 : piece.u.lowerBound + j * n / width
                    for (k, row) in rows.enumerated() {
                        let ink = upright[u, row]
                        guard ink.a != 0 else { continue }
                        let p = ArtPoint(vx, row - c.y + dys[j])
                        // Where two bands meet on the same row, the one above keeps it (its side row).
                        if let had = drawn[p], had.band < b { continue }
                        drawn[p] = (ink, Int32(row * w + u), b, k)
                    }
                }
            }
        }
        // A row left open between two bands' stairs takes the pixel below it, so the rows between keys stay one pixel.
        var out: Placed = drawn.mapValues { ($0.ink, $0.s) }
        let xs = Set(drawn.keys.map(\.x))
        for vx in xs {
            let ys = drawn.keys.filter { $0.x == vx }.map(\.y)
            guard let top = ys.min(), let bottom = ys.max(), bottom - top + 1 > ys.count else { continue }
            for vy in stride(from: bottom - 1, to: top, by: -1) where out[ArtPoint(vx, vy)] == nil {
                out[ArtPoint(vx, vy)] = out[ArtPoint(vx, vy + 1)]
            }
        }
        return out
    }

    /// The face sampled back pixel by pixel (nearest neighbour), relative to its centre, spur pixels off its outline
    /// dropped (a corner the sampling clipped to a single pixel), so the outline stays a clean stair.
    static func sampled(_ upright: PixelBuffer, _ theta: Double, spun: Bool) -> Placed {
        let w = upright.width
        let cs = cos(theta), sn = sin(theta)
        let c = centre
        var xs: [Double] = [], ys: [Double] = []
        for (u, v) in [(-c.x, -c.y), (w - c.x, -c.y), (-c.x, faceRows - c.y), (w - c.x, faceRows - c.y)] {
            let du = Double(u), dv = Double(v)
            xs.append(du * cs + 2 * dv * sn)
            ys.append(-du * sn / 2 + dv * cs)
        }
        let x0 = Int(xs.min()!.rounded(.down)), x1 = Int(xs.max()!.rounded(.up))
        let y0 = Int(ys.min()!.rounded(.down)), y1 = Int(ys.max()!.rounded(.up))
        var faces: Placed = [:]
        for vy in y0..<y1 {
            for vx in x0..<x1 {
                let X = Double(vx) + 0.5, Y = Double(vy) + 0.5
                var u = X * cs - 2 * Y * sn, v = X * sn / 2 + Y * cs
                if spun { (u, v) = (-u, -v) }
                let sx = Int((u + Double(c.x)).rounded(.down)), sy = Int((v + Double(c.y)).rounded(.down))
                guard sx >= 0, sy >= 0, sx < w, sy < faceRows, upright[sx, sy].a != 0 else { continue }
                faces[ArtPoint(vx, vy)] = (upright[sx, sy], Int32(sy * w + sx))
            }
        }
        let sides = [ArtPoint(1, 0), ArtPoint(-1, 0), ArtPoint(0, 1), ArtPoint(0, -1)]
        let spurs = faces.keys.filter { p in sides.filter { faces[p + $0] != nil }.count <= 1 }
        for p in spurs { faces[p] = nil }
        return faces
    }
}

/// Decor for very tall walls (portrait displays; Errata 26): the room light on the ceiling, the beams across it, an
/// upper shelf, a cluster of prints and a macramé wall hanging, in the room's inks and pixel style. `LayoutSolver`
/// decides what fits.
extension DecorArt {
    // MARK: Ceiling lamp

    /// The ceiling lamp's drawn size: a 50-px linen drum and its round glass, on a plate on the ceiling.
    static let ceilingLampSize = ArtSize(56, 16)

    /// Where the ceiling lamp's glass lies in a sprite of `size`: the disc under the drum, an ellipse (a disc on a
    /// level plane, seen from below), inside its metal ring.
    static func ceilingLampDisc(in size: ArtSize) -> ArtRect {
        let o = ArtPoint((size.w - ceilingLampSize.w) / 2, (size.h - ceilingLampSize.h) / 2)
        return ArtRect(o.x + 5, o.y + 7, 46, 8)
    }

    /// The room light: a linen drum on the ceiling (lit on its near half, shaded under it), its round glass underneath
    /// in a metal ring, bright and warm at its middle when lit. Drawn at `ceilingLampSize`, centred in `size`.
    public static func ceilingLamp(_ size: ArtSize, lit: Bool) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h)
        let o = ArtPoint((size.w - ceilingLampSize.w) / 2, (size.h - ceilingLampSize.h) / 2)
        // The plate it hangs from.
        c.fill(ArtRect(o.x + 19, o.y, 18, 2), .neutral7)
        c.hline(x: o.x + 20, y: o.y, length: 16, .neutral6)
        // The drum: rims, the lit linen above, the shaded linen below.
        let drum = ArtRect(o.x + 3, o.y + 2, 50, 9)
        c.roundedRectFill(drum, radius: 1, .walnut2)
        c.fill(drum.insetBy(1, 1), .walnut4)
        c.fill(ArtRect(drum.x + 1, drum.y + 1, drum.w - 2, 3), .walnut5)
        c.hline(x: drum.x + 2, y: drum.y + 1, length: drum.w - 4, .oak5)
        c.vline(x: drum.maxX - 2, y: drum.y + 1, length: drum.h - 2, .walnut3)
        // The glass under it, in its ring: the drum shows round its upper half.
        let disc = ceilingLampDisc(in: size)
        c.ellipseFill(disc.insetBy(-2, -1), .neutral4)
        c.ellipseFill(disc, lit ? .neutral9 : .neutral7)
        c.ellipseFill(ArtRect(disc.x + 10, disc.y + 2, disc.w - 20, 4), lit ? .walnut5 : .neutral8)
        c.hline(x: disc.x + 8, y: disc.maxY - 1, length: disc.w - 16, lit ? .neutral8 : .neutral6)
        return SpriteAsset(lit ? "decor.ceilingLamp.lit" : "decor.ceilingLamp", c, anchor: .zero)
    }

    /// The ceiling lamp's glass pixels (sprite-local), emissive while it is lit.
    public static func ceilingLampGlass(in size: ArtSize) -> [ArtPoint] {
        var c = PixelCanvas(width: size.w, height: size.h)
        c.ellipseFill(ceilingLampDisc(in: size), .neutral9)
        var out: [ArtPoint] = []
        for y in 0..<size.h {
            for x in 0..<size.w where c.ink(at: x, y)?.isClear == false { out.append(ArtPoint(x, y)) }
        }
        return out
    }

    // MARK: Ceiling beams

    /// Where the ceiling's beams run (sprite-local left x), back to the wall: four across, a beam's width each.
    static func beamXs(width: Int) -> [Int] { [1, 3, 5, 7].map { width * $0 / 8 - beamWidth / 2 } }
    static let beamWidth = 12

    /// Oak beams over the ceiling's joints, running from the viewer back to the crown (straight up the view in the
    /// 2:1 projection), lit on their left edge and shadowed on the right, a step darker with each of the ceiling's
    /// bands (`band(y)`: 0 at the crown, undithered, so a beam changes in one straight step). Their inks skip `oak3`,
    /// which the room light's warmth after dark lifts to a bright orange: so each beam stays darker than the ceiling
    /// behind it by day and by the room light alike, never a glowing stripe (Errata 26).
    static func drawBeams(_ c: inout PixelCanvas, band: (Int) -> Int) {
        let body: [Ink] = [.oak4, .oak2, .oak1], lit: [Ink] = [.oak5, .oak4, .oak2]
        let shade: [Ink] = [.oak2, .oak1, .oak0]
        for x0 in beamXs(width: c.width) where x0 >= 0 && x0 + beamWidth <= c.width {
            for y in 0..<c.height {
                let b = min(max(band(y), 0), 2)
                c.hline(x: x0, y: y, length: beamWidth, body[b])
                c.vline(x: x0, y: y, length: 1, lit[b])
                c.plot(x0 + 1, y, lit[b])
                c.plot(x0 + beamWidth - 2, y, shade[b])
                c.plot(x0 + beamWidth - 1, y, shade[b])
                // Grain: a short darker streak now and then.
                if y % 23 == 11 { c.hline(x: x0 + 3, y: y, length: 5, shade[b]) }
            }
            // Where a beam meets the crown, its end sits a row lower, in shadow.
            c.hline(x: x0, y: c.height - 1, length: beamWidth, .oak1)
        }
    }

    // MARK: Upper shelf

    /// A wall shelf left of the middle, its things in three groups: a succulent beside a run of books leaning on a
    /// bookend; a globe and a stack of books with a candle; a vase of dried stems at the right end. Its books are
    /// darker and taller than the lower shelf's, and nothing trails from it (the hanging plant is the pothos up here).
    public static func upperShelf(_ size: ArtSize) -> SpriteAsset {
        let w = size.w
        var c = PixelCanvas(width: w, height: size.h)
        let boardY = size.h - 14
        // A succulent rosette in a small grey pot.
        let pot = ArtRect(4, boardY - 7, 12, 7)
        c.fill(pot, .neutral6)
        c.hline(x: pot.x, y: pot.y, length: pot.w, .neutral8)
        c.vline(x: pot.maxX - 1, y: pot.y + 1, length: pot.h - 1, .neutral4)
        c.hline(x: pot.x + 1, y: pot.maxY - 1, length: pot.w - 2, .neutral5)
        let rosette: [(Int, Int, Ink)] = [(-1, -3, .green2), (9, -3, .green2), (1, -5, .green3), (7, -5, .green3),
                                          (3, -7, .green4), (5, -6, .green3), (4, -4, .green4)]
        for (dx, dy, ink) in rosette {
            c.fill(ArtRect(pot.x + dx + 1, pot.y + dy, 3, 3), ink)
        }
        c.plot(pot.x + 5, pot.y - 7, .green5)
        // Books upright, of mixed heights and widths, the last leaning on a bookend.
        var x = 22
        let books: [(w: Int, h: Int, ink: Ink, band: Ink?)] = [
            (4, 25, .walnut2, .oak4), (3, 22, .neutral3, nil), (5, 27, .blue1, .oak4), (4, 20, .red2, .neutral8),
            (3, 24, .green1, nil), (5, 23, .neutral8, .red3), (4, 26, .purple1, .oak4), (3, 19, .oak2, nil),
        ]
        for b in books {
            let r = ArtRect(x, boardY - b.h, b.w, b.h)
            c.fill(r, b.ink)
            c.vline(x: r.x, y: r.y, length: r.h, b.ink.lighter())
            c.vline(x: r.maxX - 1, y: r.y, length: r.h, b.ink.darker())
            c.hline(x: r.x, y: r.y, length: r.w, b.ink.darker(2))
            if let band = b.band {
                c.hline(x: r.x, y: r.y + 4, length: r.w, band)
                c.hline(x: r.x, y: r.maxY - 5, length: r.w, band)
            }
            x += b.w
        }
        let lean = [ArtPoint(x + 1, boardY), ArtPoint(x + 5, boardY), ArtPoint(x + 14, boardY - 19),
                    ArtPoint(x + 10, boardY - 21)]
        c.polygonFill(lean, .red2)
        c.line(from: ArtPoint(x + 2, boardY - 1), to: ArtPoint(x + 11, boardY - 20), .red3)
        c.line(from: ArtPoint(x + 5, boardY - 1), to: ArtPoint(x + 13, boardY - 18), .red1)
        let end = ArtRect(x + 13, boardY - 18, 3, 18)
        c.fill(end, .neutral2)
        c.fill(ArtRect(end.x - 2, boardY - 2, 5, 2), .neutral2)
        c.vline(x: end.x, y: end.y, length: end.h - 2, .neutral4)
        // A globe on its stand.
        let g = ArtRect(88, boardY - 22, 16, 16)
        c.fill(ArtRect(g.x + 6, boardY - 4, 4, 4), .walnut2)
        c.hline(x: g.x + 4, y: boardY - 1, length: 8, .walnut1)
        c.ellipseFill(g.insetBy(-1, -1), .walnut2)
        c.ellipseFill(g, .blue3)
        c.ellipseFill(ArtRect(g.x + 3, g.y + 3, 6, 5), .green3)
        c.ellipseFill(ArtRect(g.x + 9, g.y + 8, 4, 5), .green2)
        c.plot(g.x + 4, g.y + 2, .blue5)
        c.plot(g.x + 5, g.y + 2, .blue5)
        // Books lying flat with a candle on top.
        let sx = 106
        var y = boardY
        for (bw, ink) in [(28, Ink.walnut3), (25, .blue2), (27, .neutral7)] {
            let r = ArtRect(sx + (28 - bw) / 2, y - 4, bw, 4)
            c.fill(r, ink)
            c.hline(x: r.x, y: r.y, length: r.w, ink.lighter())
            c.vline(x: r.maxX - 1, y: r.y, length: r.h, .neutral9)
            c.hline(x: r.x, y: r.maxY - 1, length: r.w, ink.darker())
            y -= 4
        }
        let holder = ArtRect(sx + 9, y - 2, 9, 2)
        c.fill(holder, .walnut4)
        c.hline(x: holder.x, y: holder.maxY - 1, length: holder.w, .walnut2)
        let candle = ArtRect(sx + 11, y - 10, 5, 8)
        c.fill(candle, .walnut4)
        c.vline(x: candle.x, y: candle.y, length: candle.h, .walnut5)
        c.vline(x: candle.maxX - 1, y: candle.y, length: candle.h, .walnut2)
        c.hline(x: candle.x, y: candle.y, length: candle.w, .walnut5)
        c.plot(candle.x + 2, candle.y - 1, .neutral2)
        // A ceramic vase of dried stems at the right end.
        let vase = ArtRect(w - 28, boardY - 12, 12, 12)
        for (i, (dx, top, ink)) in [(-6, 26, Ink.oak3), (-2, 29, .oak2), (2, 27, .walnut3), (6, 24, .oak3),
                                     (9, 21, .oak2)].enumerated() {
            let tip = ArtPoint(vase.x + 6 + dx, boardY - top)
            c.line(from: ArtPoint(vase.x + 5 + i / 2, vase.y), to: tip, ink)
            c.fill(ArtRect(tip.x - 1, tip.y - 1, 3, 4), i % 2 == 0 ? .oak5 : .oak4)
            c.plot(tip.x, tip.y - 2, .oak5)
        }
        c.roundedRectFill(vase, radius: 3, .blue2)
        c.fill(ArtRect(vase.x + 3, vase.y - 2, 6, 3), .blue2)
        c.hline(x: vase.x + 3, y: vase.y - 2, length: 6, .blue3)
        c.vline(x: vase.x + 2, y: vase.y + 2, length: 7, .blue4)
        c.vline(x: vase.maxX - 2, y: vase.y + 2, length: 8, .blue1)
        // The board, then two brackets under it.
        c.fill(ArtRect(0, boardY, w, 4), .oak3)
        c.hline(x: 0, y: boardY, length: w, .oak5)
        c.hline(x: 0, y: boardY + 1, length: w, .oak4)
        c.hline(x: 0, y: boardY + 3, length: w, .oak1)
        c.vline(x: w - 1, y: boardY, length: 4, .oak1)
        for bx in [16, w - 22] {
            c.fill(ArtRect(bx, boardY + 4, 3, 8), .neutral3)
            c.vline(x: bx, y: boardY + 4, length: 8, .neutral5)
            c.line(from: ArtPoint(bx + 2, boardY + 11), to: ArtPoint(bx + 6, boardY + 4), .neutral3)
        }
        return SpriteAsset("decor.upperShelf", c, anchor: .zero)
    }

    /// The upper shelf's board (sprite-local): what casts its shadow on the wall.
    public static func upperShelfBoard(in size: ArtSize) -> ArtRect { ArtRect(0, size.h - 14, size.w, 4) }

    // MARK: Gallery

    /// The gallery's four frames in a sprite of `size` (those that fit): a tall poster on the left, a leafy print over
    /// a small sun in the middle, a night skyline on the right.
    public static func galleryFrames(in size: ArtSize) -> [ArtRect] {
        let h = size.h, w = size.w
        let tall = ArtRect(0, (h - min(h, 64)) / 2, 40, min(h, 64))
        let leafy = ArtRect(48, 0, 64, h * 11 / 20)
        let sun = ArtRect(56, leafy.maxY + 8, 34, h - leafy.maxY - 8)
        let city = ArtRect(120, h / 5, w - 120, h - h / 5 - 4)
        let bounds = ArtRect(0, 0, w, h)
        return [tall, leafy, sun, city].filter { bounds.contains($0) && $0.w >= 24 && $0.h >= 24 }
    }

    /// A cluster of four framed prints: a sunset poster, a leafy print, a night skyline and a small sun, in black, oak
    /// and white frames on a loose grid (`galleryFrames`).
    public static func gallery(_ size: ArtSize) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h)
        let frames = galleryFrames(in: size)
        func framed(_ r: ArtRect, frame: Ink, rim: Ink, art: (inout PixelCanvas) -> Void) {
            guard frames.contains(r) else { return }
            c.fill(r, frame)
            c.stroke(r, rim)
            c.hline(x: r.x + 1, y: r.y + 1, length: r.w - 2, frame.lighter())
            let mat = r.insetBy(2, 2)
            c.fill(mat, .neutral9)
            c.hline(x: mat.x, y: mat.maxY - 1, length: mat.w, .neutral8)
            let a = mat.insetBy(3, 3)
            c.drawing(at: a.origin, size: a.size, art)
        }
        let h = size.h, w = size.w
        // Left: a tall sunset poster over hills.
        framed(ArtRect(0, (h - min(h, 64)) / 2, 40, min(h, 64)), frame: .neutral1, rim: .neutral0) { a in
            a.gradientV(a.bounds, inks: [.red4, .walnut4, .oak5])
            a.ellipseFill(ArtRect(a.width / 2 - 6, a.height / 2 - 6, 12, 12), .oak5)
            for x in 0..<a.width {
                let top = a.height * 2 / 3 - Int(5 * abs(RoomArt.sine(Double(x) / 7)))
                a.vline(x: x, y: top, length: a.height - top, .purple2)
                let low = a.height - 6 + Int(2 * RoomArt.sine(Double(x) / 4))
                a.vline(x: x, y: low, length: a.height - low, .purple1)
            }
        }
        // Top middle: a leafy print.
        let leafy = ArtRect(48, 0, 64, h * 11 / 20)
        framed(leafy, frame: .oak2, rim: .oak0) { a in
            a.fill(a.bounds, .oak5)
            for (i, x) in stride(from: 4, to: a.width - 4, by: 11).enumerated() {
                let top = 3 + (i % 2) * 4
                a.vline(x: x + 3, y: top, length: a.height - top - 2, .green1)
                for yy in stride(from: top + 2, to: a.height - 4, by: 5) {
                    a.fill(ArtRect(x, yy, 3, 2), i % 2 == 0 ? .green3 : .green2)
                    a.fill(ArtRect(x + 4, yy + 2, 3, 2), .green2)
                }
            }
        }
        // Bottom middle: a small sun.
        framed(ArtRect(56, leafy.maxY + 8, 34, h - leafy.maxY - 8), frame: .neutral8, rim: .neutral5) { a in
            a.fill(a.bounds, .blue4)
            let s = min(a.width, a.height) - 6
            a.ellipseFill(ArtRect((a.width - s) / 2, (a.height - s) / 2, s, s), .oak4)
            a.ellipseFill(ArtRect((a.width - s) / 2 + 2, (a.height - s) / 2 + 2, s - 4, s - 4), .walnut5)
        }
        // Right: a night skyline.
        framed(ArtRect(120, h / 5, w - 120, h - h / 5 - 4), frame: .neutral1, rim: .neutral0) { a in
            a.gradientV(a.bounds, inks: [.blue0, .blue1, .purple1])
            a.ellipseFill(ArtRect(a.width - 10, 3, 5, 5), .oak5)
            var x = 0, k = 0
            while x < a.width {
                let bw = 5 + (k * 3) % 5, bh = a.height / 3 + (k * 7) % (a.height / 2)
                a.fill(ArtRect(x, a.height - bh, bw, bh), k % 2 == 0 ? .neutral2 : .neutral1)
                for wy in stride(from: a.height - bh + 2, to: a.height - 2, by: 3) where (wy + k) % 2 == 0 {
                    a.plot(x + 1 + (wy % 2), wy, .oak5)
                }
                x += bw + 1
                k += 1
            }
        }
        return SpriteAsset("decor.gallery", c, anchor: .zero)
    }

    // MARK: Wall hanging

    /// A macramé wall hanging on an oak dowel, hung by a string from a nail: cream cords knotted in rows of diamonds
    /// with a mustard band, tapering to a long fringe that hangs lowest in the middle. Sized by `size` (about 9:20).
    public static func wallHanging(_ size: ArtSize) -> SpriteAsset {
        let w = size.w, h = size.h
        var c = PixelCanvas(width: w, height: h)
        let mid = w / 2
        // The string from the nail to the dowel's ends, then the dowel.
        c.line(from: ArtPoint(mid, 1), to: ArtPoint(3, 10), .neutral4)
        c.line(from: ArtPoint(mid, 1), to: ArtPoint(w - 4, 10), .neutral4)
        c.fill(ArtRect(mid - 1, 0, 2, 2), .neutral3)
        let dowel = ArtRect(0, 10, w, 3)
        c.fill(dowel, .oak3)
        c.hline(x: 0, y: dowel.y, length: w, .oak4)
        c.hline(x: 0, y: dowel.maxY - 1, length: w, .oak1)
        c.vline(x: 0, y: dowel.y, length: 3, .walnut2)
        c.vline(x: w - 1, y: dowel.y, length: 3, .walnut2)
        // The knotted body: down to a point in the middle; the fringe below it, longest in the middle.
        let top = dowel.maxY, x0 = 4, x1 = w - 4
        let bodyEnd = top + (h - top) * 11 / 20, fringeEnd = h - 1
        let half = max(1, (x1 - x0) / 2)
        for x in x0..<x1 {
            let off = abs(x - mid)
            let body = bodyEnd - off * (bodyEnd - top) / (2 * half)
            let fringe = fringeEnd - off * (fringeEnd - bodyEnd) / half
            let cord: Ink = x % 2 == 0 ? .oak5 : .oak4
            c.vline(x: x, y: top, length: body - top, cord)
            if x % 2 == 0 { c.vline(x: x, y: body, length: max(0, fringe - body), x % 4 == 0 ? .oak5 : .oak4) }
        }
        // Rows of square knots: small diamonds, offset row to row; a mustard band a third of the way down.
        let band = top + (bodyEnd - top) / 3
        for (row, ky) in stride(from: top + 4, to: bodyEnd - 4, by: 7).enumerated() {
            for kx in stride(from: x0 + 2 + (row % 2) * 4, to: x1 - 2, by: 8) {
                let off = abs(kx - mid)
                guard ky + 3 < bodyEnd - off * (bodyEnd - top) / (2 * half) else { continue }
                let ink: Ink = abs(ky - band) < 4 ? .walnut4 : .neutral9
                c.plot(kx, ky - 1, ink)
                c.hline(x: kx - 1, y: ky, length: 3, ink)
                c.plot(kx, ky + 1, ink)
                c.plot(kx + 1, ky + 1, .oak3)
                c.plot(kx, ky + 2, .oak3)
            }
        }
        // A gathering knot over the fringe's middle.
        c.fill(ArtRect(mid - 3, bodyEnd - 1, 6, 3), .oak3)
        c.hline(x: mid - 3, y: bodyEnd - 1, length: 6, .neutral9)
        return SpriteAsset("decor.wallHanging", c, anchor: .zero)
    }
}

extension LightMask {
    // MARK: w6-polish
    /// The ceiling lamp lit (the room light after dark): its glass at full light (the room's warm light already
    /// washes the ceiling round it).
    public mutating func addCeilingLamps(_ layout: SceneLayout) {
        for d in layout.decor(.ceilingLamp) {
            addPoints(DecorArt.ceilingLampGlass(in: d.rect.size).map { ArtPoint(d.rect.x + $0.x, d.rect.y + $0.y) },
                      level: 7, tint: .warm)
        }
    }
}

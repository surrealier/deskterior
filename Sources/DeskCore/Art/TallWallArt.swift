/// Decor for very tall walls (portrait displays; Errata 26): the room light on the ceiling, the beams across it, a
/// long upper shelf and a cluster of prints, in the room's inks and pixel style. `LayoutSolver` decides what fits.
extension DecorArt {
    // MARK: Ceiling lamp

    /// The room light: a linen drum on the ceiling, its round glass underneath (an ellipse, as a disc on a level
    /// plane is in the 2:1 view), bright when lit. Drawn at `ceilingLampArt`'s 40×10, whatever `size` holds.
    public static func ceilingLamp(_ size: ArtSize, lit: Bool) -> SpriteAsset {
        let key: [Character: Ink] = [
            ".": .clear, "p": .neutral6, "q": .neutral8, "r": .walnut2, "h": .walnut5, "d": .walnut4,
            "g": lit ? .neutral9 : .neutral7, "c": lit ? .walnut5 : .neutral8,
        ]
        var c = PixelCanvas(width: size.w, height: size.h)
        c.blit(IndexedSprite(ceilingLampArt, key), at: ArtPoint((size.w - 40) / 2, (size.h - 10) / 2))
        return SpriteAsset(lit ? "decor.ceilingLamp.lit" : "decor.ceilingLamp", c, anchor: .zero)
    }

    /// The ceiling lamp: `p`/`q` its plate on the ceiling, `r` rims, `h`/`d` the drum, `g`/`c` the glass.
    static let ceilingLampArt = """
        ...........pppppppppppppppppp...........
        ........ppqqqqqqqqqqqqqqqqqqqqpp........
        ....rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr....
        ...rhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhr...
        ...rddddddddddddddddddddddddddddddddr...
        ...rddddddddddddddddddddddddddddddddr...
        ...rrrrggggggggggggggggggggggggggrrrr...
        ....rrgggggggccccccccccccccgggggggrr....
        ......rrrggggggggggggggggggggggrrr......
        .........rrrrrrrrrrrrrrrrrrrrrr.........
        """

    /// The ceiling lamp's glass pixels (sprite-local), emissive while it is lit.
    public static func ceilingLampGlass(in size: ArtSize) -> [ArtPoint] {
        let o = ArtPoint((size.w - 40) / 2, (size.h - 10) / 2)
        let art = IndexedSprite(ceilingLampArt, [".": .clear, "p": .clear, "q": .clear, "r": .clear, "h": .clear,
                                                 "d": .clear, "g": .neutral9, "c": .neutral9])
        var out: [ArtPoint] = []
        for y in 0..<art.h {
            for x in 0..<art.w where !art[x, y].isClear { out.append(ArtPoint(o.x + x, o.y + y)) }
        }
        return out
    }

    // MARK: Ceiling beams

    /// Where the ceiling's beams run (sprite-local left x), back to the wall: four across, a beam's width each.
    static func beamXs(width: Int) -> [Int] { [1, 3, 5, 7].map { width * $0 / 8 - beamWidth / 2 } }
    static let beamWidth = 12

    /// Oak beams over the ceiling's joints, running from the viewer back to the crown (straight up the view in the
    /// 2:1 projection), lit on their left edge and shadowed on the right, darkening with the ceiling's own bands
    /// (`band(x, y)`: 0 at the crown, dithered as the plaster is).
    static func drawBeams(_ c: inout PixelCanvas, band: (Int, Int) -> Int) {
        let body: [Ink] = [.oak4, .oak3, .oak2], lit: [Ink] = [.oak5, .oak4, .oak3], shade: [Ink] = [.oak2, .oak1, .oak1]
        for x0 in beamXs(width: c.width) where x0 >= 0 && x0 + beamWidth <= c.width {
            for y in 0..<c.height {
                for x in x0..<(x0 + beamWidth) {
                    let b = min(band(x, y), 2)
                    let ink = x <= x0 + 1 ? lit[b] : x >= x0 + beamWidth - 2 ? shade[b] : body[b]
                    c.plot(x, y, ink)
                }
                // Grain: a short darker streak now and then.
                if y % 23 == 11 { c.hline(x: x0 + 3, y: y, length: 5, body[min(band(x0 + 3, y), 2)].darker()) }
            }
            // Where a beam meets the crown, its end sits a row lower, in shadow.
            c.hline(x: x0, y: c.height - 1, length: beamWidth, .oak1)
        }
    }

    // MARK: Upper shelf

    /// A long wall shelf: a run of books, a globe, a cactus, a stacked pile with a mug, a storage box, more books and
    /// a pothos trailing over the right end, on an oak board with three brackets.
    public static func upperShelf(_ size: ArtSize) -> SpriteAsset {
        let w = size.w
        var c = PixelCanvas(width: w, height: size.h)
        let boardY = size.h - 14
        func books(_ x0: Int, _ specs: [(w: Int, h: Int, ink: Ink)]) -> Int {
            var x = x0
            for b in specs {
                let r = ArtRect(x, boardY - b.h, b.w, b.h)
                c.fill(r, b.ink)
                c.vline(x: r.x, y: r.y, length: r.h, b.ink.lighter())
                c.vline(x: r.maxX - 1, y: r.y, length: r.h, b.ink.darker())
                c.hline(x: r.x, y: r.y, length: r.w, b.ink.darker(2))
                c.hline(x: r.x, y: r.y + 3, length: r.w, .walnut5)
                c.hline(x: r.x, y: r.maxY - 4, length: r.w, b.ink.darker())
                x += b.w
            }
            return x
        }
        // The groups stand spread along the board (at fixed shares of its width), so a long shelf never bunches up.
        _ = books(8, [(4, 22, .blue2), (3, 24, .red3), (5, 21, .green2), (4, 25, .walnut3), (3, 20, .purple3),
                      (4, 23, .oak4), (5, 22, .blue4), (3, 19, .red2)])
        // A globe on a little stand.
        var x = w * 19 / 100
        let g = ArtRect(x, boardY - 22, 16, 16)
        c.fill(ArtRect(x + 6, boardY - 4, 4, 4), .walnut2)
        c.hline(x: x + 4, y: boardY - 1, length: 8, .walnut1)
        c.ellipseFill(g.insetBy(-1, -1), .walnut2)
        c.ellipseFill(g, .blue3)
        c.ellipseFill(ArtRect(g.x + 3, g.y + 3, 6, 5), .green3)
        c.ellipseFill(ArtRect(g.x + 9, g.y + 8, 4, 5), .green2)
        c.plot(g.x + 4, g.y + 2, .blue5)
        c.plot(g.x + 5, g.y + 2, .blue5)
        // A cactus in a terracotta pot.
        x = w * 32 / 100
        c.fill(ArtRect(x + 3, boardY - 18, 4, 11), .green2)
        c.vline(x: x + 3, y: boardY - 18, length: 11, .green3)
        c.fill(ArtRect(x, boardY - 15, 2, 5), .green2)
        c.fill(ArtRect(x + 8, boardY - 13, 2, 4), .green2)
        c.plot(x + 4, boardY - 19, .red4)
        c.fill(ArtRect(x - 1, boardY - 7, 12, 7), .red2)
        c.hline(x: x - 1, y: boardY - 7, length: 12, .red3)
        c.vline(x: x + 10, y: boardY - 6, length: 6, .red1)
        // Books lying flat with a mug on top.
        x = w * 43 / 100
        let stack: [(Int, Ink)] = [(30, .green2), (27, .oak4), (29, .blue2)]
        var y = boardY
        for (bw, ink) in stack {
            let r = ArtRect(x + (30 - bw) / 2, y - 4, bw, 4)
            c.fill(r, ink)
            c.hline(x: r.x, y: r.y, length: r.w, ink.lighter())
            c.vline(x: r.maxX - 1, y: r.y, length: r.h, .walnut5)
            y -= 4
        }
        let mug = ArtRect(x + 10, y - 7, 7, 7)
        c.fill(mug, .neutral9)
        c.vline(x: mug.maxX - 1, y: mug.y, length: mug.h, .neutral7)
        c.hline(x: mug.x, y: mug.y, length: mug.w, .neutral8)
        c.plot(mug.maxX, mug.y + 2, .neutral8)
        c.plot(mug.maxX + 1, mug.y + 3, .neutral8)
        c.plot(mug.maxX, mug.y + 4, .neutral8)
        c.hline(x: mug.x + 1, y: mug.y + 3, length: 4, .red4)
        // A walnut storage box with a label.
        let box = ArtRect(w * 58 / 100, boardY - 16, 30, 16)
        c.fill(box, .walnut3)
        c.hline(x: box.x, y: box.y, length: box.w, .walnut4)
        c.hline(x: box.x, y: box.y + 2, length: box.w, .walnut2)
        c.vline(x: box.maxX - 1, y: box.y, length: box.h, .walnut2)
        c.fill(ArtRect(box.x + 10, box.y + 6, 10, 5), .oak5)
        c.hline(x: box.x + 12, y: box.y + 8, length: 6, .walnut3)
        // More books, then a small framed photo.
        _ = books(w * 72 / 100, [(3, 21, .purple2), (5, 24, .red4), (4, 20, .oak3), (3, 23, .green3), (4, 22, .blue3)])
        let f = ArtRect(w * 84 / 100, boardY - 13, 10, 13)
        c.fill(f, .oak1)
        c.fill(f.insetBy(1, 1), .neutral9)
        let pic = f.insetBy(2, 2)
        c.fill(pic, .blue4)
        c.fill(ArtRect(pic.x, pic.maxY - 3, pic.w, 3), .green3)
        c.fill(ArtRect(pic.x + 2, pic.y + 2, 2, 4), .red4)
        let pothos = w - 22
        // A pothos at the right end; two vines trail down past the board.
        var foliage = PixelCanvas(width: w, height: size.h)
        for (dx, dy) in [(-3, -11), (0, -14), (4, -15), (8, -13), (10, -10), (-4, -8), (2, -11), (6, -10)] {
            leaf(&foliage, pothos + dx, boardY + dy)
        }
        for (vx, len, dir) in [(pothos + 1, 12, -1), (pothos + 8, 9, 1)] {
            for i in 0..<len {
                let vy = boardY + 4 + i, xx = vx + ((i / 4) % 2 == 0 ? 0 : dir)
                guard vy < size.h - 1 else { break }
                foliage.plot(xx, vy, .green1)
                if i % 3 == 1 { leaf(&foliage, i % 2 == 0 ? xx - 3 : xx + 1, vy) }
            }
        }
        c.blit(ArtKit.outline(foliage.buffer, .green0).cropped(to: ArtRect(1, 1, w, size.h)), at: .zero)
        c.blit(foliage.buffer, at: .zero)
        c.fill(ArtRect(pothos, boardY - 7, 10, 7), .neutral8)
        c.fill(ArtRect(pothos + 1, boardY - 7, 6, 6), .neutral9)
        c.vline(x: pothos + 9, y: boardY - 7, length: 7, .neutral6)
        c.hline(x: pothos + 1, y: boardY - 3, length: 8, .oak4)
        // The board, then three brackets under it.
        c.fill(ArtRect(0, boardY, w, 4), .oak3)
        c.hline(x: 0, y: boardY, length: w, .oak5)
        c.hline(x: 0, y: boardY + 1, length: w, .oak4)
        c.hline(x: 0, y: boardY + 3, length: w, .oak1)
        c.vline(x: w - 1, y: boardY, length: 4, .oak1)
        for vx in [pothos + 1, pothos + 8] { c.vline(x: vx, y: boardY, length: 4, .green1) }
        for bx in [12, w / 2 - 1, w - 30] {
            c.fill(ArtRect(bx, boardY + 4, 3, 8), .neutral3)
            c.vline(x: bx, y: boardY + 4, length: 8, .neutral5)
            c.line(from: ArtPoint(bx + 2, boardY + 11), to: ArtPoint(bx + 6, boardY + 4), .neutral3)
        }
        return SpriteAsset("decor.upperShelf", c, anchor: .zero)
    }

    // MARK: Gallery

    /// A cluster of four framed prints: a sunset poster, a leafy print, a night skyline and a small sun, in black, oak
    /// and white frames on a loose grid.
    public static func gallery(_ size: ArtSize) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h)
        let h = size.h, w = size.w
        func framed(_ r: ArtRect, frame: Ink, rim: Ink, art: (inout PixelCanvas) -> Void) {
            guard r.minX >= 0, r.minY >= 0, r.maxX <= w, r.maxY <= h else { return }
            c.fill(r, frame)
            c.stroke(r, rim)
            c.hline(x: r.x + 1, y: r.y + 1, length: r.w - 2, frame.lighter())
            let mat = r.insetBy(2, 2)
            c.fill(mat, .neutral9)
            c.hline(x: mat.x, y: mat.maxY - 1, length: mat.w, .neutral8)
            let a = mat.insetBy(3, 3)
            c.drawing(at: a.origin, size: a.size, art)
        }
        // Left: a tall sunset poster over hills.
        let tall = ArtRect(0, (h - min(h, 64)) / 2, 40, min(h, 64))
        framed(tall, frame: .neutral1, rim: .neutral0) { a in
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
        let leafy = ArtRect(48, 0, 70, h * 11 / 20)
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
        let sun = ArtRect(56, leafy.maxY + 8, 34, h - leafy.maxY - 8)
        if sun.h >= 24 {
            framed(sun, frame: .neutral8, rim: .neutral5) { a in
                a.fill(a.bounds, .blue4)
                let s = min(a.width, a.height) - 6
                a.ellipseFill(ArtRect((a.width - s) / 2, (a.height - s) / 2, s, s), .oak4)
                a.ellipseFill(ArtRect((a.width - s) / 2 + 2, (a.height - s) / 2 + 2, s - 4, s - 4), .walnut5)
            }
        }
        // Right: a night skyline.
        let city = ArtRect(126, h / 5, w - 126, h - h / 5 - 4)
        framed(city, frame: .neutral1, rim: .neutral0) { a in
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

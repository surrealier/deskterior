/// The instant, hand-drawn file-kind icons (DESIGN §3.4) at 16×16 (screen tokens) and 12×12 (minis in drawers),
/// 5×5 phone minis, the alias overlay and the Finder tag stripe. The model maps its file kinds onto `IconKind`.
public enum IconKind: String, CaseIterable, Hashable, Sendable {
    case folder, doc, text, pdf, image, video, audio, zip, app, code, dmg, screenshot, unknown
}

public enum KindIcons {
    /// The kind's signature colour (pen caps, folder tabs, phone minis).
    public static func color(_ kind: IconKind) -> Ink {
        switch kind {
        case .folder: .blue4
        case .doc: .blue3
        case .text: .neutral7
        case .pdf: .red3
        case .image: .green3
        case .video: .purple3
        case .audio: .purple4
        case .zip: .walnut4
        case .app: .blue2
        case .code: .green2
        case .dmg: .neutral6
        case .screenshot: .blue5
        case .unknown: .neutral5
        }
    }

    /// The icon at 16 or 12 px.
    public static func icon(_ kind: IconKind, size: Int = 16) -> SpriteAsset {
        let big = size >= 16
        let n = big ? 16 : 12
        var c = PixelCanvas(width: n, height: n)
        switch kind {
        case .folder: drawFolder(&c, n)
        case .image: drawPicture(&c, n, cropMarks: false)
        case .screenshot: drawPicture(&c, n, cropMarks: true)
        case .app: drawApp(&c, n)
        case .dmg: drawDiskImage(&c, n)
        default:
            let page = drawPage(&c, n)
            drawPageGlyph(&c, kind, page: page, big: big)
        }
        return SpriteAsset("icon.\(kind.rawValue).\(n)", c, anchor: ArtPoint(n / 2, n))
    }

    // MARK: Pieces

    /// A page with a dog-eared corner; returns the page rect.
    static func drawPage(_ c: inout PixelCanvas, _ n: Int) -> ArtRect {
        let big = n >= 16
        let w = big ? 12 : 9, fold = big ? 4 : 3
        let x0 = (n - w) / 2, x1 = x0 + w
        let poly = [ArtPoint(x0, 0), ArtPoint(x1 - fold, 0), ArtPoint(x1, fold), ArtPoint(x1, n), ArtPoint(x0, n)]
        c.polygonFill(poly, .neutral4)
        let inner = [ArtPoint(x0 + 1, 1), ArtPoint(x1 - fold, 1), ArtPoint(x1 - 1, fold), ArtPoint(x1 - 1, n - 1),
                     ArtPoint(x0 + 1, n - 1)]
        c.polygonFill(inner, .neutral9)
        c.vline(x: x1 - 2, y: fold, length: n - fold - 1, .neutral8)
        c.hline(x: x0 + 1, y: n - 2, length: w - 2, .neutral8)
        // Folded flap.
        for i in 0..<fold {
            c.hline(x: x1 - fold, y: i, length: i + 1, .neutral7)
        }
        c.vline(x: x1 - fold, y: 0, length: fold + 1, .neutral4)
        c.hline(x: x1 - fold, y: fold, length: fold, .neutral4)
        return ArtRect(x0, 0, w, n)
    }

    static func drawPageGlyph(_ c: inout PixelCanvas, _ kind: IconKind, page p: ArtRect, big: Bool) {
        let lx = p.x + 2, lw = p.w - 4
        switch kind {
        case .doc:
            c.hline(x: lx, y: 3, length: lw - (big ? 3 : 2), .blue3)
            c.hline(x: lx, y: 4, length: lw - (big ? 3 : 2), .blue4)
            let ys: [Int] = big ? [7, 9, 11, 13] : [6, 8]
            for (i, y) in ys.enumerated() {
                c.hline(x: lx, y: y, length: i % 2 == 0 ? lw : lw - 2, .neutral6)
            }
        case .text:
            let ys: [Int] = big ? [3, 5, 7, 9, 11, 13] : [3, 5, 7, 9]
            for (i, y) in ys.enumerated() {
                c.hline(x: lx, y: y, length: [lw - 2, lw, lw - 1, lw, lw - 3, lw - 1][i], .neutral6)
            }
        case .pdf:
            for y in big ? [3, 5] : [3] { c.hline(x: lx, y: y, length: lw - 2, .neutral6) }
            let band = big ? ArtRect(p.x - 1, 8, p.w + 2, 7) : ArtRect(p.x - 1, 5, p.w + 2, 6)
            c.fill(band, .red2)
            c.fill(band.insetBy(1, 1), .red3)
            c.hline(x: band.x + 1, y: band.y + 1, length: band.w - 2, .red4)
            if big {
                Digits.draw("PDF", at: ArtPoint(band.x + (band.w - 11) / 2, band.y + 1), .neutral9, into: &c)
            } else {
                c.hline(x: band.x + 2, y: band.y + 2, length: band.w - 4, .neutral9)
                c.hline(x: band.x + 2, y: band.y + 3, length: 3, .neutral9)
            }
        case .code:
            // Syntax-coloured lines with indentation.
            let lines: [(Int, Int, Ink)] = big
                ? [(0, 4, .purple3), (2, 5, .blue3), (2, 3, .green2), (4, 4, .red3), (2, 6, .blue3), (0, 2, .purple3)]
                : [(0, 3, .purple3), (2, 3, .blue3), (2, 4, .green2), (0, 2, .purple3)]
            for (i, line) in lines.enumerated() {
                c.hline(x: lx + line.0, y: 3 + i * 2, length: min(line.1, lw - line.0), line.2)
            }
        case .audio:
            let g: [String] = big
                ? ["....##", "...###", "...#.#", "...#..", ".###..", "####..", ".##..."]
                : ["..##", "..#.", ".##.", "##.."]
            stamp(&c, g, at: ArtPoint(p.x + (big ? 3 : 2), big ? 5 : 4), .purple3)
            c.plot(p.x + (big ? 4 : 2), big ? 10 : 7, .purple5)
        case .video:
            let r = big ? ArtRect(p.x + 1, 5, p.w - 3, 8) : ArtRect(p.x + 1, 4, p.w - 3, 6)
            c.fill(r, .purple1)
            c.fill(r.insetBy(1, 0), .purple3)
            for y in stride(from: r.y, to: r.maxY, by: 2) {
                c.plot(r.x, y, .neutral9)
                c.plot(r.maxX - 1, y, .neutral9)
            }
            let tx = r.x + r.w / 2 - 1, ty = r.y + r.h / 2 - (big ? 2 : 1)
            for i in 0..<(big ? 3 : 2) { c.vline(x: tx + i, y: ty + i, length: (big ? 5 : 3) - 2 * i, .neutral9) }
        case .zip:
            let x = p.x + p.w / 2 - 1
            for y in stride(from: 0, to: big ? 9 : 6, by: 1) {
                c.plot(x + (y % 2), y + 1, y % 2 == 0 ? .neutral3 : .walnut4)
            }
            c.fill(ArtRect(x - 1, big ? 9 : 6, 3, big ? 4 : 3), .walnut3)
            c.plot(x, big ? 10 : 7, .neutral1)
            c.hline(x: x - 1, y: big ? 9 : 6, length: 3, .walnut5)
        default:
            let g: [String] = big
                ? [".###.", "#...#", "...#.", "..#..", ".....", "..#.."]
                : [".##.", "#..#", "..#.", ".....", "..#."]
            stamp(&c, g, at: ArtPoint(p.x + (p.w - g[0].count) / 2, big ? 4 : 2), .neutral5)
        }
    }

    static func stamp(_ c: inout PixelCanvas, _ rows: [String], at o: ArtPoint, _ ink: Ink) {
        for (dy, row) in rows.enumerated() {
            for (dx, ch) in row.enumerated() where ch == "#" { c.plot(o.x + dx, o.y + dy, ink) }
        }
    }

    static func drawFolder(_ c: inout PixelCanvas, _ n: Int) {
        let big = n >= 16
        let top = big ? 2 : 1, tabW = big ? 6 : 5
        // Tab and back panel.
        c.roundedRectFill(ArtRect(0, top, tabW + 1, 4), radius: 1, .blue2)
        c.fill(ArtRect(1, top + 1, tabW - 1, 3), .blue3)
        c.roundedRectFill(ArtRect(0, top + 2, n, n - top - 3), radius: 1, .blue2)
        c.fill(ArtRect(1, top + 3, n - 2, n - top - 5), .blue3)
        // Front panel.
        let fy = top + (big ? 4 : 3)
        c.roundedRectFill(ArtRect(0, fy, n, n - fy - 1), radius: 1, .blue2)
        c.fill(ArtRect(1, fy + 1, n - 2, n - fy - 3), .blue4)
        c.hline(x: 1, y: fy + 1, length: n - 2, .blue5)
        c.hline(x: 1, y: n - 3, length: n - 2, .blue3)
        c.hline(x: 1, y: n - 2, length: n - 2, .blue2)
        if big { c.hline(x: 5, y: fy + 5, length: 6, .blue3) }
    }

    static func drawPicture(_ c: inout PixelCanvas, _ n: Int, cropMarks: Bool) {
        let big = n >= 16
        let r = big ? ArtRect(0, 2, 16, 13) : ArtRect(0, 1, 12, 10)
        c.roundedRectFill(r, radius: 1, .neutral4)
        c.fill(r.insetBy(1, 1), .neutral9)
        let art = r.insetBy(2, 2)
        c.fill(art, cropMarks ? .blue3 : .blue4)
        c.hline(x: art.x, y: art.y, length: art.w, cropMarks ? .blue2 : .blue5)
        let sun = ArtPoint(art.maxX - (big ? 4 : 3), art.y + 1)
        c.fill(ArtRect(sun.x, sun.y, 2, 2), .walnut5)
        for x in 0..<art.w {
            let hill = art.maxY - 2 - ((x * 3 / max(art.w, 1)) % 2 == 0 ? (x % 5 < 3 ? 1 : 2) : 0)
            c.vline(x: art.x + x, y: hill, length: art.maxY - hill, x < art.w / 2 ? .green3 : .green2)
        }
        if cropMarks {
            // Dashed selection corners.
            for (x, y) in [(r.x, r.y), (r.maxX - 3, r.y), (r.x, r.maxY - 1), (r.maxX - 3, r.maxY - 1)] {
                c.hline(x: x, y: y, length: 3, .neutral1)
            }
            for (x, y) in [(r.x, r.y), (r.maxX - 1, r.y), (r.x, r.maxY - 3), (r.maxX - 1, r.maxY - 3)] {
                c.vline(x: x, y: y, length: 3, .neutral1)
            }
        }
    }

    static func drawApp(_ c: inout PixelCanvas, _ n: Int) {
        let big = n >= 16
        let r = ArtRect(big ? 1 : 0, big ? 1 : 0, big ? 14 : 12, big ? 14 : 12)
        c.roundedRectFill(r, radius: big ? 3 : 2, .blue1)
        c.roundedRectFill(r.insetBy(1, 1), radius: big ? 2 : 1, .blue3)
        c.hline(x: r.x + 2, y: r.y + 1, length: r.w - 4, .blue4)
        c.fill(ArtRect(r.x + 1, r.maxY - 4, r.w - 2, 3), .blue2)
        let g: [String] = big
            ? ["...#...", "..#.#..", "..#.#..", ".#####.", ".#...#.", "#.....#"]
            : ["..#..", ".#.#.", ".###.", "#...#"]
        stamp(&c, g, at: ArtPoint(r.x + (r.w - g[0].count) / 2, r.y + (big ? 4 : 3)), .neutral9)
    }

    static func drawDiskImage(_ c: inout PixelCanvas, _ n: Int) {
        let big = n >= 16
        let r = big ? ArtRect(1, 4, 14, 11) : ArtRect(0, 3, 12, 8)
        c.roundedRectFill(r, radius: 2, .neutral4)
        c.fill(ArtRect(r.x + 1, r.y + 1, r.w - 2, big ? 3 : 2), .neutral9)
        c.fill(ArtRect(r.x + 1, r.y + (big ? 4 : 3), r.w - 2, r.h - (big ? 5 : 4)), .neutral7)
        c.hline(x: r.x + 2, y: r.maxY - 3, length: r.w - 6, .neutral3)
        c.plot(r.maxX - 3, r.maxY - 3, .green4)
        // A disc peeking out of the top.
        c.ellipseFill(ArtRect(r.x + 3, r.y - (big ? 4 : 3), r.w - 6, big ? 6 : 5), .neutral8)
        c.plot(r.x + r.w / 2, r.y - (big ? 2 : 1), .neutral4)
        c.hline(x: r.x + 1, y: r.y + 1, length: r.w - 2, .neutral9)
    }

    // MARK: Overlays and minis

    /// The alias arrow (6×6), drawn over an icon's bottom-left corner.
    public static func aliasOverlay() -> SpriteAsset {
        var c = PixelCanvas(width: 6, height: 6)
        c.fill(c.bounds, .neutral9)
        c.stroke(c.bounds, .neutral3)
        c.line(from: ArtPoint(1, 4), to: ArtPoint(4, 1), .neutral0)
        c.hline(x: 2, y: 1, length: 3, .neutral0)
        c.vline(x: 4, y: 1, length: 3, .neutral0)
        return SpriteAsset("icon.alias", c, anchor: ArtPoint(0, 6))
    }

    /// The Finder tag stripe (3 px tall pill) under an icon.
    public static func tagStripe(_ ink: Ink, width: Int = 14) -> SpriteAsset {
        var c = PixelCanvas(width: width, height: 3)
        c.roundedRectFill(c.bounds, radius: 1, ink.darker())
        c.hline(x: 1, y: 0, length: width - 2, ink.lighter())
        c.hline(x: 1, y: 1, length: width - 2, ink)
        return SpriteAsset("icon.tag", c, anchor: .zero)
    }

    /// A 5×5 mini app icon for the phone screen.
    public static func mini(_ kind: IconKind) -> SpriteAsset {
        let ink = color(kind)
        var c = PixelCanvas(width: 5, height: 5)
        c.fill(ArtRect(0, 0, 5, 5), ink)
        c.hline(x: 0, y: 0, length: 5, ink.lighter())
        c.hline(x: 0, y: 4, length: 5, ink.darker())
        for p in [ArtPoint(0, 0), ArtPoint(4, 0), ArtPoint(0, 4), ArtPoint(4, 4)] { c.plot(p, .clear) }
        let glyph: Ink = (kind == .text || kind == .screenshot || kind == .dmg) ? .neutral3 : .neutral9
        switch kind {
        case .folder: c.hline(x: 1, y: 2, length: 3, glyph)
        case .pdf, .doc, .text, .code: c.hline(x: 1, y: 2, length: 3, glyph); c.hline(x: 1, y: 3, length: 2, glyph)
        case .image, .screenshot: c.plot(3, 1, .walnut5); c.hline(x: 1, y: 3, length: 3, .green2)
        case .video: c.vline(x: 2, y: 1, length: 3, glyph); c.plot(3, 2, glyph)
        case .audio: c.vline(x: 3, y: 1, length: 3, glyph); c.plot(2, 3, glyph)
        default: c.plot(2, 2, glyph)
        }
        return SpriteAsset("mini.\(kind.rawValue)", c, anchor: .zero)
    }
}

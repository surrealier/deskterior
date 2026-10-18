/// The juice kit (DESIGN §2.1): dust puff, sparkle, landing squash, text pops and the onboarding sticky note.
public enum FXArt {
    // MARK: Dust puff

    /// Five frames (16×12): a puff that billows out, rises and thins away.
    public static func dustPuff() -> SpriteAsset {
        let w = 16, h = 12
        // (x, y, diameter) per blob, per frame.
        let frames: [[(Int, Int, Int)]] = [
            [(5, 7, 4), (8, 8, 4)],
            [(2, 6, 6), (7, 5, 6), (10, 7, 5)],
            [(0, 5, 7), (5, 3, 7), (10, 5, 6), (6, 7, 5)],
            [(0, 3, 5), (6, 1, 5), (11, 3, 5)],
            [(1, 2, 2), (8, 0, 2), (13, 2, 2)],
        ]
        let images = frames.enumerated().map { i, blobs -> PixelBuffer in
            var c = PixelCanvas(width: w, height: h)
            for (x, y, d) in blobs { c.ellipseFill(ArtRect(x, y, d, d), i >= 3 ? .neutral7 : .neutral8) }
            for (x, y, d) in blobs where d >= 4 {
                c.ellipseFill(ArtRect(x + 1, y, d - 2, d - 2), i >= 3 ? .neutral8 : .neutral9)
            }
            if i == 3 { for (x, y, d) in blobs { c.ellipseFill(ArtRect(x + 1, y + 1, d - 2, d - 2), .clear) } }
            return c.buffer
        }
        return SpriteAsset("fx.puff", frames: images, anchor: ArtPoint(w / 2, h))
    }

    // MARK: Sparkle

    /// A twinkle (7×7, three frames): small cross, full star, fading diagonal glint.
    public static func sparkle() -> SpriteAsset {
        let art = [
            [".......", ".......", "...N...", "..N9N..", "...N...", ".......", "......."],
            ["...N...", "...N...", "..NBN..", "NNB9BNN", "..NBN..", "...N...", "...N..."],
            [".......", ".N...N.", "..N.N..", "...9...", "..N.N..", ".N...N.", "......."],
        ]
        let images = art.map { IndexedSprite($0.joined(separator: "\n")).render() }
        return SpriteAsset("fx.sparkle", frames: images, anchor: ArtPoint(3, 3))
    }

    // MARK: Squash

    /// The 3-frame landing squash of a token image (wide-short, tall-thin, rest), bottom-centred in 20×18.
    public static func squash(_ image: PixelBuffer) -> SpriteAsset {
        let canvas = ArtSize(20, 18)
        let sizes = [ArtSize(image.width + 3, image.height - 4), ArtSize(image.width - 2, image.height + 2), image.size]
        let frames = sizes.map { s -> PixelBuffer in
            var out = PixelBuffer(width: canvas.w, height: canvas.h)
            out.blit(ArtKit.resampled(image, to: s), at: ArtPoint((canvas.w - s.w) / 2, canvas.h - s.h))
            return out
        }
        return SpriteAsset("fx.squash", frames: frames, anchor: ArtPoint(canvas.w / 2, canvas.h))
    }

    // MARK: Text pops

    public enum Pop: String, CaseIterable, Sendable {
        case swish = "SWISH!"
        case bonk = "BONK"
        case tidy = "TIDY!"
    }

    /// Bold 7-px-tall letters for the pops.
    static let popGlyphs: [Character: [String]] = [
        "S": [".####", "##...", "##...", ".###.", "...##", "...##", "####."],
        "W": ["##...##", "##...##", "##.#.##", "##.#.##", "#######", ".##.##.", ".#...#."],
        "I": ["##", "##", "##", "##", "##", "##", "##"],
        "H": ["##.##", "##.##", "##.##", "#####", "##.##", "##.##", "##.##"],
        "!": ["##", "##", "##", "##", "##", "..", "##"],
        "B": ["####.", "##.##", "##.##", "####.", "##.##", "##.##", "####."],
        "O": [".###.", "##.##", "##.##", "##.##", "##.##", "##.##", ".###."],
        "N": ["##..##", "###.##", "######", "##.###", "##..##", "##..##", "##..##"],
        "K": ["##.##", "##.##", "####.", "###..", "####.", "##.##", "##.##"],
        "T": ["######", "######", "..##..", "..##..", "..##..", "..##..", "..##.."],
        "D": ["####.", "##.##", "##.##", "##.##", "##.##", "##.##", "####."],
        "Y": ["##..##", "##..##", ".####.", "..##..", "..##..", "..##..", "..##.."],
    ]

    /// A text pop: chunky letters with a lit top, a dark rim, and a little bounce between letters.
    public static func pop(_ pop: Pop) -> SpriteAsset {
        let (fill, light, dark, rim): (Ink, Ink, Ink, Ink)
        switch pop {
        case .swish: (fill, light, dark, rim) = (.blue4, .blue5, .blue3, .blue0)
        case .bonk: (fill, light, dark, rim) = (.red4, .red5, .red3, .red0)
        case .tidy: (fill, light, dark, rim) = (.green4, .green5, .green3, .green0)
        }
        let text = Array(pop.rawValue)
        let width = text.reduce(0) { $0 + popGlyphs[$1]![0].count + 1 } - 1
        var letters = PixelCanvas(width: width, height: 9)
        var x = 0
        for (i, ch) in text.enumerated() {
            let g = popGlyphs[ch]!
            let dy = [1, 0, 1, 2][i % 4]
            for (gy, row) in g.enumerated() {
                for (gx, cell) in row.enumerated() where cell == "#" {
                    letters.plot(x + gx, dy + gy, gy < 2 ? light : (gy == 6 ? dark : fill))
                }
            }
            x += g[0].count + 1
        }
        var c = PixelCanvas(width: width + 2, height: 12)
        // Drop shadow one pixel down, then the rim, then the letters.
        let rimmed = ArtKit.outline(letters.buffer, rim)
        c.blit(ArtKit.silhouette(rimmed, rim), at: ArtPoint(0, 1))
        c.blit(ArtKit.silhouette(letters.buffer, rim), at: ArtPoint(1, 2))
        c.blit(rimmed, at: .zero)
        c.blit(letters.buffer, at: ArtPoint(1, 1))
        return SpriteAsset("fx.pop.\(String(describing: pop))", c, anchor: ArtPoint(c.width / 2, c.height))
    }

    // MARK: Sticky note

    /// The onboarding sticky note frame: a yellow square with a curled corner and a strip of tape.
    public static func stickyNote(width: Int = 72, height: Int = 52) -> SpriteAsset {
        var c = PixelCanvas(width: width, height: height)
        drawStickyNote(&c, top: 3, curl: 6, face: .walnut5, light: .oak5, edge: .walnut4, curlInk: .walnut3)
        // Faint ruled lines.
        for y in stride(from: 3 + 12, to: height - 6, by: 8) { c.hline(x: 4, y: y, length: width - 12, .walnut4) }
        drawTape(&c, ArtRect(width / 2 - 10, 0, 20, 6))
        return SpriteAsset("fx.stickyNote", c, anchor: .zero)
    }

    /// A sticky note's paper filling the canvas below row `top`: the face, a lit top row and left column, a darker
    /// right column and bottom row, and the bottom-right corner curled up over `curl` px. The onboarding note and the
    /// partition's notes (`PartitionArt.notePaper`) share it.
    static func drawStickyNote(_ c: inout PixelCanvas, top: Int, curl n: Int, face: Ink, light: Ink, edge: Ink,
                               curlInk: Ink) {
        let width = c.width, height = c.height
        let body = ArtRect(0, top, width, height - top)
        c.fill(body, face)
        c.hline(x: 0, y: body.y, length: width, light)
        c.vline(x: 0, y: body.y, length: body.h, light)
        c.vline(x: width - 1, y: body.y, length: body.h, edge)
        c.hline(x: 0, y: height - 1, length: width, edge)
        // Curled bottom-right corner.
        for i in 0..<n {
            c.hline(x: width - n + i, y: height - 1 - i, length: n - i, .clear)
            c.plot(width - n - 1 + i, height - 1 - i, curlInk)
        }
        c.hline(x: width - n, y: height - n, length: 1, edge)
        for i in 0..<(n - 1) { c.hline(x: width - n, y: height - n + i, length: i + 1, edge) }
    }

    /// A strip of tape over `r`: lit along its top, its cut ends a step darker.
    static func drawTape(_ c: inout PixelCanvas, _ r: ArtRect) {
        c.fill(r, .neutral8)
        c.hline(x: r.x, y: r.y, length: r.w, .neutral9)
        c.vline(x: r.x, y: r.y, length: r.h, .neutral7)
        c.vline(x: r.maxX - 1, y: r.y, length: r.h, .neutral7)
    }
}

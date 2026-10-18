/// The desk partition (Erratum 31): the felt panel and its tower, the sticky-note cube, the daily memo pad, the memo
/// clips, the D-Day card, the clip light and the notes themselves. Every placed sprite is the size of its
/// `CoreLayout` rect. Lit from the top-left like the rest of the room: aluminium rails and posts catch the light on
/// their top and left, the felt sits a step in shadow under them.
public enum PartitionArt {
    // MARK: Panel

    /// The low panel, the tower, the clamps and the cube's ledge (`partition.panel`, 488×108).
    public static func panel() -> SpriteAsset { panelSprite }

    private static let panelSprite: SpriteAsset = {
        let r = CoreLayout.partition
        var c = PixelCanvas(width: r.w, height: r.h)
        func local(_ q: ArtRect) -> ArtRect { q.offsetBy(-r.x, -r.y) }
        let low = local(CoreLayout.partitionLow), tower = local(CoreLayout.partitionTower)

        // Felt: neutral7 with a fixed neutral6 speckle (in core px, so it does not move with the sprite), and the
        // frame's shadow along its top and left.
        for face in [CoreLayout.partitionFelt, CoreLayout.partitionTowerFelt] {
            for y in face.minY..<face.maxY {
                for x in face.minX..<face.maxX {
                    let speckle = (x * 7 + y * 13) % 8 == 0
                    let shade = y == face.minY || x == face.minX
                    c.plot(x - r.x, y - r.y, speckle || shade ? .neutral6 : .neutral7)
                }
            }
        }
        // Posts, then the rails over them: a lit top or left, the body, the underside.
        for x in [low.minX, low.maxX - 3] { drawPost(&c, x: x, y: low.y, height: low.h) }
        for x in [tower.minX, tower.maxX - 3] { drawPost(&c, x: x, y: tower.y, height: low.y - tower.y) }
        drawRail(&c, x: tower.x, y: tower.y, width: tower.w, inks: [.neutral8, .neutral6, .neutral5])
        drawRail(&c, x: low.x, y: low.y, width: low.w, inks: [.neutral8, .neutral6, .neutral5])
        drawRail(&c, x: low.x, y: low.maxY - 4, width: low.w, inks: [.neutral8, .neutral6, .neutral5, .neutral4])
        // End caps: the outer columns of the rails step down where they turn the corner.
        for (x, y, h) in [(low.minX, low.y, 3), (low.maxX - 1, low.y, 3), (low.minX, low.maxY - 4, 4),
                          (low.maxX - 1, low.maxY - 4, 4), (tower.minX, tower.y, 3), (tower.maxX - 1, tower.y, 3)] {
            c.vline(x: x, y: y + 1, length: h - 1, x == low.minX || x == tower.minX ? .neutral7 : .neutral4)
        }

        // The cube's ledge: a little oak shelf on the bottom rail, left of the plant.
        let ledge = ArtRect(CoreLayout.partitionFelt.minX, CoreLayout.partitionCube.maxY - 4, 21, 4).offsetBy(-r.x, -r.y)
        c.fill(ArtRect(ledge.x, ledge.y, ledge.w, 3), .oak2)
        c.hline(x: ledge.x, y: ledge.y, length: ledge.w, .oak3)
        c.hline(x: ledge.x, y: ledge.maxY - 1, length: ledge.w, .oak1)
        c.vline(x: ledge.maxX - 1, y: ledge.y + 1, length: 3, .oak1)
        c.hline(x: ledge.x + 1, y: ledge.maxY, length: ledge.w - 1, .neutral5)

        // Desk clamps on the back strip: a dark jaw with its screw.
        for clamp in CoreLayout.partitionClamps.map(local) {
            c.fill(ArtRect(clamp.x, clamp.y, clamp.w, 3), .neutral3)
            c.hline(x: clamp.x, y: clamp.y, length: clamp.w, .neutral4)
            c.hline(x: clamp.x + 1, y: clamp.maxY - 1, length: clamp.w - 2, .neutral2)
            c.fill(ArtRect(clamp.midX - 1, clamp.y + 1, 2, 2), .neutral5)
            c.plot(clamp.midX - 1, clamp.y + 1, .neutral6)
        }

        // The monitor's wall shadow carries on over the panel, a step darker (core x368–372, rows ≤ 141).
        for y in 0...(141 - r.y) {
            for x in (368 - r.x)...(372 - r.x) {
                if let ink = c.ink(at: x, y), !ink.isClear { c.plot(x, y, ink.darker()) }
            }
        }
        return SpriteAsset("partition.panel", c, anchor: .zero)
    }()

    /// A frame post `height` rows tall: a lit left column, the body, a shaded right column.
    static func drawPost(_ c: inout PixelCanvas, x: Int, y: Int, height: Int) {
        for (i, ink) in [Ink.neutral8, .neutral6, .neutral5].enumerated() { c.vline(x: x + i, y: y, length: height, ink) }
    }

    /// A rail `width` px long, one row per ink from the top.
    static func drawRail(_ c: inout PixelCanvas, x: Int, y: Int, width: Int, inks: [Ink]) {
        for (i, ink) in inks.enumerated() { c.hline(x: x, y: y + i, length: width, ink) }
    }

    // MARK: Cube

    /// The sticky-note cube (`partition.cube`, 18×18): a 16×14 block of stacked pads, yellow on top, its front banded
    /// in the note colours, standing on the panel's ledge.
    public static func cube() -> SpriteAsset {
        let r = CoreLayout.partitionCube
        var c = PixelCanvas(width: r.w, height: r.h)
        let block = ArtRect(1, 0, 16, 14)
        // Top face, its lit back edge, then the front's 2-px bands; the right edge a step down.
        c.fill(ArtRect(block.x, 0, block.w, 4), .walnut5)
        c.hline(x: block.x, y: 0, length: block.w, .oak5)
        c.vline(x: block.maxX - 1, y: 1, length: 3, .walnut4)
        let ramps: [Apollo.Ramp] = [.walnut, .purple, .blue, .green, .red]
        for (i, ramp) in ramps.enumerated() {
            let y = 4 + 2 * i
            c.fill(ArtRect(block.x, y, block.w - 1, 2), Ink(ramp: ramp, step: 5))
            c.vline(x: block.maxX - 1, y: y, length: 2, Ink(ramp: ramp, step: 4))
        }
        // The top sheet's front edge.
        c.hline(x: block.x, y: 4, length: block.w - 1, .walnut4)
        // Its shadow on the felt beside it and on the ledge under it.
        c.vline(x: block.maxX, y: 1, length: block.h - 1, .neutral6)
        c.hline(x: block.x + 1, y: block.maxY, length: block.w, .oak1)
        return SpriteAsset("partition.cube", c, anchor: .zero)
    }

    // MARK: Daily memo pad

    static let weekdayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    /// The daily memo pad for `day` (`partition.pad`, 38×44): the date header, the weekday, and rules or
    /// scribbles (`written`). The scene overlays today's first line at `padTextOrigin`, clipped to `padTextWidth`.
    public static func dailyPad(_ day: WallTime, written: Bool) -> SpriteAsset {
        let r = CoreLayout.partitionPad
        var c = PixelCanvas(width: r.w, height: r.h)
        // Header: the red binding with the date.
        c.fill(ArtRect(0, 0, r.w, 10), .red3)
        c.hline(x: 0, y: 0, length: r.w, .red4)
        c.hline(x: 0, y: 9, length: r.w, .red2)
        c.vline(x: r.w - 1, y: 1, length: 8, .red2)
        let date = "\(RoomArt.monthNames[day.month - 1]) \(day.day)"
        Digits.draw(date, at: ArtPoint((r.w - Digits.measure(date)) / 2, 3), .neutral9, into: &c)
        // Perforation, then the page.
        c.fill(ArtRect(0, 10, r.w, 29), .neutral9)
        for x in stride(from: 1, to: r.w, by: 2) { c.plot(x, 11, .neutral6) }
        let weekday = day.weekday
        let ink: Ink = weekday == 0 ? .red4 : weekday == 6 ? .blue3 : .neutral4
        Digits.draw(weekdayNames[weekday], at: ArtPoint(2, 13), ink, into: &c)
        if written {
            // Two lines of handwriting under the overlaid first line: words with gaps, their lengths from the day.
            for (k, y) in [32, 35].enumerated() {
                let end = 2 + (k == 0 ? 22 : 10) + ArtKit.noise(day.day, k, seed: UInt64(day.year * 13 + day.month), 12)
                var x = 2, w = 0
                while x < min(end, r.w - 3) {
                    let len = min(2 + ArtKit.noise(w, y, seed: UInt64(day.day), 5), min(end, r.w - 3) - x)
                    c.hline(x: x, y: y, length: len, .neutral5)
                    x += len + 1 + ArtKit.noise(y, w, seed: 7, 2)
                    w += 1
                }
            }
        } else {
            for y in [22, 27, 32] { c.hline(x: 2, y: y, length: 34, .neutral8) }
        }
        // Page edges, then the stack of pages under it.
        c.vline(x: 0, y: 10, length: 29, .neutral8)
        c.vline(x: r.w - 1, y: 10, length: 29, .neutral7)
        c.hline(x: 0, y: 39, length: r.w, .neutral8)
        c.hline(x: 0, y: 40, length: r.w, .neutral7)
        c.hline(x: 1, y: 41, length: r.w - 2, .neutral8)
        c.hline(x: 1, y: 42, length: r.w - 2, .neutral7)
        c.hline(x: 2, y: 43, length: r.w - 4, .neutral6)
        let name = "partition.pad.\(day.month)-\(day.day)" + (written ? ".written" : "")
        return SpriteAsset(name, c, anchor: .zero, hitRects: ["page": ArtRect(0, 10, r.w, 29)])
    }

    /// Where the scene writes today's first line on the pad (pad px), and how wide it may run.
    public static let padTextOrigin = ArtPoint(2, 19)
    public static let padTextWidth = 34

    /// Where the page-peel frames sit on the pad (pad px): over its page, below the perforation.
    public static let padPeelOrigin = ArtPoint(2, 12)

    /// Frame `frame` (0..<3) of a page curling off the pad (34×26), drawn at `padPeelOrigin` on the pad: the page's
    /// bottom-right corner folds up and over, further each frame, uncovering the page under it.
    public static func padPeel(_ frame: Int) -> SpriteAsset {
        let w = 34, h = 26
        let k = [7, 13, 20][min(max(frame, 0), 2)]
        var c = PixelCanvas(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                // a, b: distance from the bottom-right corner; the fold runs along a + b = k.
                let a = w - 1 - x, b = h - 1 - y
                if a + b < k { continue }
                let flap = a <= k && b <= k && a + b >= k
                if flap {
                    let edge = a == k || b == k || a + b == k
                    c.plot(x, y, edge ? .neutral7 : .neutral8)
                } else {
                    c.plot(x, y, .neutral9)
                }
            }
        }
        // The page lifts: its shadow falls in the corner it uncovered, along the fold.
        for i in 0...k {
            let x = w - 1 - i, y = h - 1 - (k - i) + 1
            if y < h { c.plot(x, y, .neutral8) }
        }
        return SpriteAsset("partition.padPeel.\(frame)", c, anchor: .zero)
    }

    // MARK: Memo clips

    /// The memo-clip wire with five binder clips (`partition.clips`, 80×22): the wire sags a pixel at the centre;
    /// each clip hangs over its card's top edge (cards `CoreLayout.memoClipCard(i)`, drawn under the clips).
    public static func clipsRail() -> SpriteAsset {
        let r = CoreLayout.partitionClips
        var c = PixelCanvas(width: r.w, height: r.h)
        // Wire: row 1 at the ends, sagging to row 2 round the middle clip.
        func wireY(_ x: Int) -> Int { abs(x - r.w / 2) < 10 ? 2 : 1 }
        for x in 1..<(r.w - 1) { c.plot(x, wireY(x), .neutral4) }
        // Its eyelets on the felt.
        for x in [0, r.w - 2] {
            c.fill(ArtRect(x, 0, 2, 3), .neutral3)
            c.plot(x, 0, .neutral5)
        }
        // Each clip hangs with the wire through its handles.
        for i in 0..<5 {
            let x = CoreLayout.memoClipCard(i).x - r.x + 4
            c.blit(binderClip, at: ArtPoint(x, wireY(x + 3) - 1))
        }
        return SpriteAsset("partition.clips", c, anchor: .zero)
    }

    /// A binder clip, 6×5: its wire handles folded up into a loop the wire runs through, over a dark jaw lit along
    /// its top.
    static let binderClip = IndexedSprite("""
        .4444.
        .4..4.
        233332
        222222
        222222
        """, ["4": .neutral4, "3": .neutral3, "2": .neutral2, ".": .clear]).render()

    /// A clipped file's card (14×16): paper, or a polaroid for an image; the scene blits the token's 12×12 mini at
    /// `clipCardMini`.
    public static func clipCard(image: Bool) -> SpriteAsset {
        var c = PixelCanvas(width: 14, height: 16)
        c.fill(c.bounds, .neutral9)
        if image {
            c.fill(ArtRect(1, 1, 12, 12), .neutral3)
        } else {
            c.hline(x: 3, y: 14, length: 7, .neutral8)
        }
        c.vline(x: 13, y: 0, length: 16, .neutral7)
        c.hline(x: 0, y: 15, length: 14, .neutral7)
        return SpriteAsset(image ? "partition.card.image" : "partition.card", c, anchor: .zero)
    }

    /// Where a card shows its file's 12×12 mini (card px).
    public static let clipCardMini = ArtPoint(1, 1)

    // MARK: D-Day card

    /// The D-Day card (`partition.dday`, 24×20) `days` before the D-Day (negative after it); nil (no D-Day) is
    /// `RoomPlan.blank`.
    public static func dDayCard(days: Int?) -> SpriteAsset {
        guard let days else { return RoomPlan.blank("partition.dday.none") }
        let r = CoreLayout.partitionDDay
        var c = PixelCanvas(width: r.w, height: r.h)
        // Kraft card, its edges a step down, its thickness under it.
        let card = ArtRect(0, 1, r.w - 1, r.h - 2)
        c.fill(card, .oak5)
        c.vline(x: card.maxX - 1, y: card.y, length: card.h, .oak4)
        c.hline(x: card.x, y: card.maxY - 1, length: card.w, .oak4)
        c.hline(x: card.x + 1, y: card.maxY, length: card.w, .oak3)
        c.vline(x: card.maxX, y: card.y + 1, length: card.h, .oak3)
        // A rule under the count, like the title line of a printed card.
        c.hline(x: 6, y: 16, length: card.w - 12, .oak4)
        let text = ddayText(days: days)
        let near = (0...7).contains(days)
        Digits.draw(text, at: ArtPoint((card.w - Digits.measure(text) + 1) / 2, 9), near ? .red4 : .neutral2, into: &c)
        // Red pushpin.
        c.fill(ArtRect(10, 0, 3, 3), .red4)
        c.plot(10, 0, .red5)
        c.plot(12, 2, .red3)
        return SpriteAsset("partition.dday.\(text)", c, anchor: .zero)
    }

    /// The D-Day card's text: "D-12" before the day, "D-DAY" on it, "D+3" after it (capped at 999).
    public static func ddayText(days: Int) -> String {
        if days > 0 { return "D-\(min(days, 999))" }
        if days == 0 { return "D-DAY" }
        return "D+\(-max(days, -999))"
    }

    // MARK: Clip light

    /// The clip light on the tower's top rail (`partition.clipLight`, 18×16): a spring clamp on the rail, a gooseneck,
    /// and a small shade aimed down at the felt with its bulb (`CoreLayout.partitionClipBulb`) lit when `on`.
    public static func clipLight(on: Bool) -> SpriteAsset {
        let r = CoreLayout.partitionClipLight
        var c = PixelCanvas(width: r.w, height: r.h)
        // The clamp: its body on the rail and its front jaw down over the rail's face (sprite row 14 is the rail's
        // top, core y64), a dark seam between them.
        let clamp = IndexedSprite("""
            ..4444..
            .433333.
            43333332
            .333332.
            .333332.
            """, ["4": .neutral4, "3": .neutral3, "2": .neutral2, ".": .clear])
        c.blit(clamp, at: ArtPoint(1, 11))
        c.hline(x: 2, y: 13, length: 6, .neutral2)
        // Gooseneck, lit on its upper side.
        c.line(from: ArtPoint(6, 11), to: ArtPoint(10, 4), .neutral4)
        c.line(from: ArtPoint(5, 11), to: ArtPoint(9, 4), .neutral5)
        // Shade, lit along its top and left, and the bulb's face in its mouth.
        let shade = IndexedSprite("""
            ...666...
            ..66555..
            .6655554.
            665555544
            655555544
            44.....44
            """, ["6": .neutral6, "5": .neutral5, "4": .neutral4, ".": .clear])
        c.blit(shade, at: ArtPoint(9, 2))
        let bulb = CoreLayout.partitionClipBulb.offsetBy(-r.x, -r.y)
        c.fill(bulb, on ? .walnut5 : .neutral7)
        c.plot(bulb.x, bulb.y, on ? .neutral9 : .neutral8)
        return SpriteAsset(on ? "partition.clipLight.on" : "partition.clipLight.off", c, anchor: .zero)
    }

    // MARK: Notes

    /// The face, edge and curl inks of a note colour: step 5, 4 and 3 of its ramp (yellow walnut, pink purple, sky
    /// blue, lime green, orange red, cream oak), and the highlight on its top row and left column.
    static func inks(_ c: NoteColour) -> (face: Ink, edge: Ink, curl: Ink, light: Ink) {
        let ramp: Apollo.Ramp = switch c {
        case .yellow: .walnut
        case .pink: .purple
        case .sky: .blue
        case .lime: .green
        case .orange: .red
        case .cream: .oak
        }
        return (Ink(ramp: ramp, step: 5), Ink(ramp: ramp, step: 4), Ink(ramp: ramp, step: 3),
                c == .yellow ? .oak5 : .neutral9)
    }

    /// A note's paper (30×24) in `c`, with a date flag (`dated`) and a pushpin (`pinned`, odd ids) or tape. Text is
    /// not in the sprite: the scene writes it in `noteTextInk` inside `PartitionLayout.textBand`.
    public static func notePaper(_ c: NoteColour, dated: Bool, pinned: Bool) -> SpriteAsset {
        let size = PartitionLayout.noteSize
        let i = inks(c)
        var canvas = PixelCanvas(width: size.w, height: size.h)
        FXArt.drawStickyNote(&canvas, top: 2, curl: 4, face: i.face, light: i.light, edge: i.edge, curlInk: i.curl)
        if pinned {
            canvas.fill(ArtRect(13, 0, 3, 3), .red4)
            canvas.plot(13, 0, .red5)
            canvas.plot(15, 2, .red3)
        } else {
            FXArt.drawTape(&canvas, ArtRect(9, 0, 12, 4))
        }
        if dated { canvas.fill(ArtRect(26, 18, 2, 2), .red4) }
        let name = "note.\(c.rawValue)" + (dated ? ".dated" : "") + (pinned ? ".pin" : "")
        return SpriteAsset(name, canvas, anchor: .zero)
    }

    /// The ink of a note's text.
    public static let noteTextInk = Ink.neutral2

    /// Frame `frame` (0..<4) of a note balled up on its way into the wastebasket: 12×10, 10×9, 8×8, 6×6.
    public static func noteCrumple(_ c: NoteColour, frame: Int) -> SpriteAsset {
        let f = min(max(frame, 0), crumpleArt.count - 1)
        let i = inks(c)
        let key: [Character: Ink] = ["L": i.light, "5": i.face, "4": i.edge, "3": i.curl, ".": .clear]
        let image = IndexedSprite(crumpleArt[f], key).render()
        return SpriteAsset("note.crumple.\(c.rawValue).\(f)", image, anchor: ArtPoint(image.width / 2, image.height))
    }

    /// Balled paper, largest first: flat facets in the face colour and its highlight (`L`) where they catch the light
    /// from the top-left, creases and the shaded underside in the darker steps.
    static let crumpleArt = [
        """
        ...L55.4....
        ..LL5545L4..
        .L5L54455L4.
        L55545LL5543
        L5L4555L5443
        .5545L554343
        L55455544543
        .4554443543.
        ..4433443...
        ....33333...
        """,
        """
        ..L55.4...
        .LL5455L4.
        L5L5445543
        L55L55L543
        .554L55443
        L554554343
        .45444443.
        ..433443..
        ....333...
        """,
        """
        ..L54...
        .L5L554.
        L5545L43
        L55L5543
        .5454443
        L5544343
        .443443.
        ..3333..
        """,
        """
        .L54..
        L5L543
        L55543
        .54443
        .4433.
        ..33..
        """,
    ]
}

import Foundation

/// What containers show of their contents (DESIGN §2.1 visibility matrix; E3–E8), as pure `PixelBuffer`s that
/// plug into the storage and prop art:
///
/// - drawers: 12-px kind icons standing in a fanned row at their `ContentJostle` rows once revealed
///   (`DrawerSim.isRevealed`; at rest, p ≥ 8), plain paper while they only peek; the cabinet's file drawer hangs
///   folders with kind-coloured tabs and initials;
/// - the riser cubby: the same icons as dim silhouettes;
/// - the phone: 5×5 minis; the pen cup: pen caps in kind colours; the wastebasket: balls in the heap slots.
///
/// A drawer's content buffer covers its whole interior (`contentSize`: the front's width less the walls, by
/// `travel − 1` rows); the art shows its bottom `p − 1` rows, nearest the front. Rows are y-down, so an item's
/// base row grows toward the front.
public enum InteriorRaster {
    /// One token as an interior draws it.
    public struct Item: Hashable, Sendable {
        public var kind: FileKind
        /// Display name (NFC); folder tabs show its initials.
        public var name: String
        /// Stable per-token seed: layout jitter and ball variants never reshuffle when other items change.
        public var seed: UInt64

        public init(kind: FileKind, name: String = "", seed: UInt64 = 0) {
            self.kind = kind
            self.name = name
            self.seed = seed
        }

        public init(key: TokenKey, meta: TokenMeta) {
            self.init(kind: meta.kind, name: meta.displayName, seed: InteriorRaster.seed(key))
        }
    }

    /// Mini icon size in drawers.
    public static let miniSize = 12

    /// A token's container members in order (bottom / back first).
    public static func items(_ id: ContainerID, in state: DeskState) -> [Item] {
        state.tokens.members(of: id).compactMap { key in state.tokens.meta(of: key).map { Item(key: key, meta: $0) } }
    }

    /// The art's icon kind for a file kind (same cases).
    public static func iconKind(_ kind: FileKind) -> IconKind {
        IconKind(rawValue: kind.rawValue) ?? .unknown
    }

    /// A deterministic seed for a token (FNV-1a of the volume, mixed with the inode).
    public static func seed(_ key: TokenKey) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in key.volume.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return SplitMix64.mix(h ^ key.inode)
    }

    // MARK: Drawers

    /// The size of a drawer's content buffer.
    public static func contentSize(_ id: ContainerID) -> ArtSize {
        precondition(id.isDrawer, "\(id) is not a drawer")
        let travel = Int(id.spec.travel ?? 1)
        let width = isRiser(id) ? CoreLayout.riserDrawerL.w - 4 : CoreLayout.cabinet.w - 8
        return ArtSize(width, travel - 1)
    }

    static func isRiser(_ id: ContainerID) -> Bool { id == .riserLeft || id == .riserRight }

    /// The rows an item's base may take (`ContentJostle` bounds): from a few rows back to the front wall.
    public static func baseBounds(_ id: ContainerID) -> ClosedRange<Float> {
        let h = Float(contentSize(id).h)
        if id == .cabinetFile { return 6...(h - 1) }
        return max(2, h - 6)...(h - 1)
    }

    /// Home positions (left x, base row) for `items`: minis fan across the drawer, front row with a little
    /// seeded scatter; file folders hang front to back (the last one nearest the front).
    public static func homes(_ id: ContainerID, items: [Item]) -> [ArtPoint] {
        let size = contentSize(id), n = items.count
        guard n > 0 else { return [] }
        let front = size.h - 1
        if id == .cabinetFile {
            let back = Int(baseBounds(id).lowerBound) + 2
            let pitch = n > 1 ? min(3, Float(front - back) / Float(n - 1)) : 0
            return (0..<n).map { i in
                ArtPoint(folderTabSlot(i, width: size.w), front - Int((Float(n - 1 - i) * pitch).rounded()))
            }
        }
        let span = size.w - miniSize
        let pitch = n > 1 ? min(Float(miniSize + 1), Float(span) / Float(n - 1)) : 0
        let used = Int((pitch * Float(n - 1)).rounded())
        let start = (span - used) / 2
        return items.enumerated().map { i, item in
            let jx = n > 1 && pitch >= 6 ? Int(item.seed % 3) - 1 : 0
            let jy = Int((item.seed >> 8) % 2)
            let x = min(max(start + Int((Float(i) * pitch).rounded()) + jx, 0), span)
            return ArtPoint(x, front - jy)
        }
    }

    /// Home base rows for `ContentJostle`.
    public static func jostleHomes(_ id: ContainerID, items: [Item]) -> [Float] {
        homes(id, items: items).map { Float($0.y) }
    }

    /// The drawer's content buffer at opening `p` with each item's base row moved by `offsets` (from
    /// `ContentJostle.pixelOffsets`; missing entries are 0). Icons show when `revealed` (pass
    /// `DrawerSim.isRevealed` while it moves; by default from `Visibility.drawerOpen`), else only paper.
    public static func drawerContents(
        _ id: ContainerID, items: [Item], offsets: [Int] = [], opening p: Int, revealed: Bool? = nil
    ) -> PixelBuffer {
        let size = contentSize(id)
        var c = PixelCanvas(width: size.w, height: size.h)
        let open = revealed ?? (Float(p) >= Visibility.drawerOpen)
        if id == .cabinetFile {
            drawFolders(&c, items: items, offsets: offsets, open: open)
            return c.buffer
        }
        let homes = homes(id, items: items)
        let bounds = baseBounds(id)
        let order = items.indices.sorted { a, b in
            let ya = base(homes[a].y, offsets, a, bounds), yb = base(homes[b].y, offsets, b, bounds)
            return ya != yb ? ya < yb : a < b
        }
        for i in order {
            let y = base(homes[i].y, offsets, i, bounds)
            let origin = ArtPoint(homes[i].x, y - miniSize + 1)
            if open {
                c.blit(KindIcons.icon(iconKind(items[i].kind), size: miniSize).image, at: origin)
            } else {
                drawPaper(&c, at: origin, seed: items[i].seed)
            }
        }
        return c.buffer
    }

    static func base(_ home: Int, _ offsets: [Int], _ i: Int, _ bounds: ClosedRange<Float>) -> Int {
        let y = home + (i < offsets.count ? offsets[i] : 0)
        return min(max(y, Int(bounds.lowerBound)), Int(bounds.upperBound))
    }

    /// Where each item is drawn (content px), back to front as drawn last-on-top, for hit-testing a drag out.
    public static func itemRects(_ id: ContainerID, items: [Item], offsets: [Int] = []) -> [ArtRect] {
        let homes = homes(id, items: items)
        let bounds = baseBounds(id)
        if id == .cabinetFile {
            return homes.indices.map { i in
                let y = base(homes[i].y, offsets, i, bounds)
                return ArtRect(homes[i].x, y - folderTab.h, folderTab.w, folderTab.h + 1)
            }
        }
        return homes.indices.map { i in
            ArtRect(homes[i].x, base(homes[i].y, offsets, i, bounds) - miniSize + 1, miniSize, miniSize)
        }
    }

    /// The topmost item under content point `p`, if any.
    public static func item(at p: ArtPoint, _ id: ContainerID, items: [Item], offsets: [Int] = []) -> Int? {
        let rects = itemRects(id, items: items, offsets: offsets)
        let bounds = baseBounds(id)
        let homes = homes(id, items: items)
        // Front-most (largest base row, then latest) first.
        let order = rects.indices.sorted { a, b in
            let ya = base(homes[a].y, offsets, a, bounds), yb = base(homes[b].y, offsets, b, bounds)
            return ya != yb ? ya > yb : a > b
        }
        return order.first { rects[$0].contains(p) }
    }

    /// A sheet of paper standing where a mini would (peek: the contents stay anonymous).
    static func drawPaper(_ c: inout PixelCanvas, at o: ArtPoint, seed: UInt64) {
        let w = miniSize - 2 - Int(seed % 3)
        let x = o.x + 1 + Int((seed >> 4) % 2)
        c.fill(ArtRect(x, o.y, w, miniSize), .neutral8)
        c.vline(x: x, y: o.y, length: miniSize, .neutral9)
        c.vline(x: x + w - 1, y: o.y, length: miniSize, .neutral6)
        for y in stride(from: o.y + 2 + Int((seed >> 6) % 2), to: o.y + miniSize - 1, by: 2) {
            c.hline(x: x + 2, y: y, length: w - 4, .neutral7)
        }
    }

    // MARK: File drawer

    /// A hanging folder's tab.
    public static let folderTab = ArtSize(13, 7)

    /// Five staggered tab positions across the drawer.
    static func folderTabSlot(_ i: Int, width: Int) -> Int {
        let slots = 5
        let pitch = (width - 2 - folderTab.w) / (slots - 1)
        return 1 + [0, 2, 4, 1, 3][i % slots] * pitch
    }

    /// Up to two initials from the start of a name, uppercased, when the tab font has them ("report.pdf" → "RE");
    /// "" when the name starts with a character it cannot draw (the tab then shows pseudo-text).
    public static func initials(_ name: String, maxWidth: Int = folderTab.w - 4) -> String {
        var out = ""
        for ch in name.uppercased().drop(while: { !($0.isLetter || $0.isNumber) }) {
            guard ch.isLetter || ch.isNumber, Digits.glyphs[ch] != nil else { break }
            guard Digits.measure(out + String(ch)) <= maxWidth else { break }
            out.append(ch)
            if out.count == 2 { break }
        }
        return out
    }

    /// Hanging folders back to front: each a coloured top edge across the drawer and a tab with initials.
    static func drawFolders(_ c: inout PixelCanvas, items: [Item], offsets: [Int], open: Bool) {
        let w = c.width, h = c.height
        // Floor and the two hanging rails.
        c.fill(.neutral5)
        c.hline(x: 0, y: 0, length: w, .neutral4)
        for y in [2, 3] { c.hline(x: 0, y: y, length: w, y == 2 ? .neutral7 : .neutral3) }
        let homes = homes(.cabinetFile, items: items)
        let bounds = baseBounds(.cabinetFile)
        let order = items.indices.sorted { a, b in
            let ya = base(homes[a].y, offsets, a, bounds), yb = base(homes[b].y, offsets, b, bounds)
            return ya != yb ? ya < yb : a < b
        }
        for i in order {
            let y = base(homes[i].y, offsets, i, bounds)
            let ink = open ? KindIcons.color(iconKind(items[i].kind)) : .neutral8
            // The folder's top edge with its shadow, hooks over the rails.
            c.hline(x: 1, y: y, length: w - 2, ink)
            c.plot(0, y, .neutral2)
            c.plot(w - 1, y, .neutral2)
            if y + 1 < h { c.hline(x: 1, y: y + 1, length: w - 2, ink.darker(2)) }
            // Tab.
            let t = ArtRect(homes[i].x, y - folderTab.h, folderTab.w, folderTab.h)
            if open {
                drawTab(&c, t, ink: ink, label: initials(items[i].name))
            } else {
                c.fill(ArtRect(t.x, t.y + 2, t.w, t.h - 2), .neutral8)
                c.hline(x: t.x, y: t.y + 2, length: t.w, .neutral9)
            }
        }
    }

    static func drawTab(_ c: inout PixelCanvas, _ t: ArtRect, ink: Ink, label: String) {
        c.fill(t, ink)
        c.hline(x: t.x, y: t.y, length: t.w, ink.lighter())
        c.vline(x: t.maxX - 1, y: t.y + 1, length: t.h - 1, ink.darker())
        c.plot(t.x, t.y, .clear)
        c.plot(t.maxX - 1, t.y, .clear)
        // White label insert with the initials.
        let lb = ArtRect(t.x + 2, t.y + 1, t.w - 4, Digits.height + 1)
        c.fill(lb, .neutral9)
        if label.isEmpty {
            c.hline(x: lb.x + 1, y: lb.y + 2, length: 5, .neutral5)
            c.hline(x: lb.x + 1, y: lb.y + 4, length: 3, .neutral5)
        } else {
            let tw = Digits.measure(label)
            Digits.draw(label, at: ArtPoint(lb.x + (lb.w - tw) / 2, lb.y + 1), .neutral1, into: &c)
        }
    }

    // MARK: Drawer sprites

    /// A riser drawer front at opening `p` with its contents (an overfull drawer shows paper poking out).
    public static func riserDrawer(
        _ id: ContainerID, p: Int, items: [Item], offsets: [Int] = [], revealed: Bool? = nil
    ) -> SpriteAsset {
        precondition(isRiser(id), "\(id) is not a riser drawer")
        let contents = items.isEmpty
            ? nil : drawerContents(id, items: items, offsets: offsets, opening: p, revealed: revealed)
        return StorageArt.riserDrawer(p: p, jammed: items.count > id.spec.capacity, contents: contents)
    }

    /// Cabinet drawers top → bottom.
    public static let cabinetDrawers: [ContainerID] = [.cabinetTop, .cabinetMiddle, .cabinetFile]

    /// The pedestal cabinet (geometry of `StorageArt.cabinet`) with each drawer pulled out by `p[i]` and showing
    /// `items[i]` (jostled by `offsets[i]`, icons per `revealed[i]`); overfull drawers show paper poking out.
    public static func cabinet(
        p: [Int], items: [[Item]], offsets: [[Int]] = [], revealed: [Bool?] = []
    ) -> SpriteAsset {
        let r = CoreLayout.cabinet, top = StorageArt.cabinetTopFace
        let opens = (0..<3).map { i in min(max(i < p.count ? p[i] : 0, 0), CoreLayout.cabinetTravels[i]) }
        let content = (0..<3).map { i in i < items.count ? items[i] : [] }
        let jammed = (0..<3).map { content[$0].count > cabinetDrawers[$0].spec.capacity }
        // The closed cabinet supplies the carcass, plinth and the shaded top face; the drawers are redrawn on it.
        var c = PixelCanvas(StorageArt.cabinet().image)
        let bodyH = r.h - CoreLayout.cabinetPlinth
        c.fill(ArtRect(0, top, r.w, bodyH), .neutral3)
        c.vline(x: 0, y: top, length: bodyH, .neutral5)
        c.vline(x: r.w - 1, y: top, length: bodyH, .neutral4)
        for i in stride(from: 2, through: 0, by: -1) {
            let f0 = CoreLayout.cabinetFront(i).offsetBy(-r.x, -r.y + top)
            let open = opens[i]
            StorageArt.drawCabinetDrawer(&c, front: f0, open: open, index: i, jammed: false)
            let id = cabinetDrawers[i]
            if open >= 2, !content[i].isEmpty || id == .cabinetFile {
                let buf = drawerContents(id, items: content[i], offsets: i < offsets.count ? offsets[i] : [],
                                         opening: open, revealed: i < revealed.count ? revealed[i] : nil)
                let rows = open - 1
                let shown = buf.cropped(to: ArtRect(0, buf.height - rows, buf.width, rows))
                c.blit(shown, at: ArtPoint(f0.x + 4, f0.y + 1))
                // The shadow under the drawer's back edge, as `StorageArt.drawInterior` draws it.
                c.hline(x: f0.x + 4, y: f0.y + 1, length: buf.width, .neutral4)
            }
            if jammed[i] { StorageArt.drawPaperPoking(&c, frontTop: f0.y + open, width: f0.w) }
        }
        // The desk's shadow over the top drawer's first rows (the top face above is already shaded).
        for y in top..<(top + 2) {
            for x in 0..<r.w {
                if let ink = c.ink(at: x, y), !ink.isClear { c.plot(x, y, ink.darker(1)) }
            }
        }
        let base = StorageArt.cabinet(p: opens)
        let name = "cabinet.interior.p\(opens.map(String.init).joined(separator: "-"))"
            + ".n\(content.map { String($0.count) }.joined(separator: "-"))"
        return SpriteAsset(name, c, anchor: base.anchor, hitRects: base.hitRects)
    }

    // MARK: Cubby

    /// The riser cubby's contents (28×12, `CoreLayout.riserCubby`): icons standing in two rows as dim
    /// silhouettes (names show only on hover).
    public static func cubby(_ items: [Item]) -> PixelBuffer {
        let size = CoreLayout.riserCubby.size
        var c = PixelCanvas(width: size.w, height: size.h)
        let rows: [(base: Int, level: Int)] = [(size.h - 3, 1), (size.h - 1, 2)]
        for (layer, row) in rows.enumerated() {
            let members = items.indices.filter { items.count < 3 ? layer == 1 : $0 % 2 == layer }
            let n = members.count
            guard n > 0 else { continue }
            let span = size.w - miniSize
            let pitch = n > 1 ? min(Float(miniSize + 1), Float(span) / Float(n - 1)) : 0
            let start = (span - Int((pitch * Float(n - 1)).rounded())) / 2 + (layer == 0 ? 1 : 0)
            for (k, i) in members.enumerated() {
                let icon = KindIcons.icon(iconKind(items[i].kind), size: miniSize).image
                let dim = relit(icon, level: row.level)
                c.blit(dim, at: ArtPoint(start + Int((Float(k) * pitch).rounded()), row.base - miniSize + 1))
            }
        }
        return c.buffer
    }

    /// `b` relit at `level` (cool): the deep-night tint.
    static func relit(_ b: PixelBuffer, level: Int) -> PixelBuffer {
        var out = b
        out.withUnsafeMutablePixels { px in
            for i in px.indices where px[i].a != 0 {
                px[i] = LightRamp.shared.mapColor(px[i], level: level, tint: .cool)
            }
        }
        return out
    }

    // MARK: Phone, pen cup, wastebasket

    /// 5×5 minis for the face-up phone (`PropArt.phoneStand(face:minis:)`), at most six.
    public static func phoneMinis(_ items: [Item]) -> [PixelBuffer] {
        items.prefix(ContainerSpec.phone.capacity).map { KindIcons.mini(iconKind($0.kind)).image }
    }

    /// Pen cap inks by kind (`PropArt.penCup(_:pens:)`), at most six.
    public static func penInks(_ items: [Item]) -> [Ink] {
        items.prefix(ContainerSpec.penCup.capacity).map { KindIcons.color(iconKind($0.kind)) }
    }

    /// The pen cup in `pose` holding `items`; tipping frames mirror for a cup tipping left.
    public static func penCup(_ pose: PropArt.PenCupPose, mirrored: Bool = false, items: [Item]) -> SpriteAsset {
        let s = PropArt.penCup(pose, pens: penInks(items))
        return mirrored ? SpriteAsset(s.name + ".mirrored", s.image.flippedHorizontally(), anchor: s.anchor,
                                      hitRects: s.hitRects) : s
    }

    /// Heap slots (basket-local top-left of each 8-px ball), filling bottom-up: ten fill the basket up to its
    /// mouth, and from the 11th (`WastebasketMachine.aboveRimCount`) the heap rises above the rim. Supersedes
    /// `PropArt.heapSlots`.
    public static let basketSlots: [ArtPoint] = {
        let rows: [(y: Int, xs: [Int])] = [
            (28, [4, 12, 20]), (20, [7, 15, 22]), (12, [5, 18]), (4, [9, 17]),
            (-3, [12, 3, 21]), (-4, [0, 24]), (-7, [8, 16]), (-9, [3, 21]), (-11, [12]), (-12, [6, 18]), (-13, [9, 15]),
        ]
        return rows.flatMap { row in row.xs.map { ArtPoint($0, row.y) } }
    }()

    /// How far the heap can rise above the basket's top (slots reach 13 px above it).
    public static let heapRise = 13

    /// The wastebasket heap: one crumpled ball per item in `basketSlots` (bottom first), in a buffer `heapRise` px
    /// taller than the basket; draw it at the basket's origin + `(0, −heapRise)` between `wastebasketBack` and
    /// `wastebasketFront`. `lift` raises the balls (a knock's jiggle).
    public static func heap(_ items: [Item], lift: Int = 0) -> PixelBuffer {
        let r = CoreLayout.wastebasket
        var c = PixelCanvas(width: r.w, height: r.h + heapRise)
        for (i, item) in items.prefix(basketSlots.count).enumerated() {
            let slot = basketSlots[i]
            c.blit(PropArt.paperBall(Int(item.seed % 3)).image, at: ArtPoint(slot.x, slot.y + heapRise - lift))
        }
        return c.buffer
    }

    /// The basket composed (back, heap, front), `heapRise` px taller than `CoreLayout.wastebasket`, anchored at
    /// the basket's foot. Balls inside show through the gaps of the wire mesh, shaded two steps (inside the
    /// basket, in its shadow), so fullness is visible below the rim too.
    public static func wastebasket(_ items: [Item], lift: Int = 0) -> SpriteAsset {
        let r = CoreLayout.wastebasket
        let balls = heap(items, lift: lift)
        let front = PropArt.wastebasketFront().image
        var out = PixelBuffer(width: r.w, height: r.h + heapRise)
        out.blit(PropArt.wastebasketBack().image, at: ArtPoint(0, heapRise))
        out.blit(balls, at: .zero)
        out.blit(front, at: ArtPoint(0, heapRise))
        let gap = Ink.neutral2.color
        for y in 0..<r.h {
            for x in 0..<r.w where front[x, y] == gap {
                let b = balls[x, y + heapRise]
                guard b.a != 0, let i = Apollo.index(of: b) else { continue }
                out[x, y + heapRise] = Ink(palette: i).darker(2).color
            }
        }
        return SpriteAsset("wastebasket.n\(items.count)", out, anchor: ArtPoint(r.w / 2, r.h + heapRise),
                           hitRects: ["mouth": ArtRect(0, heapRise, r.w, 6)])
    }

    /// The empty basket tipping toward the right (`right`) or left: `frame` 0…2 of the tip
    /// (`WastebasketMachine.tipFrame`), nil lying on its side (`WastebasketMachine.tippedRect`), mouth that way.
    /// It turns about the corner of its foot on that side: the tipping frames through three shears of whole-px rows
    /// (every pixel moves whole, none is lost or doubled), the lying one by an exact quarter turn. The sprite covers
    /// the whole swing; its anchor is the upright foot's centre.
    public static func wastebasketTipped(frame: Int?, right: Bool) -> SpriteAsset {
        let r = CoreLayout.wastebasket
        var upright = PixelBuffer(width: r.w, height: r.h)
        upright.blit(PropArt.wastebasketBack().image, at: .zero)
        upright.blit(PropArt.wastebasketFront().image, at: .zero)
        // The swing's box for a right tip (core px): the far top corner sweeps a circle about the foot corner.
        let reach = Int((Float(r.w * r.w + r.h * r.h)).squareRoot().rounded(.up))
        let box = ArtRect(r.minX, r.maxY - reach, r.w + reach, reach)
        let pivot = SIMD2(Float(r.maxX - box.x), Float(r.maxY - box.y))
        var out = PixelBuffer(width: box.w, height: box.h)
        guard let frame else {
            // Lying: a quarter turn clockwise about the foot's corner, top toward the right.
            for y in 0..<r.h {
                for x in 0..<r.w where upright[x, y].a != 0 {
                    out[Int(pivot.x) + r.h - 1 - y, Int(pivot.y) - r.w + x] = upright[x, y]
                }
            }
            return tippedSprite(out, frame: nil, right: right, foot: r.midX - box.x)
        }
        let a = Float([25, 55, 80][min(max(frame, 0), 2)]) * .pi / 180
        // Turning clockwise (top toward the right) by `a`: each output px maps back through the inverse shears.
        let alpha = Float(tan(Double(a / 2))), beta = -Float(sin(Double(a)))
        for oy in 0..<box.h {
            for ox in 0..<box.w {
                // Pixel centres, relative to the pivot (a corner between pixels).
                var x = Float(ox) + 0.5 - pivot.x, y = Float(oy) + 0.5 - pivot.y
                x = (x + alpha * y).rounded(.down) + 0.5
                y = (y + beta * x).rounded(.down) + 0.5
                x = (x + alpha * y).rounded(.down) + 0.5
                let sx = Int((x + pivot.x).rounded(.down)) - (r.minX - box.x)
                let sy = Int((y + pivot.y).rounded(.down)) - (r.minY - box.y)
                guard sx >= 0, sx < r.w, sy >= 0, sy < r.h else { continue }
                let px = upright[sx, sy]
                if px.a != 0 { out[ox, oy] = px }
            }
        }
        return tippedSprite(out, frame: frame, right: right, foot: r.midX - box.x)
    }

    /// A right-tip image as the sprite for that side, anchored at the upright foot's centre `foot`.
    static func tippedSprite(_ image: PixelBuffer, frame: Int?, right: Bool, foot: Int) -> SpriteAsset {
        let name = "wastebasket.tipped" + (frame.map { ".f\($0)" } ?? "") + (right ? ".right" : ".left")
        return right
            ? SpriteAsset(name, image, anchor: ArtPoint(foot, image.height))
            : SpriteAsset(name, image.flippedHorizontally(), anchor: ArtPoint(image.width - foot, image.height))
    }
}

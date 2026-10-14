/// Loose tokens as the desk and the floor show them (DESIGN §2.2 E11): a pile is up to three 16×16 icons standing on
/// the desk, each one behind 2 px up and to the right of the one in front, over a dithered contact shadow, with a
/// count tag from two tokens up; a floor token is one icon over its shadow. Pure, so the scene and tests draw the
/// same pixels.
public enum PileArt {
    /// A composed stack.
    public struct Stack: Equatable, Sendable {
        public var image: PixelBuffer
        /// The pixels that take clicks: the icons and the tag, not the shadow.
        public var hitMask: PixelBuffer
        /// Image px where the stack stands: the bottom centre of the front icon's square.
        public var base: ArtPoint
        /// Top-left of each icon's square in image px, front first.
        public var iconOrigins: [ArtPoint]
        /// The count tag and its top-left in image px (drawn into `image` unless the stack was made without it, for
        /// a scene that draws tags in a pass of their own).
        public var tag: PixelBuffer? = nil
        public var tagOrigin: ArtPoint = .zero
    }

    /// Icons drawn at most.
    public static let maxIcons = 3
    /// Each icon behind sits this far up and to the right.
    public static let step = 2
    /// Rows of shadow under the base.
    public static let shadowRows = 2

    /// The stack of `icons` (front first; at most `maxIcons` drawn) for a pile of `count` tokens. `shadow` is the
    /// shadow ink (one step darker than the surface: `oak3` on the desk, `oak1` on the floor), or nil for none.
    /// `lift` raises the icons off the shadow (a knock's hop), keeping the image size. With `drawsTag` false the tag
    /// is left out of `image` (it still takes clicks) and handed back in `tag`.
    public static func stack(_ icons: [PixelBuffer], count: Int, shadow: Ink? = .oak3, lift: Int = 0,
                             selected: Bool = false, drawsTag: Bool = true) -> Stack {
        let shown = Array(icons.prefix(maxIcons))
        let n = max(1, shown.count)
        let tag = count >= 2 ? Digits.badge("\(count)", fill: .red3, ink: .neutral9, rim: .red1) : nil
        let back = (n - 1) * step
        let lifted = max(0, lift)
        // A 2-px margin for the selection frame; the tag pokes 3 px above and right of the backmost icon.
        let m = 2
        let top = max(tag == nil ? 0 : 3, m) + lifted
        let front = ArtPoint(m, top + back)
        let tagX = tag.map { front.x + back + 16 + 3 - $0.width } ?? 0
        let w = max(front.x + back + 16 + m, tag.map { tagX + $0.width } ?? 0)
        let h = front.y + 16 + shadowRows
        var c = PixelCanvas(width: w, height: h)
        var mask = PixelCanvas(width: w, height: h)
        let base = ArtPoint(front.x + 8, front.y + 16)
        if let shadow {
            // The front icon's silhouette cast 2 px right and 1 px down onto the desk (the room is lit from the
            // top-left), only its lower rows: a standing card's shadow is short.
            let icon = shown.first ?? PixelBuffer(width: 16, height: 16)
            for y in 0..<icon.height {
                for x in 0..<icon.width where icon.pixel(x, y).a != 0 && front.y + y + 1 >= base.y - 6 {
                    c.plot(front.x + x + 2, front.y + y + 1, shadow)
                }
            }
        }
        if selected {
            // The screen's selection look: a blue square behind the front icon in a dark rounded frame.
            let r = ArtRect(front.x - 2, front.y - 2 - lifted, 20, 20)
            c.roundedRectFill(r, radius: 3, .blue0)
            c.roundedRectFill(r.insetBy(1, 1), radius: 2, Role.selection)
        }
        var origins: [ArtPoint] = []
        for i in (0..<shown.count).reversed() {
            let o = ArtPoint(front.x + i * step, front.y - i * step - lifted)
            c.blit(shown[i], at: o)
            mask.blit(shown[i], at: o)
            origins.insert(o, at: 0)
        }
        let tagOrigin = ArtPoint(tagX, top - 3 - lifted)
        if let tag {
            if drawsTag { c.blit(tag, at: tagOrigin) }
            mask.blit(tag, at: tagOrigin)
        }
        return Stack(image: c.buffer, hitMask: mask.buffer, base: base, iconOrigins: origins, tag: tag,
                     tagOrigin: tagOrigin)
    }

    /// `image` over its contact shadow in `ink`: its silhouette's lowest `rows` rows cast 2 px right and 1 px down
    /// (as a pile's), in an image 2 px wider and 1 px taller with the same top-left.
    public static func castShadow(of image: PixelBuffer, ink: Ink, rows: Int = 6) -> PixelBuffer {
        var c = PixelCanvas(width: image.width + 2, height: image.height + 1)
        let bottom = image.opaqueBounds().maxY
        for y in max(0, bottom - rows)..<image.height {
            for x in 0..<image.width where image.pixel(x, y).a != 0 { c.plot(x + 2, y + 1, ink) }
        }
        c.blit(image, at: .zero)
        return c.buffer
    }

    /// The 3-frame landing squash of `image` (DESIGN §2.1 juice: wide and short, tall and thin, at rest), each
    /// frame bottom-centred in the same `(w + 4) × (h + 2)` canvas, so the image's bottom centre stays put.
    /// `amount` (0…2) scales it with the impact: 2 squashes by 4 rows, 1 by 2, 0 not at all. Frames are made by
    /// dropping or repeating whole interior rows and columns (`reshaped`), so the 1-px outline survives.
    public static func squash(_ image: PixelBuffer, amount: Int = 2) -> [PixelBuffer] {
        let w = image.width, h = image.height, a = min(max(amount, 0), 2)
        let canvas = ArtSize(w + 4, h + 2)
        let sizes = a == 0 ? [image.size, image.size, image.size]
            : [ArtSize(w + a + 1, max(1, h - 2 * a)), ArtSize(max(1, w - a), h + a), image.size]
        return sizes.map { s in
            var out = PixelBuffer(width: canvas.w, height: canvas.h)
            out.blit(reshaped(image, to: s), at: ArtPoint((canvas.w - s.w) / 2, canvas.h - s.h))
            return out
        }
    }

    /// `image` at `size` by dropping or repeating whole rows and columns from the middle of its opaque box (rows and
    /// columns that repeat their neighbour first), never resampling: outlines, which sit at the box's edges, stay.
    public static func reshaped(_ image: PixelBuffer, to size: ArtSize) -> PixelBuffer {
        let box = image.opaqueBounds()
        guard box.w > 0, box.h > 0 else { return PixelBuffer(width: size.w, height: size.h) }
        let rows = lineMap(count: image.height, to: size.h, inside: box.minY..<box.maxY) { y in
            y > 0 && (0..<image.width).allSatisfy { image.pixel($0, y) == image.pixel($0, y - 1) }
        }
        let cols = lineMap(count: image.width, to: size.w, inside: box.minX..<box.maxX) { x in
            x > 0 && (0..<image.height).allSatisfy { image.pixel(x, $0) == image.pixel(x - 1, $0) }
        }
        var out = PixelBuffer(width: size.w, height: size.h)
        for (ty, sy) in rows.enumerated() {
            for (tx, sx) in cols.enumerated() { out[tx, ty] = image[sx, sy] }
        }
        return out
    }

    /// Source line for each of `target` lines out of `count`: drops or repeats lines inside `box` (never its first
    /// two or last two), repeats-of-a-neighbour first, then nearest the middle.
    static func lineMap(count: Int, to target: Int, inside box: Range<Int>, repeats: (Int) -> Bool) -> [Int] {
        guard target != count, count > 0 else { return Array(0..<count) }
        let inner = box.count > 4 ? Array((box.lowerBound + 2)..<(box.upperBound - 2)) : Array(box)
        let mid = Float(box.lowerBound + box.upperBound - 1) / 2
        let ranked = inner.sorted { a, b in
            let ra = repeats(a), rb = repeats(b)
            if ra != rb { return ra }
            let da = abs(Float(a) - mid), db = abs(Float(b) - mid)
            return da != db ? da < db : a < b
        }
        var picks: [Int] = []
        let n = abs(target - count)
        // Spread repeats over the candidates; drops never take a line twice.
        while picks.count < n, !ranked.isEmpty {
            for line in ranked where picks.count < n {
                if target < count, picks.contains(line) { continue }
                picks.append(line)
            }
            if target < count { break }
        }
        if target < count {
            let dropped = Set(picks)
            var out = (0..<count).filter { !dropped.contains($0) }
            while out.count > target { out.remove(at: out.count / 2) }
            return out
        }
        var out: [Int] = []
        for line in 0..<count {
            out.append(line)
            out += Array(repeating: line, count: picks.filter { $0 == line }.count)
        }
        return out
    }
}

extension PropArt {
    /// The empty pen cup as it stands on the desk: over its contact shadow (`PileArt.castShadow`, as the scene's cup
    /// draws it wherever it is moved), its top-left where `penCup()`'s is.
    public static func penCupOnDesk() -> SpriteAsset {
        let cup = penCup()
        return SpriteAsset(cup.name + ".onDesk", PileArt.castShadow(of: cup.image, ink: .oak3, rows: penCupShadowRows),
                           anchor: cup.anchor, hitRects: cup.hitRects)
    }

    /// Rows of the cup's silhouette that cast its contact shadow.
    public static let penCupShadowRows = 4
}

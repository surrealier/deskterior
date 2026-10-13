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
    }

    /// Icons drawn at most.
    public static let maxIcons = 3
    /// Each icon behind sits this far up and to the right.
    public static let step = 2
    /// Rows of shadow under the base.
    public static let shadowRows = 2

    /// The stack of `icons` (front first; at most `maxIcons` drawn) for a pile of `count` tokens. `shadow` is the
    /// shadow ink (one step darker than the surface: `oak3` on the desk, `oak1` on the floor), or nil for none.
    /// `lift` raises the icons off the shadow (a knock's hop), keeping the image size.
    public static func stack(_ icons: [PixelBuffer], count: Int, shadow: Ink? = .oak3, lift: Int = 0,
                             selected: Bool = false) -> Stack {
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
        if let tag {
            let o = ArtPoint(tagX, top - 3 - lifted)
            c.blit(tag, at: o)
            mask.blit(tag, at: o)
        }
        return Stack(image: c.buffer, hitMask: mask.buffer, base: base, iconOrigins: origins)
    }

    /// The 3-frame landing squash of `image` (DESIGN §2.1 juice: wide and short, tall and thin, at rest), each
    /// frame bottom-centred in the same `(w + 4) × (h + 2)` canvas, so the image's bottom centre stays put.
    public static func squash(_ image: PixelBuffer) -> [PixelBuffer] {
        let w = image.width, h = image.height
        let canvas = ArtSize(w + 4, h + 2)
        let sizes = [ArtSize(w + 3, max(1, h - 4)), ArtSize(max(1, w - 2), h + 2), image.size]
        return sizes.map { s in
            var out = PixelBuffer(width: canvas.w, height: canvas.h)
            out.blit(ArtKit.resampled(image, to: s), at: ArtPoint((canvas.w - s.w) / 2, canvas.h - s.h))
            return out
        }
    }
}

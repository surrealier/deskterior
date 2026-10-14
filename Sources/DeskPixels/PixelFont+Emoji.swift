import DeskCore

/// Colour emoji and variation selectors in the glyph fallback (DESIGN §1.4, M10 review): an emoji is snapped to
/// Apollo by its lightness first and keeps a light rim where its own edge is dark, and a variation selector no
/// font maps falls back to its base character before the box does.
extension PixelFont {
    /// U+FE0E (text presentation) and U+FE0F (emoji presentation).
    static let variationSelectors: Set<Unicode.Scalar> = ["\u{FE0E}", "\u{FE0F}"]

    /// `c` without its variation selectors, if it had any (and something is left).
    static func strippingVariationSelectors(_ c: Character) -> Character? {
        guard c.unicodeScalars.contains(where: variationSelectors.contains) else { return nil }
        let rest = String(String.UnicodeScalarView(c.unicodeScalars.filter { !variationSelectors.contains($0) }))
        return rest.count == 1 ? rest.first : nil
    }

    /// The base character of a text-presentation sequence ("☺︎", "✈︎"): it asks for the plain glyph, which the
    /// pixel font or the system font draws in the text colour.
    static func textPresentationBase(_ c: Character) -> Character? {
        c.unicodeScalars.contains("\u{FE0E}") ? strippingVariationSelectors(c) : nil
    }

    /// How much lightness outweighs a/b when snapping an emoji: at 9 px an emoji reads by its lights and darks, so
    /// its light and dark parts keep their lightness before their exact hue (Apple's 😀 still shades from light
    /// yellow to its own orange).
    static let emojiLightnessWeight = 2.0

    /// Snaps every opaque pixel to the Apollo colour nearest by `emojiLightnessWeight`-weighted OKLab distance.
    static func snapEmoji(_ b: PixelBuffer) -> PixelBuffer {
        var out = PixelBuffer(width: b.width, height: b.height)
        var cache: [UInt32: RGBA8] = [:]
        for y in 0..<b.height {
            for x in 0..<b.width {
                let c = b.pixel(x, y)
                guard c.a != 0 else { continue }
                if let hit = cache[c.rgbHex] {
                    out[x, y] = hit
                    continue
                }
                let lab = OKLab(c)
                var best = 0, bestD = Double.infinity
                for (i, p) in Apollo.oklab.enumerated() {
                    let dL = lab.L - p.L, da = lab.a - p.a, db = lab.b - p.b
                    let d = emojiLightnessWeight * dL * dL + da * da + db * db
                    if d < bestD { (best, bestD) = (i, d) }
                }
                cache[c.rgbHex] = Apollo.colors[best]
                out[x, y] = Apollo.colors[best]
            }
        }
        return out
    }

    /// Below this OKLab lightness an emoji's rim pixel would vanish into a dark label (`090a14`…`394a50`).
    static let emojiRimMinimumL = 0.45
    /// What a dark rim pixel becomes: a mid grey that reads on the label's dark plate.
    static let emojiRim = Ink.neutral5

    /// Lifts dark pixels on an emoji's rim (next to a clear pixel or the edge) to `emojiRim`, so a black cat, a
    /// black heart or ⬛ keeps an outline on the dark label; dark features inside it (eyes, a mouth) stay.
    static func liftDarkRim(_ b: PixelBuffer) -> PixelBuffer {
        var out = b
        for y in 0..<b.height {
            for x in 0..<b.width {
                let c = b.pixel(x, y)
                guard c.a != 0, OKLab(c).L < emojiRimMinimumL else { continue }
                let rim = b.pixel(x - 1, y).a == 0 || b.pixel(x + 1, y).a == 0 || b.pixel(x, y - 1).a == 0
                    || b.pixel(x, y + 1).a == 0
                if rim { out[x, y] = emojiRim.color }
            }
        }
        return out
    }
}

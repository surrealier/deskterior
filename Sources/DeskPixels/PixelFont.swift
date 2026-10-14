import CoreGraphics
import CoreText
import DeskCore
import Foundation

/// A pixel font rasterized by CoreText at its native size (1 font px = 1 art px) with anti-aliasing,
/// smoothing and subpixel positioning off, then thresholded to **binary alpha**.
///
/// Text is NFC-normalized first (Galmuri has no conjoining jamo) and laid out one `Character` at a time on
/// integer advances, without kerning, so `measure` matches `TextLayout`'s per-character model. The rendered
/// width is `measure` plus any ink that overhangs the ends (`overhang(of:)`, e.g. a leading "ĥ"). Characters
/// the font lacks fall back to the system font at the same size (also without anti-aliasing; then its
/// non-colour cascade fonts); colour emoji are drawn large, area-averaged down to a small square on the
/// baseline and snapped to Apollo with binary alpha (they keep their own colours whatever the text colour); a
/// variation selector no font maps is dropped for its base character; a hollow box stands in for anything that
/// still draws nothing.
///
/// Verified against Galmuri9's BDF: CoreText reproduces the designed bitmaps exactly (ASCII, Latin-1/Ext-A,
/// kana, all 11,172 Hangul syllables). Glyph bitmaps are cached and the type is thread-safe (`CTFont` is
/// immutable and thread-safe but not annotated `Sendable`; the glyph cache is lock-protected).
public final class PixelFont: @unchecked Sendable {
    /// Where a character's pixels come from.
    public enum GlyphSource: Sendable, Equatable {
        case primary
        case systemFallback
        /// A colour emoji, pixelated to Apollo (its own colours, not the text's).
        case colorFallback
        case box
    }

    /// Font size in px.
    public let pixelSize: Int
    /// Height of every rendered line (and of `render`'s buffer).
    public let lineHeight: Int
    /// Rows above the baseline in a line: glyphs stand on the top edge of row `baseline`. The rows below it
    /// hold the font's deepest descent (its bounding box), so cedillas, ogoneks and "¿" are never cut.
    public let baseline: Int

    private let primary: CTFont
    private let fallback: CTFont?
    private let cache = FontRegistry.LockedCache<Character, Glyph>()

    /// Galmuri9 (10 px; 15-px line, baseline 12) from `Resources/Fonts`; nil if the font file cannot be found or
    /// loaded, which is reported through `ResourceLocator.reportMissing`.
    ///
    /// The line box holds 12 rows above the baseline (accented capitals, "Ǻ", Vietnamese "ấ") and 3 below
    /// ("ç", "ą", "¿", "ș"); only stacked capital Vietnamese marks such as "Ấ" (13–14 rows) lose their top.
    public static let galmuri9: PixelFont? = {
        guard let url = ResourceLocator.fontURL(named: "Galmuri9.ttf"),
              let font = PixelFont(url: url, pixelSize: 10, lineHeight: 15)
        else {
            ResourceLocator.reportMissing("Galmuri9.ttf")
            return nil
        }
        return font
    }()

    /// Loads the font file at `url` (see `FontRegistry`); nil if it is not a readable font.
    public convenience init?(url: URL, pixelSize: Int, lineHeight: Int) {
        guard let font = FontRegistry.font(at: url, size: CGFloat(pixelSize)) else { return nil }
        self.init(font: font, pixelSize: pixelSize, lineHeight: lineHeight)
    }

    /// Wraps an existing `CTFont`, which should already be at `pixelSize`.
    public init(font: CTFont, pixelSize: Int, lineHeight: Int) {
        precondition(pixelSize > 0 && lineHeight > 0, "PixelFont needs a positive size and line height")
        self.pixelSize = pixelSize
        self.lineHeight = lineHeight
        self.primary = font
        self.fallback = CTFontCreateUIFontForLanguage(.system, CGFloat(pixelSize), nil)
        // The bounding box, not the descent metric (Galmuri9: descent 1, but glyphs reach 3 rows below).
        // Pixel fonts have whole-pixel bounds; Galmuri9 → 3 rows below, baseline 12 in a 15-px line.
        let descent = Int((-CTFontGetBoundingBox(font).minY).rounded())
        self.baseline = min(lineHeight, max(0, lineHeight - descent))
    }

    // MARK: Measuring

    /// Advance of one character in px (after NFC normalization).
    public func advance(of c: Character) -> Int {
        TextLayout.nfc(String(c)).reduce(0) { $0 + glyph($1).advance }
    }

    /// Width of `s` in px: the sum of its advances. `render(s, color:).width` adds `overhang(of: s)`.
    public func measure(_ s: String) -> Int {
        TextLayout.nfc(s).reduce(0) { $0 + glyph($1).advance }
    }

    /// Columns of ink that `s` draws left of its first pen position and right of its last advance (usually
    /// zero; a leading "ĥ" or "Į" overhangs 1 px to the left).
    public func overhang(of s: String) -> (left: Int, right: Int) {
        let line = layout(s)
        return (line.left, line.right)
    }

    /// Which font draws `c` (after NFC normalization).
    public func source(of c: Character) -> GlyphSource {
        TextLayout.nfc(String(c)).first.map { glyph($0).source } ?? .primary
    }

    // MARK: Rendering

    /// One line of text in `color` on transparent, `lineHeight` tall and `measure(s)` wide plus the ink that
    /// overhangs either end (`overhang(of:)`). The pen starts at x = `overhang(of: s).left`, so place the buffer
    /// that many px left of where the text should start.
    public func render(_ s: String, color: RGBA8) -> PixelBuffer {
        let line = layout(s)
        var out = PixelBuffer(width: line.left + line.advance + line.right, height: lineHeight)
        var pen = line.left
        for g in line.glyphs {
            g.stamp(into: &out, penX: pen, color: color)
            pen += g.advance
        }
        return out
    }

    /// Glyphs of `s`, their total advance and the ink overhanging each end.
    private func layout(_ s: String) -> (glyphs: [Glyph], advance: Int, left: Int, right: Int) {
        let glyphs = TextLayout.nfc(s).map(glyph)
        var pen = 0, minInk = 0, maxInk = 0
        for g in glyphs {
            if let ink = g.ink {
                minInk = min(minInk, pen + ink.lowerBound)
                maxInk = max(maxInk, pen + ink.upperBound)
            }
            pen += g.advance
        }
        return (glyphs, pen, -minInk, max(0, maxInk - pen))
    }

    /// `render` plus an optional 1-px drop shadow down-right; with a shadow the buffer is 1 px wider and taller.
    /// (Colour emoji keep their own colours; only their silhouette casts the shadow.)
    public func renderLabel(_ s: String, color: RGBA8, shadow: RGBA8?) -> PixelBuffer {
        let text = render(s, color: color)
        guard let shadow else { return text }
        var out = PixelBuffer(width: text.width + 1, height: text.height + 1)
        for y in 0..<text.height {
            for x in 0..<text.width where text.pixels[y * text.width + x].a != 0 {
                out[x + 1, y + 1] = shadow
            }
        }
        out.blit(text, at: .zero)
        return out
    }

    // MARK: Glyphs

    /// Extra columns kept on each side of a glyph's advance cell for ink that overhangs it (combining marks).
    private static let cellMargin = 4
    private static let maxCachedGlyphs = 8192

    private struct Glyph: Sendable {
        let advance: Int
        /// `(advance + 2 * cellMargin) × lineHeight`, row-major from the top; true = ink.
        let mask: [Bool]
        let maskWidth: Int
        let source: GlyphSource
        /// The glyph's own colour per mask cell (colour emoji); nil draws the text colour.
        let colors: [RGBA8]?
        /// Columns holding ink, relative to the pen (may start below 0 or end past `advance`); nil if blank.
        let ink: Range<Int>?

        init(advance: Int, mask: [Bool], maskWidth: Int, source: GlyphSource, colors: [RGBA8]? = nil) {
            self.advance = advance
            self.mask = mask
            self.maskWidth = maskWidth
            self.source = source
            self.colors = colors
            let inked = (0..<maskWidth).filter { x in stride(from: x, to: mask.count, by: maskWidth).contains { mask[$0] } }
            if let first = inked.first, let last = inked.last {
                ink = (first - PixelFont.cellMargin)..<(last + 1 - PixelFont.cellMargin)
            } else {
                ink = nil
            }
        }

        func stamp(into out: inout PixelBuffer, penX: Int, color: RGBA8) {
            let height = mask.count / max(1, maskWidth)
            for y in 0..<min(height, out.height) {
                for mx in 0..<maskWidth where mask[y * maskWidth + mx] {
                    out.set(penX - PixelFont.cellMargin + mx, y, colors?[y * maskWidth + mx] ?? color)
                }
            }
        }
    }

    private func glyph(_ c: Character) -> Glyph {
        if let hit = cache[c] { return hit }
        let g = makeGlyph(c)
        if cache.count >= Self.maxCachedGlyphs { cache.removeAll() }
        return cache.insertIfAbsent(g, for: c)
    }

    private func makeGlyph(_ c: Character) -> Glyph {
        if c.isNewline || c == "\t" { return glyph(" ") }
        // Text presentation ("☺︎", "✈︎") asks for the plain glyph of its base character.
        if let base = Self.textPresentationBase(c) { return glyph(base) }
        if let g = designed(c) { return g }
        if let g = rasterize(c, font: primary, source: .primary) { return g }
        if let fallback {
            if let g = rasterize(c, font: fallback, source: .systemFallback) { return g }
            // The system font's cascade (other scripts), skipping colour fonts: emoji become boxes.
            let s = String(c) as CFString
            let cascade = CTFontCreateForString(fallback, s, CFRange(location: 0, length: CFStringGetLength(s)))
            if !CTFontGetSymbolicTraits(cascade).contains(.traitColorGlyphs) {
                if let g = rasterize(c, font: cascade, source: .systemFallback) { return g }
            } else if let g = rasterizeColor(c, font: cascade) {
                return g
            }
        }
        // A variation selector no font maps: the base character before the box.
        if let base = Self.strippingVariationSelectors(c) { return glyph(base) }
        return boxGlyph()
    }

    /// Colour emoji are drawn at this many times their final size, then area-averaged down.
    private static let colorOversample = 6

    /// A colour emoji (`font` is a colour font, e.g. Apple Color Emoji): drawn large through a `CTLine` (so ZWJ
    /// sequences, flags and skin tones shape as one picture), trimmed to its ink, reduced into a `pixelSize`
    /// square standing on the baseline (`featureAverage`, so eyes and outlines survive), alpha thresholded,
    /// snapped to Apollo by lightness first (`snapEmoji`) and given a light rim where its edge is dark
    /// (`liftDarkRim`). Nil when nothing is drawn.
    private func rasterizeColor(_ c: Character, font: CTFont) -> Glyph? {
        let box = max(3, min(baseline, pixelSize))
        let big = CTFontCreateCopyWithAttributes(font, CGFloat(box * Self.colorOversample), nil, nil)
        let text = NSAttributedString(string: String(c), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): big])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let pad = 4
        let w = Int(width.rounded(.up)) + 2 * pad, h = Int((ascent + descent).rounded(.up)) + 2 * pad
        guard width > 0, let ctx = CGBridge.makeContext(width: w, height: h) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        ctx.textPosition = CGPoint(x: CGFloat(pad), y: CGFloat(pad) + descent)
        CTLineDraw(line, ctx)
        guard let drawn = CGBridge.pixelBuffer(from: ctx) else { return nil }
        let bounds = IconPixelator.alphaBounds(drawn, minAlpha: 32)
        guard !bounds.isEmpty else { return nil }
        let fit = IconPixelator.fitted(bounds.size, into: ArtSize(box, box))
        let snapped = Self.liftDarkRim(Self.snapEmoji(Self.featureAverage(drawn.cropped(to: bounds), to: fit)))
        guard !snapped.opaqueBounds().isEmpty else { return nil }

        let advance = fit.w + 1
        let cellWidth = advance + 2 * Self.cellMargin
        var mask = [Bool](repeating: false, count: cellWidth * lineHeight)
        var colors = [RGBA8](repeating: .clear, count: cellWidth * lineHeight)
        let top = baseline - fit.h
        for y in 0..<fit.h where top + y >= 0 && top + y < lineHeight {
            for x in 0..<fit.w {
                let px = snapped.pixel(x, y)
                guard px.a != 0 else { continue }
                let i = (top + y) * cellWidth + Self.cellMargin + x
                mask[i] = true
                colors[i] = px
            }
        }
        return Glyph(advance: advance, mask: mask, maskWidth: cellWidth, source: .colorFallback, colors: colors)
    }

    /// Area-averages `big` down to `size` with binary alpha (`IconPixelator.alphaThreshold`), except that a pixel
    /// whose source block holds a dark feature (at least a fifth of it more than 0.25 OKLab L below the block's
    /// average: an eye, a mouth, an outline) takes that feature's average colour, so it is not washed out.
    static func featureAverage(_ big: PixelBuffer, to size: ArtSize) -> PixelBuffer {
        var out = Quantizer.thresholdAlpha(Quantizer.areaAverage(big, to: size), at: IconPixelator.alphaThreshold)
        for y in 0..<size.h {
            for x in 0..<size.w where out.pixel(x, y).a != 0 {
                let x0 = x * big.width / size.w, x1 = max(x0 + 1, (x + 1) * big.width / size.w)
                let y0 = y * big.height / size.h, y1 = max(y0 + 1, (y + 1) * big.height / size.h)
                let mean = OKLab(out.pixel(x, y)).L
                var n = 0, dark = 0, r = 0, g = 0, b = 0
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        let c = big.pixel(xx, yy)
                        guard c.a > 128 else { continue }
                        n += 1
                        guard OKLab(c).L < mean - 0.25 else { continue }
                        dark += 1
                        r += Int(c.r)
                        g += Int(c.g)
                        b += Int(c.b)
                    }
                }
                if n > 0, dark * 5 >= n {
                    out[x, y] = RGBA8(UInt8(r / dark), UInt8(g / dark), UInt8(b / dark))
                }
            }
        }
        return out
    }

    /// Draws every glyph of `c` on integer advances; nil when `font` lacks any of its code units.
    private func rasterize(_ c: Character, font: CTFont, source: GlyphSource) -> Glyph? {
        let units = Array(String(c).utf16)
        var ids = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &ids, units.count) else { return nil }
        ids = ids.filter { $0 != 0 }      // the second slot of a surrogate pair is 0
        guard !ids.isEmpty else { return nil }

        var advances = [CGSize](repeating: .zero, count: ids.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, ids, &advances, ids.count)
        var positions: [CGPoint] = []
        var pen = 0
        for a in advances {
            positions.append(CGPoint(x: pen, y: 0))
            pen += max(0, Int(a.width.rounded()))
        }

        let cellWidth = pen + 2 * Self.cellMargin
        guard let ctx = CGBridge.makeContext(width: cellWidth, height: lineHeight) else { return nil }
        Self.disableSmoothing(ctx)
        ctx.setFillColor(CGColor(colorSpace: CGBridge.colorSpace, components: [1, 1, 1, 1])!)
        // Integer baseline: CG is y-up, so the baseline sits `lineHeight − baseline` px above the bottom.
        ctx.translateBy(x: CGFloat(Self.cellMargin), y: CGFloat(lineHeight - baseline))
        CTFontDrawGlyphs(font, ids, positions, ids.count, ctx)

        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * lineHeight)
        var mask = [Bool](repeating: false, count: cellWidth * lineHeight)
        for y in 0..<lineHeight {
            for x in 0..<cellWidth where bytes[y * ctx.bytesPerRow + x * 4 + 3] >= 128 {
                mask[y * cellWidth + x] = true
            }
        }
        return Glyph(advance: pen, mask: mask, maskWidth: cellWidth, source: source)
    }

    // MARK: w6-polish
    /// Glyphs drawn here for a 10-px font that lacks them, where the system font's would be a blot at this size:
    /// rows from the cap line (9 rows over the baseline), `#` = ink. The ⌘ of "⌘Z" in the copy line (Errata 26).
    static let designedGlyphs: [Character: [String]] = [
        "⌘": [".......", ".#...#.", "#.#.#.#", ".#####.", "..#.#..", ".#####.", "#.#.#.#", ".#...#."],
    ]

    /// A designed glyph (`designedGlyphs`) for a 10-px font: its rows from the cap line, advance one past its ink.
    private func designed(_ c: Character) -> Glyph? {
        guard pixelSize == 10, let rows = Self.designedGlyphs[c], let w = rows.map(\.count).max() else { return nil }
        let advance = w + 1, cellWidth = advance + 2 * Self.cellMargin
        var mask = [Bool](repeating: false, count: cellWidth * lineHeight)
        let top = baseline - 9
        for (r, row) in rows.enumerated() where top + r >= 0 && top + r < lineHeight {
            for (x, ch) in row.enumerated() where ch == "#" { mask[(top + r) * cellWidth + Self.cellMargin + x] = true }
        }
        return Glyph(advance: advance, mask: mask, maskWidth: cellWidth, source: .primary)
    }

    /// A hollow 7×9 box standing on the baseline, advance 8 (or proportionally smaller fonts).
    private func boxGlyph() -> Glyph {
        let boxH = max(3, min(baseline, pixelSize - 1))
        let boxW = max(3, (boxH * 7 + 4) / 9)
        let advance = boxW + 1
        let cellWidth = advance + 2 * Self.cellMargin
        var mask = [Bool](repeating: false, count: cellWidth * lineHeight)
        let top = baseline - boxH
        for y in top..<baseline where y >= 0 && y < lineHeight {
            for x in 0..<boxW where y == top || y == baseline - 1 || x == 0 || x == boxW - 1 {
                mask[y * cellWidth + Self.cellMargin + x] = true
            }
        }
        return Glyph(advance: advance, mask: mask, maskWidth: cellWidth, source: .box)
    }

    private static func disableSmoothing(_ ctx: CGContext) {
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSubpixelPositionFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.textMatrix = .identity
    }
}

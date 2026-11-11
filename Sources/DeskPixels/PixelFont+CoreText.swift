#if canImport(CoreText)
import CoreGraphics
import CoreText
import DeskCore
import Foundation

/// The macOS glyph source: the font file through CoreText at its native size, then the system font and its
/// cascade, colour emoji included (`PixelFont`'s documentation). Also what `GlyphAtlas.bake` records.
struct CoreTextRasterizer: GlyphRasterizer, @unchecked Sendable {
    let primary: CTFont
    let fallback: CTFont?

    func glyph(for c: Character, in pf: PixelFont) -> PixelFont.Glyph? {
        if let g = rasterize(c, font: primary, source: .primary, in: pf) { return g }
        if let fallback {
            if let g = rasterize(c, font: fallback, source: .systemFallback, in: pf) { return g }
            // The system font's cascade (other scripts), skipping colour fonts: emoji become boxes.
            let s = String(c) as CFString
            let cascade = CTFontCreateForString(fallback, s, CFRange(location: 0, length: CFStringGetLength(s)))
            if !CTFontGetSymbolicTraits(cascade).contains(.traitColorGlyphs) {
                if let g = rasterize(c, font: cascade, source: .systemFallback, in: pf) { return g }
            } else if let g = rasterizeColor(c, font: cascade, in: pf) {
                return g
            }
        }
        return nil
    }

    /// Colour emoji are drawn at this many times their final size, then area-averaged down.
    static let colorOversample = 6

    /// A colour emoji (`font` is a colour font, e.g. Apple Color Emoji): drawn large through a `CTLine` (so ZWJ
    /// sequences, flags and skin tones shape as one picture), trimmed to its ink, reduced into a `pixelSize`
    /// square standing on the baseline (`featureAverage`, so eyes and outlines survive), alpha thresholded,
    /// snapped to Apollo by lightness first (`snapEmoji`) and given a light rim where its edge is dark
    /// (`liftDarkRim`). Nil when nothing is drawn.
    func rasterizeColor(_ c: Character, font: CTFont, in pf: PixelFont) -> PixelFont.Glyph? {
        let box = max(3, min(pf.baseline, pf.pixelSize))
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
        let snapped = PixelFont.liftDarkRim(PixelFont.snapEmoji(PixelFont.featureAverage(drawn.cropped(to: bounds), to: fit)))
        guard !snapped.opaqueBounds().isEmpty else { return nil }

        let advance = fit.w + 1
        let cellWidth = advance + 2 * PixelFont.cellMargin
        var mask = [Bool](repeating: false, count: cellWidth * pf.lineHeight)
        var colors = [RGBA8](repeating: .clear, count: cellWidth * pf.lineHeight)
        let top = pf.baseline - fit.h
        for y in 0..<fit.h where top + y >= 0 && top + y < pf.lineHeight {
            for x in 0..<fit.w {
                let px = snapped.pixel(x, y)
                guard px.a != 0 else { continue }
                let i = (top + y) * cellWidth + PixelFont.cellMargin + x
                mask[i] = true
                colors[i] = px
            }
        }
        return PixelFont.Glyph(advance: advance, mask: mask, maskWidth: cellWidth, source: .colorFallback, colors: colors)
    }

    /// Draws every glyph of `c` on integer advances; nil when `font` lacks any of its code units.
    func rasterize(_ c: Character, font: CTFont, source: PixelFont.GlyphSource, in pf: PixelFont) -> PixelFont.Glyph? {
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

        let cellWidth = pen + 2 * PixelFont.cellMargin
        guard let ctx = CGBridge.makeContext(width: cellWidth, height: pf.lineHeight) else { return nil }
        Self.disableSmoothing(ctx)
        ctx.setFillColor(CGColor(colorSpace: CGBridge.colorSpace, components: [1, 1, 1, 1])!)
        // Integer baseline: CG is y-up, so the baseline sits `lineHeight − baseline` px above the bottom.
        ctx.translateBy(x: CGFloat(PixelFont.cellMargin), y: CGFloat(pf.lineHeight - pf.baseline))
        CTFontDrawGlyphs(font, ids, positions, ids.count, ctx)

        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * pf.lineHeight)
        var mask = [Bool](repeating: false, count: cellWidth * pf.lineHeight)
        for y in 0..<pf.lineHeight {
            for x in 0..<cellWidth where bytes[y * ctx.bytesPerRow + x * 4 + 3] >= 128 {
                mask[y * cellWidth + x] = true
            }
        }
        return PixelFont.Glyph(advance: pen, mask: mask, maskWidth: cellWidth, source: source)
    }

    static func disableSmoothing(_ ctx: CGContext) {
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

extension PixelFont {
    /// Loads the font file at `url` (see `FontRegistry`); nil if it is not a readable font.
    public convenience init?(url: URL, pixelSize: Int, lineHeight: Int) {
        guard let font = FontRegistry.font(at: url, size: CGFloat(pixelSize)) else { return nil }
        self.init(font: font, pixelSize: pixelSize, lineHeight: lineHeight)
    }

    /// Wraps an existing `CTFont`, which should already be at `pixelSize`.
    public convenience init(font: CTFont, pixelSize: Int, lineHeight: Int) {
        precondition(pixelSize > 0 && lineHeight > 0, "PixelFont needs a positive size and line height")
        // The bounding box, not the descent metric (Galmuri9: descent 1, but glyphs reach 3 rows below).
        // Pixel fonts have whole-pixel bounds; Galmuri9 → 3 rows below, baseline 12 in a 15-px line.
        let descent = Int((-CTFontGetBoundingBox(font).minY).rounded())
        self.init(
            pixelSize: pixelSize, lineHeight: lineHeight, baseline: min(lineHeight, max(0, lineHeight - descent)),
            rasterizer: CoreTextRasterizer(primary: font, fallback: CTFontCreateUIFontForLanguage(.system, CGFloat(pixelSize), nil))
        )
    }

    /// The scalars the font file itself maps (not its fallbacks), in order; empty for an atlas font.
    public var primaryScalars: [Unicode.Scalar] {
        guard let ct = rasterizer as? CoreTextRasterizer else { return [] }
        let set = CTFontCopyCharacterSet(ct.primary)
        var out: [Unicode.Scalar] = []
        for v in UInt32(0)...0x10FFFF {
            guard let s = Unicode.Scalar(v), CFCharacterSetIsLongCharacterMember(set, v) else { continue }
            out.append(s)
        }
        return out
    }

    /// The glyph the font file itself draws for `scalar` (no designed glyph, no fallback): what an atlas stores.
    func primaryGlyph(_ scalar: Unicode.Scalar) -> Glyph? {
        guard let ct = rasterizer as? CoreTextRasterizer else { return nil }
        return ct.rasterize(Character(scalar), font: ct.primary, source: .primary, in: self)
    }
}
#endif // canImport(CoreText)

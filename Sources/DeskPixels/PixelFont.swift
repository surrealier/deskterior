import CoreGraphics
import CoreText
import DeskCore
import Foundation

/// A pixel font rasterized by CoreText at its native size (1 font px = 1 art px) with anti-aliasing,
/// smoothing and subpixel positioning off, then thresholded to **binary alpha**.
///
/// Text is NFC-normalized first (Galmuri has no conjoining jamo) and laid out one `Character` at a time on
/// integer advances, without kerning, so `measure` always equals the rendered width and matches
/// `TextLayout`'s per-character model. Characters the font lacks fall back to the system font at the same size
/// (also without anti-aliasing; then its non-colour cascade fonts), then to a hollow box.
///
/// Verified against Galmuri9's BDF: CoreText reproduces the designed bitmaps exactly (ASCII, Latin-1/Ext-A,
/// kana, all 11,172 Hangul syllables). Glyph bitmaps are cached and the type is thread-safe (`CTFont` is
/// immutable and thread-safe but not annotated `Sendable`; the glyph cache is lock-protected).
public final class PixelFont: @unchecked Sendable {
    /// Where a character's pixels come from.
    public enum GlyphSource: Sendable, Equatable {
        case primary
        case systemFallback
        case box
    }

    /// Font size in px.
    public let pixelSize: Int
    /// Height of every rendered line (and of `render`'s buffer).
    public let lineHeight: Int
    /// Rows above the baseline in a line: glyphs stand on the top edge of row `baseline`.
    public let baseline: Int

    private let primary: CTFont
    private let fallback: CTFont?
    private let cache = FontRegistry.LockedCache<Character, Glyph>()

    /// Galmuri9 (10 px, line height 12) from `Resources/Fonts`; nil if the font file cannot be found or loaded.
    public static let galmuri9: PixelFont? = {
        guard let url = ResourceLocator.fontURL(named: "Galmuri9.ttf") else { return nil }
        return PixelFont(url: url, pixelSize: 10, lineHeight: 12)
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
        // Galmuri9: ascent 10 + descent 1 in a 12-px line → baseline 11 (accented capitals reach row 0).
        let descent = Int(CTFontGetDescent(font).rounded())
        self.baseline = min(lineHeight, max(0, lineHeight - descent))
    }

    // MARK: Measuring

    /// Advance of one character in px (after NFC normalization).
    public func advance(of c: Character) -> Int {
        TextLayout.nfc(String(c)).reduce(0) { $0 + glyph($1).advance }
    }

    /// Width of `s` in px; always equals `render(s, color:).width`.
    public func measure(_ s: String) -> Int {
        TextLayout.nfc(s).reduce(0) { $0 + glyph($1).advance }
    }

    /// Which font draws `c` (after NFC normalization).
    public func source(of c: Character) -> GlyphSource {
        TextLayout.nfc(String(c)).first.map { glyph($0).source } ?? .primary
    }

    // MARK: Rendering

    /// One line of text in `color` on transparent: width = `measure(s)`, height = `lineHeight`.
    public func render(_ s: String, color: RGBA8) -> PixelBuffer {
        let glyphs = TextLayout.nfc(s).map(glyph)
        let width = glyphs.reduce(0) { $0 + $1.advance }
        var out = PixelBuffer(width: width, height: lineHeight)
        var pen = 0
        for g in glyphs {
            g.stamp(into: &out, penX: pen, color: color)
            pen += g.advance
        }
        return out
    }

    /// `render` plus an optional 1-px drop shadow down-right; with a shadow the buffer is 1 px wider and taller.
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
    private static let overhang = 4
    private static let maxCachedGlyphs = 8192

    private struct Glyph: Sendable {
        let advance: Int
        /// `(advance + 2 * overhang) × lineHeight`, row-major from the top; true = ink.
        let mask: [Bool]
        let maskWidth: Int
        let source: GlyphSource

        func stamp(into out: inout PixelBuffer, penX: Int, color: RGBA8) {
            let height = mask.count / max(1, maskWidth)
            for y in 0..<min(height, out.height) {
                for mx in 0..<maskWidth where mask[y * maskWidth + mx] {
                    out.set(penX - PixelFont.overhang + mx, y, color)
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
        if let g = rasterize(c, font: primary, source: .primary) { return g }
        if let fallback {
            if let g = rasterize(c, font: fallback, source: .systemFallback) { return g }
            // The system font's cascade (other scripts), skipping colour fonts: emoji become boxes.
            let s = String(c) as CFString
            let cascade = CTFontCreateForString(fallback, s, CFRange(location: 0, length: CFStringGetLength(s)))
            if !CTFontGetSymbolicTraits(cascade).contains(.traitColorGlyphs),
               let g = rasterize(c, font: cascade, source: .systemFallback) {
                return g
            }
        }
        return boxGlyph()
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

        let cellWidth = pen + 2 * Self.overhang
        guard let ctx = CGBridge.makeContext(width: cellWidth, height: lineHeight) else { return nil }
        Self.disableSmoothing(ctx)
        ctx.setFillColor(CGColor(colorSpace: CGBridge.colorSpace, components: [1, 1, 1, 1])!)
        // Integer baseline: CG is y-up, so the baseline sits `lineHeight − baseline` px above the bottom.
        ctx.translateBy(x: CGFloat(Self.overhang), y: CGFloat(lineHeight - baseline))
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

    /// A hollow 7×9 box standing on the baseline, advance 8 (or proportionally smaller fonts).
    private func boxGlyph() -> Glyph {
        let boxH = max(3, min(baseline, pixelSize - 1))
        let boxW = max(3, (boxH * 7 + 4) / 9)
        let advance = boxW + 1
        let cellWidth = advance + 2 * Self.overhang
        var mask = [Bool](repeating: false, count: cellWidth * lineHeight)
        let top = baseline - boxH
        for y in top..<baseline where y >= 0 && y < lineHeight {
            for x in 0..<boxW where y == top || y == baseline - 1 || x == 0 || x == boxW - 1 {
                mask[y * cellWidth + Self.overhang + x] = true
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

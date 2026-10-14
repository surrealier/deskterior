import DeskCore
import DeskPixels
import Foundation

/// `deskterior-assets status-glyph --out <dir>`: the status item's template glyph (`StatusGlyphArt`) as AppKit
/// would tint it, for review: `StatusGlyph@1x.png` and `@2x.png` (the black + alpha sources) and
/// `StatusGlyph-preview.png` — light and dark menu-bar strips at 1× and 2×, then each magnified ×6.
enum StatusGlyphReview {
    /// Approximate menu-bar backgrounds and template tints (light: black at 85 %; dark: white at 90 %).
    static let bars: [(background: RGBA8, ink: RGBA8)] = [
        (RGBA8(hex: 0xF2F2F2), RGBA8(hex: 0x262626)),
        (RGBA8(hex: 0x2B2B2D), RGBA8(hex: 0xE6E6E6)),
    ]

    static func run(outDir: URL) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for scale in [1, 2] {
            try write(StatusGlyphArt.image(scale: scale), "StatusGlyph@\(scale)x.png", in: outDir, scale: 1)
        }
        try write(preview(), "StatusGlyph-preview.png", in: outDir, scale: 1)
    }

    /// One strip per bar: the 1× and 2× glyphs at their device size in a 24-pt bar, then both magnified.
    static func preview() -> PixelBuffer {
        let g1 = StatusGlyphArt.image(scale: 1), g2 = StatusGlyphArt.image(scale: 2)
        let tiles = [g1, g2, g1.scaledNearest(12), g2.scaledNearest(6)]
        let pad = 12
        let rowH = tiles.map(\.height).max()! + 2 * pad
        let width = tiles.reduce(pad) { $0 + $1.width + pad }
        var sheet = PixelBuffer(width: width, height: rowH * bars.count)
        for (row, bar) in bars.enumerated() {
            let top = row * rowH
            sheet.fill(ArtRect(0, top, width, rowH), bar.background)
            var x = pad
            for tile in tiles {
                var tinted = tile
                tinted.withUnsafeMutablePixels { px in
                    for i in px.indices where px[i].a != 0 { px[i] = bar.ink }
                }
                sheet.blit(tinted, at: ArtPoint(x, top + (rowH - tile.height) / 2))
                x += tile.width + pad
            }
        }
        return sheet
    }
}

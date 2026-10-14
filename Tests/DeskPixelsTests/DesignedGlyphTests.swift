import Testing
@testable import DeskCore
@testable import DeskPixels

/// Glyphs drawn for Galmuri9 where the system font's would be a blot at 10 px (Errata 26).
@Suite("Designed glyphs")
struct DesignedGlyphTests {
    @Test("⌘ is the designed 7×7 glyph on the cap line, advance 8, in the text colour; ⌥ still falls back")
    func commandKey() throws {
        let f = try #require(PixelFont.galmuri9, "Galmuri9.ttf not found via ResourceLocator")
        let ink = Role.labelText.color
        #expect(f.source(of: "⌘") == .primary && f.advance(of: "⌘") == 8)
        let b = f.render("⌘", color: ink)
        let box = b.opaqueBounds()
        #expect(box == ArtRect(0, f.baseline - 8, 7, 7), "\(box)")
        #expect(Set(b.pixels.filter { $0.a != 0 }) == [ink])
        // Its four loops stay open: the pixel inside each corner loop is clear.
        for (x, y) in [(1, 1), (5, 1), (1, 5), (5, 5)] { #expect(b[x, box.minY + y].a == 0, "(\(x), \(y))") }
        // Against "Z", as in "⌘Z", it is no wider or taller than a capital.
        let z = f.render("Z", color: ink).opaqueBounds()
        #expect(box.h <= z.h && box.maxY <= z.maxY)
        #expect(f.source(of: "⌥") == .systemFallback)
    }
}

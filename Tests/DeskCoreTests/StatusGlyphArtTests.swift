import Testing
@testable import DeskCore

@Suite("Status item glyph")
struct StatusGlyphArtTests {
    @Test("18 pt at 1× and 2×: black and alpha only, binary alpha")
    func sizesAndInk() {
        for scale in [1, 2] {
            let b = StatusGlyphArt.image(scale: scale)
            #expect(b.size == ArtSize(18 * scale, 18 * scale))
            #expect(b.pixels.allSatisfy { $0 == .clear || $0 == StatusGlyphArt.ink })
            #expect(StatusGlyphArt.ink == RGBA8(0, 0, 0, 255))
        }
    }

    @Test("The 2× glyph is drawn on its own grid, with the 1× glyph's weight and bounds")
    func ownTwoX() {
        let one = StatusGlyphArt.image(scale: 1), two = StatusGlyphArt.image(scale: 2)
        #expect(two != one.scaledNearest(2), "2× adds its own detail (corners, dog-ears, power button)")
        // The same glyph at a glance: as much ink, over the same doubled bounds.
        let ink1 = one.pixels.filter { $0.a != 0 }.count, ink2 = two.pixels.filter { $0.a != 0 }.count
        #expect(abs(Double(ink2) / Double(4 * ink1) - 1) < 0.15, "ink 1× \(ink1) px, 2× \(ink2) px")
        #expect(one.opaqueBounds() == ArtRect(0, 1, 18, 17))
        #expect(two.opaqueBounds() == ArtRect(0, 2, 36, 34))
    }
}

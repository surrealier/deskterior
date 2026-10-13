import Testing
@testable import DeskCore
@testable import DeskPixels

/// DESIGN §1.4 glyph fallback: Galmuri9, then the system font without anti-aliasing, then colour emoji pixelated
/// to Apollo with binary alpha, then a box.
@Suite("Glyph fallback")
struct GlyphFallbackTests {
    static let ink = Role.labelText.color

    func font() throws -> PixelFont {
        try #require(PixelFont.galmuri9, "Galmuri9.ttf not found via ResourceLocator")
    }

    private func expectPaletteBinary(_ b: PixelBuffer, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(b.pixels.allSatisfy { $0 == .clear || Apollo.index(of: $0) != nil }, sourceLocation: sourceLocation)
    }

    @Test("Colour emoji: a small Apollo picture standing on the baseline, binary alpha, its own colours")
    func colourEmoji() throws {
        let f = try font()
        for c: Character in ["😀", "👨‍👩‍👧", "🇰🇷", "❤️", "👍🏽"] {
            #expect(f.source(of: c) == .colorFallback, "\(c)")
            let b = f.render(String(c), color: Self.ink)
            expectPaletteBinary(b)
            let ink = b.opaqueBounds()
            #expect(!ink.isEmpty, "\(c) drew nothing")
            #expect(ink.maxY == f.baseline || ink.maxY == f.baseline - 1, "\(c) stands on the baseline")
            #expect(ink.h <= f.pixelSize && ink.w <= f.pixelSize, "\(c) fits the box: \(ink)")
            #expect(b.width == f.advance(of: c) && f.advance(of: c) <= f.pixelSize + 1)
            let colours = Set(b.pixels.filter { $0.a != 0 })
            #expect(colours.count >= 2, "\(c) keeps some colour: \(colours.count)")
        }
        // The smiley is yellow, not the text colour, and the text colour does not tint it.
        let smile = f.render("😀", color: Self.ink)
        #expect(smile.pixels.contains { Apollo.index(of: $0).map { Apollo.ramp(of: $0) == .walnut } ?? false })
        #expect(f.render("😀", color: Ink.red3.color) == smile)
    }

    @Test("Text around emoji renders exactly as without them (NFC, advances and goldens unchanged)")
    func textUnchanged() throws {
        let f = try font()
        let plain = f.render("보고서 final.pdf", color: Self.ink)
        let mixed = f.render("보고서 final.pdf😀", color: Self.ink)
        #expect(mixed.cropped(to: ArtRect(0, 0, plain.width, plain.height)) == plain)
        #expect(f.measure("보고서 final.pdf😀") == f.measure("보고서 final.pdf") + f.advance(of: "😀"))
        // NFD input still equals NFC output with an emoji in the name.
        let nfd = "\u{1107}\u{1169}\u{1100}\u{1169}\u{1109}\u{1165} 😀"
        #expect(f.render(nfd, color: Self.ink) == f.render("보고서 😀", color: Self.ink))
        // Symbols the system font has still come from it, in the text colour.
        #expect(f.source(of: "⌘") == .systemFallback)
        #expect(Set(f.render("⌘", color: Self.ink).pixels.filter { $0.a != 0 }) == [Self.ink])
    }

    @Test("A code point no font has still draws something (the system's last resort, or the box), in the text colour")
    func lastResort() throws {
        let f = try font()
        for c: Character in ["\u{10FFFD}", "\u{0378}"] {
            #expect(f.source(of: c) != .primary && f.source(of: c) != .colorFallback)
            let b = f.render(String(c), color: Self.ink)
            #expect(!b.opaqueBounds().isEmpty)
            #expect(Set(b.pixels.filter { $0.a != 0 }) == [Self.ink])
        }
    }

    /// Apple Color Emoji's artwork can change with macOS updates; re-record (after a look) when it does.
    @Test("Golden: a file name with emoji, on a dark label")
    func golden() throws {
        let f = try font()
        let label = f.renderLabel("memo 😀👨‍👩‍👧🇰🇷.txt", color: Self.ink, shadow: Role.labelShadow.color)
        var out = PixelBuffer(width: label.width + 4, height: label.height + 4, fill: Role.screenOff.color)
        out.blit(label, at: ArtPoint(2, 2))
        expectPaletteBinary(out)
        #expect(Golden.match(out, "glyph-fallback-emoji"))
        if let dir = TestSupport.environment("DESKTERIOR_REVIEW_DIR"), !dir.isEmpty {
            try TestSupport.writePNG(out.scaledNearest(8), directory: dir, name: "glyph-fallback-emoji@8x")
        }
    }
}

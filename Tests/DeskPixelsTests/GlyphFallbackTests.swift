import CoreText
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

    /// The Apple Color Emoji version the golden was recorded with (its artwork changes with macOS updates and may
    /// differ on another machine).
    static let recordedEmojiVersion = "21.4d3e1"

    /// The installed Apple Color Emoji's version string.
    static var emojiVersion: String? {
        CTFontCopyName(CTFontCreateWithName("AppleColorEmoji" as CFString, 12, nil), kCTFontVersionNameKey) as String?
    }

    /// Whether to hold the emoji golden: with the recorded artwork, or when `DESKTERIOR_EMOJI_GOLDEN=1` forces it.
    static var emojiGoldenApplies: Bool {
        TestSupport.environment("DESKTERIOR_EMOJI_GOLDEN") == "1" || emojiVersion == recordedEmojiVersion
    }

    /// The property checks always run; the pixel golden only against the recorded emoji artwork (re-record, after a
    /// look, when a macOS update changes it).
    @Test("Golden: a file name with emoji, on a dark label")
    func golden() throws {
        let f = try font()
        let label = f.renderLabel("memo 😀👨‍👩‍👧🇰🇷.txt", color: Self.ink, shadow: Role.labelShadow.color)
        var out = PixelBuffer(width: label.width + 4, height: label.height + 4, fill: Role.screenOff.color)
        out.blit(label, at: ArtPoint(2, 2))
        expectPaletteBinary(out)
        if Self.emojiGoldenApplies { #expect(Golden.match(out, "glyph-fallback-emoji")) }
        if let dir = TestSupport.environment("DESKTERIOR_REVIEW_DIR"), !dir.isEmpty {
            try TestSupport.writePNG(out.scaledNearest(8), directory: dir, name: "glyph-fallback-emoji@8x")
        }
    }

    /// Review sheet (only with `DESKTERIOR_REVIEW_DIR`): dark, light and selector-variant emoji on a dark label.
    @Test("Review: emoji on labels", .enabled(if: !(TestSupport.environment("DESKTERIOR_REVIEW_DIR") ?? "").isEmpty))
    func reviewSheet() throws {
        let f = try font()
        let lines = ["😀 smile 🐈‍⬛ cat 🖤 ⬛ dark", "☺︎ ☺ ☺️ ✈︎ ✈️ #️⃣ 1️⃣ ©️ ™", "👨‍👩‍👧 🇰🇷 🇺🇳 🫠 👍🏽 🎉 ❤️ 🏳️‍🌈"]
        var out = PixelBuffer(width: 220, height: 60, fill: Role.screenOff.color)
        var y = 2
        for l in lines {
            let label = f.renderLabel(l, color: Self.ink, shadow: Role.labelShadow.color)
            expectPaletteBinary(label)
            out.blit(label, at: ArtPoint(2, y))
            y += label.height + 4
        }
        try TestSupport.writePNG(out.scaledNearest(6), directory: TestSupport.environment("DESKTERIOR_REVIEW_DIR")!,
                                 name: "glyph-review@6x")
    }

    @Test("Text-presentation selectors draw the base glyph; an unmapped selector falls back to its base, not the box")
    func variationSelectors() throws {
        let f = try font()
        // ☺︎ (U+263A U+FE0E): Galmuri9 has ☺; ✈︎: the system font has ✈. Both in the text colour.
        #expect(f.source(of: "\u{263A}\u{FE0E}") == f.source(of: "\u{263A}") && f.source(of: "\u{263A}") != .box)
        #expect(f.render("\u{263A}\u{FE0E}", color: Self.ink) == f.render("\u{263A}", color: Self.ink))
        #expect(f.source(of: "\u{2708}\u{FE0E}") == .systemFallback)
        #expect(Set(f.render("\u{2708}\u{FE0E}", color: Self.ink).pixels.filter { $0.a != 0 }) == [Self.ink])
        // Emoji presentation still gets the colour picture.
        #expect(f.source(of: "\u{2708}\u{FE0F}") == .colorFallback)
        #expect(PixelFont.strippingVariationSelectors("a") == nil)
        #expect(PixelFont.strippingVariationSelectors("\u{2708}\u{FE0F}") == "\u{2708}")
    }

    @Test("Dark emoji keep a light rim on a dark label; dark features inside stay dark")
    func darkEmojiContrast() throws {
        let f = try font()
        let plate = Role.screenOff.color
        for c: Character in ["\u{1F5A4}", "\u{2B1B}", "\u{1F408}\u{200D}\u{2B1B}"] {     // 🖤 ⬛ 🐈‍⬛
            #expect(f.source(of: c) == .colorFallback, "\(c)")
            let b = f.render(String(c), color: Self.ink)
            expectPaletteBinary(b)
            // Every pixel on the glyph's rim stands out from the label's dark plate.
            for y in 0..<b.height {
                for x in 0..<b.width where b.pixel(x, y).a != 0 {
                    let rim = b.pixel(x - 1, y).a == 0 || b.pixel(x + 1, y).a == 0 || b.pixel(x, y - 1).a == 0
                        || b.pixel(x, y + 1).a == 0
                    if rim {
                        #expect(OKLab(b.pixel(x, y)).L - OKLab(plate).L >= 0.25, "\(c) rim at \(x),\(y): \(b.pixel(x, y))")
                    }
                }
            }
        }
        // The rim lift leaves interior darks alone.
        var face = PixelBuffer(width: 3, height: 3, fill: Ink.walnut5.color)
        face[1, 1] = Ink.neutral0.color
        face[0, 0] = Ink.neutral0.color
        let lifted = PixelFont.liftDarkRim(face)
        #expect(lifted[1, 1] == Ink.neutral0.color && lifted[0, 0] == PixelFont.emojiRim.color)
    }

    @Test("Emoji snap by lightness first: a bright yellow stays a light yellow, not orange")
    func emojiSnap() {
        let yellow = PixelBuffer(width: 1, height: 1, fill: RGBA8(0xFF, 0xCC, 0x4D))
        let snapped = PixelFont.snapEmoji(yellow)[0, 0]
        #expect(snapped == Ink.walnut5.color, "\(snapped)")
        // Exact palette colours map to themselves.
        let row = PixelBuffer(width: Apollo.count, height: 1, pixels: Apollo.colors)
        #expect(PixelFont.snapEmoji(row) == row)
    }
}

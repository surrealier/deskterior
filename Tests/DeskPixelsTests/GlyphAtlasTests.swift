import DeskCore
import Foundation
import Testing
@testable import DeskPixels

/// The baked Galmuri9 glyphs (`Resources/Fonts/Galmuri9.glyphs`, docs/WINDOWS.md WP4): the same text draws the same
/// pixels from the atlas as from CoreText, so the CoreText goldens hold on every platform.
@Suite("GlyphAtlas")
struct GlyphAtlasTests {
    static let ink = Role.labelText.color
    static let shadow = Role.labelShadow.color

    static func atlasData() throws -> Data {
        let url = try #require(ResourceLocator.fontURL(named: GlyphAtlas.galmuri9FileName), "Galmuri9.glyphs not found")
        return try Data(contentsOf: url)
    }

    static func atlasFont() throws -> PixelFont {
        PixelFont(atlas: try GlyphAtlas(data: atlasData()))
    }

    @Test("The atlas loads, holds Galmuri9's metrics and was baked from the font file in Resources")
    func loads() throws {
        let atlas = try GlyphAtlas(data: Self.atlasData())
        #expect(atlas.pixelSize == 10 && atlas.lineHeight == 15 && atlas.baseline == 12 && atlas.cellMargin == 4)
        #expect(atlas.count > 11_172, "Hangul syllables alone are 11,172")
        let ttf = try #require(ResourceLocator.fontURL(named: "Galmuri9.ttf"))
        #expect(atlas.isBaked(from: try Data(contentsOf: ttf)), "Galmuri9.ttf changed: run deskterior-assets bake-font")
    }

    @Test("Metrics and placement from the atlas")
    func metrics() throws {
        let f = try Self.atlasFont()
        #expect(f.advance(of: "가") == 10 && f.advance(of: "a") == 6 && f.advance(of: " ") == 4 && f.advance(of: "…") == 10)
        let a = f.render("A", color: Self.ink).opaqueBounds()
        #expect(a.maxY == 12 && a.minY == 3)
        let ga = f.render("가", color: Self.ink).opaqueBounds()
        #expect(ga.minY == 3 && ga.maxY == 12 && ga.minX == 0 && ga.w == 9)
        #expect(f.source(of: "가") == .primary && f.source(of: "⌘") == .primary)
    }

    @Test("The CoreText goldens, drawn from the atlas")
    func goldens() throws {
        let f = try Self.atlasFont()
        let report = "보고서 final.pdf"
        let nfd = String(report.decomposedStringWithCanonicalMapping)
        #expect(f.render(nfd, color: Self.ink) == f.render(report, color: Self.ink))
        #expect(Golden.match(f.render(report, color: Self.ink), "galmuri9-report-pdf"))
        #expect(Golden.match(f.render("Deskterior 0.1", color: Self.ink), "galmuri9-latin"))
        let name = "2026 3분기 사업 계획서 최종본 (수정) 진짜 최종.pages"
        let fitted = TextLayout.middleTruncate(name, maxWidth: 200, advance: f.advance(of:))
        #expect(Golden.match(f.renderLabel(fitted, color: Self.ink, shadow: Self.shadow), "galmuri9-label-truncated"))
    }

    @Test("A combining sequence the font has no precomposed glyph for draws its parts side by side")
    func combining() throws {
        let f = try Self.atlasFont()
        let b = f.render("e\u{301}\u{323}", color: Self.ink)
        #expect(b.width == f.measure("e\u{301}\u{323}") + f.overhang(of: "e\u{301}\u{323}").left + f.overhang(of: "e\u{301}\u{323}").right)
        #expect(!b.opaqueBounds().isEmpty)
    }

    @Test("Damaged atlases are refused")
    func refusals() throws {
        let data = try Self.atlasData()
        #expect(throws: GlyphAtlas.Failure.self) { try GlyphAtlas(data: Data("nope".utf8)) }
        #expect(throws: GlyphAtlas.Failure.self) { try GlyphAtlas(data: data.prefix(40)) }
        var badVersion = [UInt8](data)
        badVersion[4] = 9
        #expect(throws: GlyphAtlas.Failure.unsupportedVersion(9)) { try GlyphAtlas(data: Data(badVersion)) }
    }

    @Test("Writing and reading round-trips")
    func roundTrip() throws {
        let mask = (0..<(14 * 15)).map { $0 % 3 == 0 }
        let data = GlyphAtlas.write([GlyphAtlas.Entry(scalar: "Z", advance: 6, mask: mask),
                                     GlyphAtlas.Entry(scalar: "A", advance: 6, mask: mask.map { !$0 })],
                                    pixelSize: 10, lineHeight: 15, baseline: 12, cellMargin: 4, fontFile: Data([1, 2, 3]))
        let atlas = try GlyphAtlas(data: data)
        #expect(atlas.allScalars == ["A", "Z"])
        #expect(atlas.glyph("Z")?.mask == mask && atlas.glyph("A")?.mask == mask.map { !$0 })
        #expect(atlas.glyph("Q") == nil)
        #expect(atlas.isBaked(from: Data([1, 2, 3])) && !atlas.isBaked(from: Data([1, 2])))
    }

    #if canImport(CoreText)
    @Test("The committed atlas is what bake-font writes today")
    func upToDate() throws {
        let ttfURL = try #require(ResourceLocator.fontURL(named: "Galmuri9.ttf"))
        let ct = try #require(PixelFont(url: ttfURL, pixelSize: 10, lineHeight: 15))
        let baked = GlyphAtlas.bake(ct, fontFile: try Data(contentsOf: ttfURL))
        if let dir = TestSupport.environment("DESKTERIOR_ATLAS_OUT"), !dir.isEmpty {
            try baked.write(to: URL(fileURLWithPath: dir).appendingPathComponent(GlyphAtlas.galmuri9FileName))
        }
        #expect(baked == (try? Self.atlasData()), "run: swift run deskterior-assets bake-font --out Resources/Fonts/Galmuri9.glyphs")
    }

    @Test("Every atlas glyph draws exactly as CoreText draws it")
    func matchesCoreText() throws {
        let ttfURL = try #require(ResourceLocator.fontURL(named: "Galmuri9.ttf"))
        let ct = try #require(PixelFont(url: ttfURL, pixelSize: 10, lineHeight: 15))
        let atlas = try GlyphAtlas(data: Self.atlasData())
        let f = PixelFont(atlas: atlas)
        for s in atlas.allScalars {
            let text = String(s)
            #expect(f.render(text, color: Self.ink) == ct.render(text, color: Self.ink), "U+\(String(s.value, radix: 16))")
        }
        for text in ["Ünïcödé façade ÀÉÎ ¡¿ Ștefan Ǻ ĥ", "한글 파일 이름.hwp", "テキスト", "(괄호) [대괄호] 100% 완료!"] {
            #expect(f.render(text, color: Self.ink) == ct.render(text, color: Self.ink), "\(text)")
        }
    }
    #endif
}

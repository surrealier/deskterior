import CoreGraphics
import CoreText
import Testing
@testable import DeskCore
@testable import DeskPixels

@Suite("PixelFont (Galmuri9)")
struct PixelFontTests {
    static let ink = Role.labelText.color
    static let shadow = Role.labelShadow.color
    static let report = "보고서 final.pdf"

    func font() throws -> PixelFont {
        try #require(PixelFont.galmuri9, "Galmuri9.ttf not found via ResourceLocator")
    }

    @Test("ResourceLocator finds the repo font from tests")
    func locatesRepoFont() throws {
        let url = try #require(ResourceLocator.fontURL(named: "Galmuri9.ttf"))
        #expect(TestSupport.fileExists(url.path))
        #expect(url.lastPathComponent == "Galmuri9.ttf")
        #expect(ResourceLocator.fontsDirectory() != nil)
        #expect(ResourceLocator.fontURL(named: "NoSuchFont.ttf") == nil)

        // This test file lives in <repo>/Tests/DeskPixelsTests/, so the repo fallback is <repo>/Resources/Fonts.
        // Debug builds only (release binaries carry no source paths).
        let repoFonts = TestSupport.standardized(TestSupport.repoRoot() + "/Resources/Fonts")
        #expect(ResourceLocator.repoFontsDirectory?.path == repoFonts)
        #expect(ResourceLocator.fontDirectoryCandidates().last?.path == repoFonts)
        if TestSupport.environment("DESKTERIOR_RESOURCES") == nil {
            #expect(url.path == repoFonts + "/Galmuri9.ttf")
        }
        let env = ResourceLocator.fontDirectoryCandidates(environment: ["DESKTERIOR_RESOURCES": "/opt/desk"])
        #expect(env.contains { $0.path == "/opt/desk/Fonts" })
        #expect(env.last?.path == repoFonts)
    }

    @Test("FontRegistry loads from data and caches by (file, size)")
    func registry() throws {
        let url = try #require(ResourceLocator.fontURL(named: "Galmuri9.ttf"))
        let a = try #require(FontRegistry.font(at: url, size: 10))
        let b = try #require(FontRegistry.font(at: url, size: 10))
        #expect(a === b)
        #expect(CTFontGetSize(a) == 10)
        #expect(CTFontGetGlyphCount(a) > 20_000)
        let c = try #require(FontRegistry.font(at: url, size: 20))
        #expect(c !== a && CTFontGetSize(c) == 20)
        let missing = url.deletingLastPathComponent().appendingPathComponent("missing.ttf")
        #expect(FontRegistry.font(at: missing, size: 10) == nil)
    }

    @Test("Metrics: 10 px font, 15 px line, baseline 12; Galmuri advances")
    func metrics() throws {
        let f = try font()
        #expect(f.pixelSize == 10 && f.lineHeight == 15 && f.baseline == 12)
        #expect(f.advance(of: "가") == 10)
        #expect(f.advance(of: "a") == 6)
        #expect(f.advance(of: " ") == 4)
        #expect(f.advance(of: ".") == 4)
        #expect(f.advance(of: "…") == 10)
        // An NFD syllable is one Character; it measures like its NFC form.
        let nfdBo = Character(TestSupport.nfd("보"))
        #expect(f.advance(of: nfdBo) == 10)
    }

    @Test("NFD input renders exactly like NFC and matches the golden")
    func reportGolden() throws {
        let f = try font()
        let nfd = TestSupport.nfd(Self.report)
        #expect(nfd.unicodeScalars.count != Self.report.unicodeScalars.count)
        let fromNFC = f.render(Self.report, color: Self.ink)
        let fromNFD = f.render(nfd, color: Self.ink)
        #expect(fromNFD == fromNFC)
        #expect(fromNFC.height == 15)
        expectBinaryAlpha(fromNFC)
        #expect(fromNFC.opaqueBounds().w > 70)
        #expect(Golden.match(fromNFC, "galmuri9-report-pdf"))
    }

    @Test("Latin golden")
    func latinGolden() throws {
        let f = try font()
        let b = f.render("Deskterior 0.1", color: Self.ink)
        #expect(b.width == f.measure("Deskterior 0.1"))
        expectBinaryAlpha(b)
        #expect(Golden.match(b, "galmuri9-latin"))
    }

    @Test("Middle-truncated label with shadow golden")
    func truncatedLabelGolden() throws {
        let f = try font()
        let name = "2026 3분기 사업 계획서 최종본 (수정) 진짜 최종.pages"
        let fitted = TextLayout.middleTruncate(name, maxWidth: 200, advance: f.advance(of:))
        #expect(fitted.hasSuffix(".pages") && fitted.contains("…"))
        #expect(f.measure(fitted) <= 200)
        let label = f.renderLabel(fitted, color: Self.ink, shadow: Self.shadow)
        #expect(label.width == f.measure(fitted) + 1 && label.height == 16)
        expectBinaryAlpha(label)
        #expect(Golden.match(label, "galmuri9-label-truncated"))
    }

    @Test("Emoji take the colour fallback (details and golden in GlyphFallbackTests): binary alpha, no crash")
    func emoji() throws {
        let f = try font()
        #expect(f.source(of: "😀") == .colorFallback)
        #expect(f.source(of: "👨‍👩‍👧") == .colorFallback)
        let s = "memo 😀👨‍👩‍👧.txt"
        let b = f.render(s, color: Self.ink)
        #expect(b.width == f.measure(s))
        expectBinaryAlpha(b)
    }

    @Test("Missing glyphs fall back to the system font without anti-aliasing")
    func systemFallback() throws {
        let f = try font()
        #expect(f.source(of: "가") == .primary)
        #expect(f.source(of: "A") == .primary)
        for c: Character in ["⌥", "✓"] {
            #expect(f.source(of: c) == .systemFallback, "\(c)")
            let b = f.render(String(c), color: Self.ink)
            #expect(b.width == f.advance(of: c) && b.width > 0)
            expectBinaryAlpha(b)
            #expect(!b.opaqueBounds().isEmpty, "\(c) drew nothing")
        }
    }

    @Test("measure == render width; every pixel is the ink or clear")
    func measureMatchesRender() throws {
        let f = try font()
        let samples = [
            "", " ", "a", "Deskterior", "보고서", Self.report, "日本語テキスト", "Ünïcödé façade", "tab\tand\nnewline",
            "😀", "⌘K", "e\u{301}", "ꙮ", "(괄호) [대괄호] {중괄호}", "100% 완료!", "…",
        ]
        for s in samples {
            let b = f.render(s, color: Self.ink)
            #expect(b.width == f.measure(s), "\(s)")
            #expect(b.height == 15)
            expectBinaryAlpha(b)
            // Colour emoji keep their own (Apollo) colours.
            #expect(b.pixels.allSatisfy { $0 == .clear || $0 == Self.ink || (s == "😀" && Apollo.index(of: $0) != nil) }, "\(s)")
            #expect(f.measure(s) == TextLayout.width(TextLayout.nfc(s), advance: f.advance(of:)), "\(s)")
        }
    }

    @Test("Glyphs sit on the baseline; Hangul fills rows 3–11")
    func baselinePlacement() throws {
        let f = try font()
        let a = f.render("A", color: Self.ink).opaqueBounds()
        #expect(a.maxY == 12 && a.minY == 3)                       // cap height 9 above the baseline
        let g = f.render("g", color: Self.ink).opaqueBounds()
        #expect(g.maxY == 13)                                       // 1-px descender
        let ga = f.render("가", color: Self.ink).opaqueBounds()
        #expect(ga.minY == 3 && ga.maxY == 12 && ga.minX == 0 && ga.w == 9)
    }

    @Test("Nothing is clipped: marks below and above, and ink left of the pen (M1 review F3, F9)")
    func noClipping() throws {
        let f = try font()
        let marks: [Character] = [
            "ç", "Ç", "ą", "Ę", "ş", "Ţ", "ų", "µ", "¡", "¿", "Ș", "ș", "Ț", "ț",  // 2–3 rows below the baseline
            "À", "Å", "Ǻ", "ấ", "ầ", "ế", "ố", "Ẻ", "Ủ",                             // 11–12 rows above
            "ĥ", "Ĩ", "ĩ", "Į", "į", "Ľ", "ľ", "Ƒ", "Ɲ",                              // ink left of the pen
        ]
        for c in marks {
            let b = f.render(String(c), color: Self.ink)
            #expect(inkCount(b) == referenceInkCount(c), "\(c) lost ink")
            #expect(b.width == f.measure(String(c)) + f.overhang(of: String(c)).left + f.overhang(of: String(c)).right)
        }
        // A string keeps its advances: the pen starts after the left overhang.
        let s = "ĥat Façade ¿Qué? Ștefan"
        let b = f.render(s, color: Self.ink)
        #expect(f.overhang(of: s) == (left: 1, right: 0))
        #expect(b.width == f.measure(s) + 1)
        #expect(inkCount(b) == s.reduce(0) { $0 + referenceInkCount($1) })
        #expect(f.overhang(of: "Façade") == (left: 0, right: 0) && f.render("Façade", color: Self.ink).width == f.measure("Façade"))
    }

    @Test("renderLabel adds a 1-px down-right shadow")
    func labelShadow() throws {
        let f = try font()
        let plain = f.render("Hi 안녕", color: Self.ink)
        #expect(f.renderLabel("Hi 안녕", color: Self.ink, shadow: nil) == plain)
        let label = f.renderLabel("Hi 안녕", color: Self.ink, shadow: Self.shadow)
        #expect(label.width == plain.width + 1 && label.height == plain.height + 1)
        for y in 0..<plain.height {
            for x in 0..<plain.width where plain[x, y].a != 0 {
                #expect(label[x, y] == Self.ink)
                if x + 1 >= plain.width || y + 1 >= plain.height || plain[x + 1, y + 1].a == 0 {
                    #expect(label[x + 1, y + 1] == Self.shadow)
                }
            }
        }
        #expect(label.pixels.allSatisfy { $0 == .clear || $0 == Self.ink || $0 == Self.shadow })
    }

    @Test("Concurrent rendering is deterministic")
    func concurrent() async throws {
        let f = try font()
        let expected = f.render(Self.report, color: Self.ink)
        let results = await withTaskGroup(of: PixelBuffer.self) { group in
            for i in 0..<16 {
                group.addTask {
                    // Mix in fresh characters so the cache is written concurrently too.
                    _ = f.render("동시 \(i) 렌더링 테스트 \(i * 7)", color: Self.ink)
                    return f.render(Self.report, color: Self.ink)
                }
            }
            var out: [PixelBuffer] = []
            for await b in group { out.append(b) }
            return out
        }
        #expect(results.count == 16)
        #expect(results.allSatisfy { $0 == expected })
    }

    /// Writes 4× nearest-neighbour upscales for visual review: each image as-is (transparent) and on the
    /// screen-off background. Does nothing unless `DESKTERIOR_REVIEW_DIR` is set.
    @Test("Review images (only with DESKTERIOR_REVIEW_DIR)")
    func reviewImages() throws {
        guard let dir = TestSupport.environment("DESKTERIOR_REVIEW_DIR"), !dir.isEmpty else { return }
        let f = try font()
        let samples: [(String, PixelBuffer)] = [
            ("galmuri9-report-pdf", f.render(Self.report, color: Self.ink)),
            ("galmuri9-latin", f.render("Deskterior 0.1", color: Self.ink)),
            ("galmuri9-sheet", sheet(f)),
        ]
        for (name, b) in samples {
            try TestSupport.writePNG(b.scaledNearest(4), directory: dir, name: "\(name)@4x")
            var bg = PixelBuffer(width: b.width + 4, height: b.height + 4, fill: Role.screenOff.color)
            bg.blit(b, at: ArtPoint(2, 2))
            try TestSupport.writePNG(bg.scaledNearest(4), directory: dir, name: "\(name)-on-dark@4x")
        }
    }

    // MARK: Helpers

    private func sheet(_ f: PixelFont) -> PixelBuffer {
        let lines = [
            "보고서 final.pdf", "Deskterior 0.1", "가나다라마바사 ABC abc 0123456789",
            "한글 파일 이름.hwp · 스크린샷 2026-10-14.png", "Ünïcödé façade ÀÉÎ ¡¿ ‘quotes’ Ștefan Ǻ ĥ",
            "fallback: ⌘ ✓ ₿  emoji: 😀 👨‍👩‍👧 🇰🇷",
            TextLayout.middleTruncate("2026 3분기 사업 계획서 최종본 (수정) 진짜 최종.pages", maxWidth: 200,
                                      advance: f.advance(of:)),
        ]
        let rendered = lines.map { f.renderLabel($0, color: Self.ink, shadow: Self.shadow) }
        let w = rendered.map(\.width).max() ?? 0
        let pitch = f.lineHeight + 1
        var out = PixelBuffer(width: w, height: rendered.count * pitch)
        for (i, b) in rendered.enumerated() { out.blit(b, at: ArtPoint(0, i * pitch)) }
        return out
    }

    private func inkCount(_ b: PixelBuffer) -> Int {
        b.pixels.filter { $0.a != 0 }.count
    }

    /// Opaque pixels of `c` drawn by CoreText with `PixelFont`'s settings in a roomy context (nothing clipped).
    private func referenceInkCount(_ c: Character) -> Int {
        guard let url = ResourceLocator.fontURL(named: "Galmuri9.ttf"),
              let font = FontRegistry.font(at: url, size: 10) else { return -1 }
        let units = Array(String(c).utf16)
        var ids = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &ids, units.count) else { return -1 }
        ids = ids.filter { $0 != 0 }
        var advances = [CGSize](repeating: .zero, count: ids.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, ids, &advances, ids.count)
        var positions: [CGPoint] = []
        var pen = 0
        for a in advances {
            positions.append(CGPoint(x: pen, y: 0))
            pen += max(0, Int(a.width.rounded()))
        }
        guard let ctx = CGBridge.makeContext(width: 64, height: 64) else { return -1 }
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSubpixelPositionFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.textMatrix = .identity
        ctx.setFillColor(CGColor(colorSpace: CGBridge.colorSpace, components: [1, 1, 1, 1])!)
        ctx.translateBy(x: 24, y: 24)
        CTFontDrawGlyphs(font, ids, positions, ids.count, ctx)
        guard let b = CGBridge.pixelBuffer(from: ctx) else { return -1 }
        return b.pixels.filter { $0.a >= 128 }.count
    }

    private func expectBinaryAlpha(_ b: PixelBuffer, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(b.pixels.allSatisfy { $0.a == 0 || $0.a == 255 }, sourceLocation: sourceLocation)
        #expect(b.pixels.allSatisfy { $0.a != 0 || $0 == .clear }, sourceLocation: sourceLocation)
    }
}

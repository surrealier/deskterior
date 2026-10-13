import Testing
@testable import DeskCore

@Suite struct QuantizerTests {
    // MARK: areaAverage

    @Test(arguments: [(7, 5, 3, 2), (10, 10, 3, 3), (64, 64, 16, 16), (5, 3, 5, 3), (2, 2, 7, 5)])
    func uniformColourSurvivesExactly(sw: Int, sh: Int, dw: Int, dh: Int) {
        let c = RGBA8(0xbe, 0x77, 0x2b)
        let out = Quantizer.areaAverage(PixelBuffer(width: sw, height: sh, fill: c), to: ArtSize(dw, dh))
        #expect(out.size == ArtSize(dw, dh))
        #expect(out.pixels.allSatisfy { $0 == c })
    }

    @Test func checkerboardAveragesToMidGrey() {
        let src = checker(4, 4, .black, .white)
        let out = Quantizer.areaAverage(src, to: ArtSize(2, 2))
        #expect(out.pixels.allSatisfy { $0 == RGBA8(128, 128, 128) })
        // A 1-px checker into a non-integer ratio still lands near the middle.
        let odd = Quantizer.areaAverage(checker(9, 9, .black, .white), to: ArtSize(4, 4))
        #expect(odd.pixels.allSatisfy { $0.a == 255 && $0.r >= 96 && $0.r <= 160 && $0.r == $0.g && $0.g == $0.b })
    }

    @Test func fractionalCoverageIsWeighted() {
        // Three source pixels into two: [0, 90, 180] → [(0·2 + 90)/3, (90 + 180·2)/3].
        let src = PixelBuffer(width: 3, height: 1, pixels: [0, 90, 180].map { RGBA8($0, $0, $0) })
        let out = Quantizer.areaAverage(src, to: ArtSize(2, 1))
        #expect(out.pixels == [RGBA8(30, 30, 30), RGBA8(150, 150, 150)])
    }

    @Test func colourIsWeightedByAlpha() {
        let red = RGBA8(200, 20, 20)
        let out = Quantizer.areaAverage(checker(2, 2, red, .clear), to: ArtSize(1, 1))
        #expect(out.pixels == [RGBA8(200, 20, 20, 128)])
        let empty = Quantizer.areaAverage(PixelBuffer(width: 6, height: 6), to: ArtSize(2, 2))
        #expect(empty.pixels.allSatisfy { $0 == .clear })
    }

    @Test func degenerateSizes() {
        #expect(Quantizer.areaAverage(PixelBuffer(width: 4, height: 4, fill: .white), to: .zero).size == .zero)
        let fromEmpty = Quantizer.areaAverage(PixelBuffer(width: 0, height: 0), to: ArtSize(3, 2))
        #expect(fromEmpty.size == ArtSize(3, 2) && fromEmpty.pixels.allSatisfy { $0 == .clear })
    }

    // MARK: thresholdAlpha

    @Test func thresholdBinarizesAlpha() {
        let src = PixelBuffer(width: 5, height: 1, pixels: [
            RGBA8(9, 9, 9, 0), RGBA8(10, 20, 30, 114), RGBA8(10, 20, 30, 115), RGBA8(1, 2, 3, 200), .white,
        ])
        let out = Quantizer.thresholdAlpha(src)
        #expect(out.pixels == [.clear, .clear, RGBA8(10, 20, 30), RGBA8(1, 2, 3), .white])
        let all = Quantizer.thresholdAlpha(src, at: 0)
        #expect(all.pixels[0] == .clear)
        #expect(all.pixels[1] == RGBA8(10, 20, 30))
    }

    // MARK: mapToPalette

    @Test func paletteMappingOutputsOnlyApolloOrClear() {
        let src = noise(24, 24, seed: 7)
        for dither in [false, true] {
            let out = Quantizer.mapToPalette(src, dither: dither)
            for (o, s) in zip(out.pixels, src.pixels) {
                if s.a == 0 {
                    #expect(o == .clear)
                } else {
                    #expect(Apollo.index(of: o) != nil, "\(o)")
                }
            }
        }
    }

    @Test func paletteMappingRespectsAllowedSet() {
        let allowed = [1, 9, 16, 36, 45]
        let out = Quantizer.mapToPalette(noise(16, 16, seed: 3), allowed: allowed, dither: true)
        for o in out.pixels where o.a != 0 {
            #expect(allowed.contains(Apollo.index(of: o) ?? -1))
        }
    }

    @Test func paletteColoursAreKeptExactly() {
        let src = PixelBuffer(width: Apollo.count, height: 1, pixels: Apollo.colors)
        #expect(Quantizer.mapToPalette(src) == src)
        #expect(Quantizer.mapToPalette(src, dither: true) == src)
    }

    @Test func unditheredMappingIsNearest() {
        let c = RGBA8(0x52, 0x70, 0x7a)
        let out = Quantizer.mapToPalette(PixelBuffer(width: 3, height: 3, fill: c))
        #expect(out.pixels.allSatisfy { $0 == Apollo.colors[Apollo.nearestIndex(to: c)] })
    }

    @Test func ditheringMidGreyUsesBothNeighbours() throws {
        let lo = Apollo.oklab[43], hi = Apollo.oklab[44] // a8b5b2, c7cfcc
        let mid = OKLab(L: (lo.L + hi.L) / 2, a: (lo.a + hi.a) / 2, b: (lo.b + hi.b) / 2).rgba8
        let pair = Apollo.nearestTwo(to: OKLab(mid))
        try #require(Set([pair.first, pair.second]) == [43, 44])

        let src = PixelBuffer(width: 8, height: 8, fill: mid)
        let flat = Quantizer.mapToPalette(src)
        #expect(Set(flat.pixels).count == 1)
        let dithered = Quantizer.mapToPalette(src, dither: true)
        let nLo = dithered.pixels.filter { $0 == Apollo.colors[43] }.count
        let nHi = dithered.pixels.filter { $0 == Apollo.colors[44] }.count
        #expect(nLo + nHi == 64)
        #expect(nLo >= 20 && nHi >= 20, "\(nLo) / \(nHi)")

        // Restricted to black and white, a mid grey splits roughly half and half.
        let grey = Quantizer.mapToPalette(PixelBuffer(width: 4, height: 4, fill: RGBA8(0x7a, 0x7c, 0x7e)), allowed: [36, 45], dither: true)
        let dark = grey.pixels.filter { $0 == Apollo.colors[36] }.count
        #expect(dark >= 5 && dark <= 11, "\(dark)")
    }

    @Test func ditherPatternFollowsBayerPhase() {
        let mid = RGBA8(0x7a, 0x7c, 0x7e)
        let a = Quantizer.mapToPalette(PixelBuffer(width: 8, height: 8, fill: mid), allowed: [36, 45], dither: true)
        // The 4×4 pattern tiles.
        for y in 0..<4 {
            for x in 0..<4 {
                #expect(a[x, y] == a[x + 4, y] && a[x, y] == a[x, y + 4] && a[x, y] == a[x + 4, y + 4])
            }
        }
    }

    // MARK: medianCut

    @Test func medianCutRespectsMaxColors() {
        let src = noise(32, 32, seed: 11)
        for maxColors in [1, 2, 4, 8, 16] {
            let set = Quantizer.medianCut(src, maxColors: maxColors)
            #expect(!set.isEmpty && set.count <= maxColors)
            #expect(set == set.sorted() && Set(set).count == set.count)
            #expect(set.allSatisfy { $0 >= 0 && $0 < Apollo.count })
        }
    }

    @Test func medianCutKeepsDistinctPaletteColours() {
        var src = PixelBuffer(width: 6, height: 6, fill: Apollo.colors[16])
        src.fill(ArtRect(0, 0, 2, 2), Apollo.colors[27])
        src.fill(ArtRect(4, 4, 2, 2), Apollo.colors[3])
        src.set(5, 0, .clear)
        #expect(Quantizer.medianCut(src, maxColors: 8) == [3, 16, 27])
        #expect(Quantizer.medianCut(src, maxColors: 3) == [3, 16, 27])
        #expect(Quantizer.medianCut(src, maxColors: 1).count == 1)
    }

    @Test func medianCutEdgeCases() {
        #expect(Quantizer.medianCut(PixelBuffer(width: 4, height: 4), maxColors: 4).isEmpty)
        #expect(Quantizer.medianCut(noise(4, 4, seed: 1), maxColors: 0).isEmpty)
        #expect(Quantizer.medianCut(PixelBuffer(width: 3, height: 3, fill: Apollo.colors[9]), maxColors: 5) == [9])
    }

    @Test func medianCutIsDeterministic() {
        let src = noise(20, 20, seed: 5)
        #expect(Quantizer.medianCut(src, maxColors: 6) == Quantizer.medianCut(src, maxColors: 6))
    }

    // MARK: cleanup

    @Test func orphansAreRemoved() {
        let o = RGBA8.white
        let src = grid([
            "x...x",
            "....x",
            ".x...",
            "..x..",
            "x....",
        ], o)
        let out = Quantizer.removeOrphans(src)
        #expect(out == grid([
            "....x",
            "....x",
            ".....",
            ".....",
            ".....",
        ], o))
    }

    @Test func outlineRing() {
        let fill = RGBA8(hex: 0xd7b594), ink = Role.outline.color
        let src = grid([
            ".....",
            ".....",
            "..x..",
            ".....",
            ".....",
        ], fill)
        let out = Quantizer.outline(src, color: ink)
        #expect(out.size == src.size)
        #expect(out[2, 2] == fill)
        for (x, y) in [(2, 1), (1, 2), (3, 2), (2, 3)] { #expect(out[x, y] == ink) }
        for (x, y) in [(1, 1), (3, 3), (0, 0), (2, 0)] { #expect(out[x, y] == .clear) }

        var block = PixelBuffer(width: 7, height: 7)
        block.fill(ArtRect(2, 2, 3, 3), fill)
        let ringed = Quantizer.outline(block, color: ink)
        #expect(ringed.pixels.filter { $0 == ink }.count == 12)
        #expect(ringed.pixels.filter { $0 == fill }.count == 9)
    }

    @Test func outlineAtTheEdgeStaysInBounds() {
        let full = PixelBuffer(width: 3, height: 3, fill: .white)
        #expect(Quantizer.outline(full, color: .black) == full)
    }

    @Test func trimToOpaque() {
        var src = PixelBuffer(width: 10, height: 8)
        src.set(3, 2, .white)
        src.set(6, 5, .black)
        let out = Quantizer.trimToOpaque(src)
        #expect(out.size == ArtSize(4, 4))
        #expect(out[0, 0] == .white && out[3, 3] == .black)
        #expect(Quantizer.trimToOpaque(PixelBuffer(width: 5, height: 5)).size == .zero)
    }

    @Test func iconChainProducesBinaryPaletteArt() {
        // Soft-edged disc → 12×12 → binary → palette → cleaned → outlined, all Apollo or clear.
        var src = PixelBuffer(width: 48, height: 48)
        for y in 0..<48 {
            for x in 0..<48 {
                let d = Double((x - 24) * (x - 24) + (y - 24) * (y - 24)).squareRoot()
                if d < 20 { src[x, y] = RGBA8(UInt8(x * 5), 140, UInt8(y * 5), d < 18 ? 255 : 120) }
            }
        }
        let small = Quantizer.areaAverage(Quantizer.trimToOpaque(src), to: ArtSize(10, 10))
        var framed = PixelBuffer(width: 12, height: 12)
        framed.blit(Quantizer.thresholdAlpha(small), at: ArtPoint(1, 1))
        let palette = Quantizer.medianCut(framed, maxColors: 8)
        let mapped = Quantizer.removeOrphans(Quantizer.mapToPalette(framed, allowed: palette))
        let out = Quantizer.outline(mapped, color: Role.outline.color)
        #expect(out.pixels.allSatisfy { $0 == .clear || Apollo.index(of: $0) != nil })
        #expect(out.pixels.contains(Role.outline.color))
        #expect(out.opaqueBounds() == ArtRect(0, 0, 12, 12))
    }

    // MARK: helpers

    private func checker(_ w: Int, _ h: Int, _ a: RGBA8, _ b: RGBA8) -> PixelBuffer {
        var p = PixelBuffer(width: w, height: h)
        for y in 0..<h { for x in 0..<w { p[x, y] = (x + y) % 2 == 0 ? a : b } }
        return p
    }

    /// Deterministic pseudo-random colours with about one pixel in eight transparent.
    private func noise(_ w: Int, _ h: Int, seed: UInt64) -> PixelBuffer {
        var s = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        var p = PixelBuffer(width: w, height: h)
        for i in p.pixels.indices {
            s ^= s << 13
            s ^= s >> 7
            s ^= s << 17
            p.pixels[i] = s & 7 == 0 ? .clear : RGBA8(UInt8(truncatingIfNeeded: s >> 8), UInt8(truncatingIfNeeded: s >> 16), UInt8(truncatingIfNeeded: s >> 24))
        }
        return p
    }

    private func grid(_ rows: [String], _ c: RGBA8) -> PixelBuffer {
        var p = PixelBuffer(width: rows[0].count, height: rows.count)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "x" { p[x, y] = c }
        }
        return p
    }
}

import Testing
@testable import DeskCore

@Suite struct OKLabTests {
    @Test func matchesPublishedReferenceValues() {
        // Ottosson / CSS Color 4 reference conversions for the sRGB primaries.
        let cases: [(RGBA8, OKLab)] = [
            (RGBA8(255, 0, 0), OKLab(L: 0.62796, a: 0.22486, b: 0.12585)),
            (RGBA8(0, 255, 0), OKLab(L: 0.86644, a: -0.23389, b: 0.17950)),
            (RGBA8(0, 0, 255), OKLab(L: 0.45201, a: -0.03246, b: -0.31153)),
            (.white, OKLab(L: 1, a: 0, b: 0)),
            (.black, OKLab(L: 0, a: 0, b: 0)),
        ]
        for (c, want) in cases {
            #expect(OKLab(c).distance(to: want) < 1e-4, "\(c) → \(OKLab(c)), want \(want)")
        }
    }

    @Test func eightBitColoursRoundTrip() {
        for c in Apollo.colors { #expect(OKLab(c).rgba8 == c) }
        for r in stride(from: 0, through: 255, by: 15) {
            for g in stride(from: 0, through: 255, by: 15) {
                for b in stride(from: 0, through: 255, by: 15) {
                    let c = RGBA8(UInt8(r), UInt8(g), UInt8(b))
                    #expect(OKLab(c).rgba8 == c)
                }
            }
        }
    }

    @Test func transferFunctionsInvert() {
        for v in 0...255 {
            #expect(OKLab.encode8(OKLab.srgb8ToLinear[v]) == UInt8(v))
        }
        #expect(OKLab.encode8(-0.5) == 0)
        #expect(OKLab.encode8(2) == 255)
    }

    @Test func alphaIsIgnored() {
        #expect(OKLab(RGBA8(10, 20, 30, 0)) == OKLab(RGBA8(10, 20, 30)))
    }

    @Test func distanceIsSymmetricAndSquaredAgrees() {
        let p = Apollo.oklab[3], q = Apollo.oklab[40]
        #expect(p.distance(to: q) == q.distance(to: p))
        #expect(abs(p.distance(to: q) * p.distance(to: q) - p.distanceSquared(to: q)) < 1e-12)
        #expect(p.distance(to: p) == 0)
    }

    @Test func paletteTableMatchesColours() {
        #expect(Apollo.oklab.count == Apollo.count)
        for i in 0..<Apollo.count { #expect(Apollo.oklab[i] == OKLab(Apollo.colors[i])) }
    }

    @Test func nearestIndexMapsPaletteToItself() {
        for (i, c) in Apollo.colors.enumerated() {
            #expect(Apollo.nearestIndex(to: c) == i)
            #expect(Apollo.nearestIndex(to: RGBA8(c.r, c.g, c.b, 0)) == i)
            #expect(Apollo.nearestIndex(to: Apollo.oklab[i]) == i)
        }
    }

    @Test func nearestIndexFindsCloseColours() {
        #expect(Apollo.nearestIndex(to: RGBA8(0, 0, 0)) == 36)       // 090a14
        #expect(Apollo.nearestIndex(to: RGBA8(255, 255, 255)) == 45) // ebede9
        #expect(Apollo.nearestIndex(to: RGBA8(0xd8, 0xb4, 0x95)) == 16)
    }

    @Test func nearestIndexAmongCandidates() {
        let white = OKLab(.white)
        #expect(Apollo.nearestIndex(to: white, among: [0, 6, 12]) == 12)
        #expect(Apollo.nearestIndex(to: white, among: [3]) == 3)
        // Candidate order and duplicates don't change the answer.
        for i in 0..<Apollo.count {
            let p = Apollo.oklab[i]
            let a = Apollo.nearestIndex(to: p, among: [40, 2, 30, 17])
            #expect(Apollo.nearestIndex(to: p, among: [17, 30, 2, 40, 40]) == a)
        }
    }

    @Test func nearestTwoOrdersByDistance() {
        let n = Apollo.nearestTwo(to: Apollo.oklab[40])
        #expect(n.first == 40 && n.d0 == 0)
        #expect(n.second != 40 && n.d1 > 0)
        for i in 0..<Apollo.count where i != 40 {
            #expect(Apollo.oklab[40].distanceSquared(to: Apollo.oklab[i]) >= n.d1)
        }
        let single = Apollo.nearestTwo(to: Apollo.oklab[5], among: [9])
        #expect(single.first == 9 && single.second == 9)
    }
}

@Suite struct IndexLUTTests {
    let lut = IndexLUT.shared

    @Test func sizeAndRange() {
        #expect(IndexLUT.byteCount == 262_144)
        #expect(lut.bytes.count == 262_144)
        #expect(lut.bytes.allSatisfy { Int($0) < Apollo.count })
    }

    @Test func layoutIsRFastestThenGThenB() {
        #expect(IndexLUT.offset(of: RGBA8(0, 0, 0)) == 0)
        #expect(IndexLUT.offset(of: RGBA8(4, 0, 0)) == 1)
        #expect(IndexLUT.offset(of: RGBA8(0, 4, 0)) == 64)
        #expect(IndexLUT.offset(of: RGBA8(0, 0, 4)) == 4096)
        #expect(IndexLUT.offset(of: RGBA8(3, 3, 3)) == 0)
        #expect(IndexLUT.offset(of: RGBA8(255, 255, 255)) == 262_143)
        #expect(IndexLUT.offset(r6: 5, g6: 6, b6: 7) == (7 * 64 + 6) * 64 + 5)
    }

    @Test func paletteColoursHaveDistinctBins() {
        let bins = Set(Apollo.colors.map { IndexLUT.offset(of: $0) })
        #expect(bins.count == Apollo.count)
        // The closest pair (7.7 RGB units apart) still lands in different bins.
        #expect(IndexLUT.offset(of: RGBA8(hex: 0x172038)) != IndexLUT.offset(of: RGBA8(hex: 0x1e1d39)))
    }

    @Test func paletteColoursMapToThemselves() {
        for (i, c) in Apollo.colors.enumerated() { #expect(lut.lookup(c) == i) }
    }

    @Test func driftWithinTheSameBinMapsBack() {
        for (i, c) in Apollo.colors.enumerated() {
            for d in driftOffsets() {
                let drifted = drift(c, d)
                guard IndexLUT.offset(of: drifted) == IndexLUT.offset(of: c) else { continue }
                #expect(lut.lookup(drifted) == i, "\(c) drift \(d)")
            }
        }
    }

    @Test func driftAcrossBinEdgesMapsBack() {
        // Includes 172038 + (1, -1, 0), whose bin centre alone is nearer 1e1d39.
        for (i, c) in Apollo.colors.enumerated() {
            for d in driftOffsets() {
                #expect(lut.lookup(drift(c, d)) == i, "\(c) drift \(d)")
            }
        }
    }

    @Test func binsFarFromThePaletteUseTheCentre() {
        var checked = 0
        for b6 in stride(from: 0, to: 64, by: 5) {
            for g6 in stride(from: 1, to: 64, by: 6) {
                for r6 in stride(from: 2, to: 64, by: 7) {
                    let lo = [r6 * 4, g6 * 4, b6 * 4]
                    let nearPalette = Apollo.colors.contains { c in
                        zip([Int(c.r), Int(c.g), Int(c.b)], lo).allSatisfy { $0 >= $1 - 1 && $0 <= $1 + 4 }
                    }
                    guard !nearPalette else { continue }
                    let centre = OKLab(
                        linearR: OKLab.srgbToLinear((Double(lo[0]) + 1.5) / 255),
                        g: OKLab.srgbToLinear((Double(lo[1]) + 1.5) / 255),
                        b: OKLab.srgbToLinear((Double(lo[2]) + 1.5) / 255)
                    )
                    #expect(Int(lut.bytes[IndexLUT.offset(r6: r6, g6: g6, b6: b6)]) == Apollo.nearestIndex(to: centre))
                    checked += 1
                }
            }
        }
        #expect(checked > 1000)
    }

    private func driftOffsets() -> [(Int, Int, Int)] {
        var out: [(Int, Int, Int)] = []
        for dr in -1...1 { for dg in -1...1 { for db in -1...1 { out.append((dr, dg, db)) } } }
        return out
    }

    private func drift(_ c: RGBA8, _ d: (Int, Int, Int)) -> RGBA8 {
        func f(_ v: UInt8, _ dv: Int) -> UInt8 { UInt8(min(max(Int(v) + dv, 0), 255)) }
        return RGBA8(f(c.r, d.0), f(c.g, d.1), f(c.b, d.2))
    }
}

@Suite struct LightRampTests {
    let ramp = LightRamp.shared

    @Test func tableShapeAndClosure() {
        #expect(ramp.gpuBytes.count == 2 * 8 * Apollo.count)
        #expect(ramp.gpuBytes.allSatisfy { Int($0) < Apollo.count })
        #expect(ramp.gpuRGBABytes.count == ramp.gpuBytes.count * 4)
    }

    @Test func gpuLayout() {
        #expect(LightRamp.offset(index: 0, level: 0, tint: .cool) == 0)
        #expect(LightRamp.offset(index: 5, level: 0, tint: .cool) == 5)
        #expect(LightRamp.offset(index: 0, level: 1, tint: .cool) == 46)
        #expect(LightRamp.offset(index: 0, level: 0, tint: .warm) == 8 * 46)
        #expect(LightRamp.offset(index: 45, level: 7, tint: .warm) == 735)
        for tint in Tint.allCases {
            for level in 0...7 {
                for i in 0..<Apollo.count {
                    let o = LightRamp.offset(index: i, level: level, tint: tint)
                    let j = ramp.map(i, level: level, tint: tint)
                    #expect(Int(ramp.gpuBytes[o]) == j)
                    let c = Apollo.colors[j]
                    #expect(Array(ramp.gpuRGBABytes[o * 4..<o * 4 + 4]) == [c.r, c.g, c.b, 255])
                }
            }
        }
    }

    @Test(arguments: Tint.allCases)
    func levelSevenIsIdentity(tint: Tint) {
        for i in 0..<Apollo.count { #expect(ramp.map(i, level: 7, tint: tint) == i) }
    }

    @Test(arguments: Tint.allCases)
    func lightnessNeverIncreasesAsLevelDrops(tint: Tint) {
        for i in 0..<Apollo.count {
            for level in 0..<7 {
                let lower = Apollo.oklab[ramp.map(i, level: level, tint: tint)].L
                let upper = Apollo.oklab[ramp.map(i, level: level + 1, tint: tint)].L
                #expect(lower <= upper, "index \(i) level \(level)")
            }
        }
    }

    @Test(arguments: Tint.allCases)
    func levelZeroIsVeryDark(tint: Tint) {
        let bound = Apollo.oklab[Ink.neutral3.paletteIndex!].L // 202e37, 4th-darkest neutral
        for i in 0..<Apollo.count {
            #expect(Apollo.oklab[ramp.map(i, level: 0, tint: tint)].L < bound, "index \(i)")
        }
    }

    @Test func lowerLevelsDarkenTheBrightColours() {
        for tint in Tint.allCases {
            let white = Ink.neutral9.paletteIndex!
            #expect(Apollo.oklab[ramp.map(white, level: 3, tint: tint)].L < Apollo.oklab[white].L - 0.2)
        }
    }

    @Test func warmDeskStaysWood() {
        let desk = Role.desk.paletteIndex!
        for level in 5...7 {
            let family = Apollo.ramp(of: ramp.map(desk, level: level, tint: .warm))
            #expect(family == .oak || family == .walnut, "level \(level) → \(family)")
        }
    }

    @Test func tintsDiverge() {
        // Moonlight pulls toward blue (b < 0), lamplight toward orange (b > 0).
        let wall = Ink.neutral8.paletteIndex!
        #expect(Apollo.oklab[ramp.map(wall, level: 2, tint: .cool)].b < Apollo.oklab[ramp.map(wall, level: 2, tint: .warm)].b)
        #expect(Apollo.oklab[ramp.map(wall, level: 1, tint: .warm)].b > 0)
    }

    @Test func isDeterministic() {
        #expect(LightRamp().gpuBytes == ramp.gpuBytes)
    }

    @Test func mapColorPassesThroughNonPaletteColours() {
        #expect(ramp.mapColor(.clear, level: 0, tint: .cool) == .clear)
        let odd = RGBA8(1, 2, 3)
        #expect(ramp.mapColor(odd, level: 2, tint: .warm) == odd)
        let translucentDesk = RGBA8(0xd7, 0xb5, 0x94, 128)
        #expect(ramp.mapColor(translucentDesk, level: 2, tint: .warm) == translucentDesk)
        let desk = Role.desk.color
        #expect(ramp.mapColor(desk, level: 7, tint: .cool) == desk)
        #expect(ramp.mapColor(desk, level: 3, tint: .cool) == Apollo.colors[ramp.map(16, level: 3, tint: .cool)])
    }

    @Test func lightnessScaleCurve() {
        #expect(abs(LightRamp.lightnessScale(level: 0) - 0.12) < 1e-12)
        #expect(abs(LightRamp.lightnessScale(level: 7) - 1) < 1e-12)
        for level in 0..<7 {
            #expect(LightRamp.lightnessScale(level: level) < LightRamp.lightnessScale(level: level + 1))
        }
    }

    /// Golden: the tuned table, one row per (tint, level) from level 7 down. Re-record deliberately when
    /// retuning (the failure message prints the current table).
    @Test func matchesGolden() {
        let actual = Tint.allCases.flatMap { tint in
            stride(from: 7, through: 0, by: -1).map { level in
                (0..<Apollo.count).map { String(ramp.map($0, level: level, tint: tint)) }.joined(separator: " ")
            }
        }
        let golden = LightRampGolden.rows
        #expect(actual == golden, "LightRamp changed; current table:\n\(actual.joined(separator: "\n"))")
    }
}

private enum LightRampGolden {
    static let rows: [String] = [
        "0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45", // cool 7
        "0 1 2 3 4 4 6 7 8 8 9 11 12 13 14 14 15 16 18 12 13 21 21 22 24 25 26 27 28 21 30 31 32 32 33 35 36 37 38 39 40 41 42 42 43 44", // cool 6
        "0 1 1 2 3 42 6 6 7 8 9 42 18 19 13 14 14 15 24 12 19 20 14 15 24 18 12 26 20 14 30 31 31 32 33 34 36 37 37 38 39 40 41 42 42 43", // cool 5
        "37 0 1 2 41 42 38 6 7 7 8 42 18 12 13 13 41 42 24 18 12 13 20 14 37 24 25 19 13 20 30 30 31 32 32 13 36 37 37 38 39 40 41 41 42 42", // cool 4
        "37 0 1 1 2 41 38 6 6 7 41 41 24 18 40 40 41 41 37 18 12 19 13 41 37 24 18 12 19 13 37 30 31 31 31 13 36 36 37 38 39 1 40 40 41 41", // cool 3
        "37 0 0 1 1 40 37 38 6 6 40 40 37 30 39 40 40 40 37 24 18 12 40 40 36 37 24 18 12 12 37 30 30 31 31 31 36 36 37 37 0 39 1 40 40 2", // cool 2
        "36 37 0 0 1 1 37 38 38 39 39 39 37 38 0 39 39 1 36 37 38 0 39 39 36 37 37 24 30 39 36 37 30 30 30 30 36 36 36 37 37 0 0 39 1 1", // cool 1
        "36 36 37 37 0 0 36 36 37 37 0 0 36 37 37 37 0 0 36 36 37 37 0 0 36 36 36 37 37 37 36 36 37 37 37 30 36 36 36 36 36 37 37 0 0 0", // cool 0
        "0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45", // warm 7
        "0 1 2 3 4 43 6 7 8 9 9 11 12 13 14 14 15 16 18 19 20 21 21 22 24 25 26 27 28 21 30 31 32 33 33 35 36 37 38 39 40 41 42 42 43 44", // warm 6
        "38 39 1 2 42 42 6 7 7 8 9 15 18 19 20 14 14 15 18 12 19 20 21 15 24 18 19 26 27 21 24 25 31 32 33 14 36 37 37 38 6 40 41 42 42 43", // warm 5
        "37 39 1 40 41 42 38 6 7 8 8 14 18 19 20 20 14 14 18 12 19 20 20 14 24 18 19 19 20 20 37 18 25 26 26 13 36 36 37 38 6 40 41 41 42 42", // warm 4
        "37 38 39 40 40 41 38 6 7 7 8 20 18 12 19 20 20 20 18 18 19 20 20 20 37 18 25 19 19 20 37 18 25 19 26 13 36 36 37 38 6 6 40 13 41 14", // warm 3
        "37 38 39 6 40 40 37 6 6 7 7 20 18 18 19 19 13 20 24 18 18 19 19 20 36 18 18 19 19 19 36 24 18 25 19 19 36 36 36 37 18 6 12 40 13 13", // warm 2
        "36 37 18 6 6 6 36 37 6 6 6 19 18 18 18 12 19 19 36 18 18 18 19 19 36 36 18 18 19 19 36 24 18 18 18 12 36 36 36 36 37 18 18 12 12 19", // warm 1
        "36 36 36 37 18 18 36 36 36 18 18 18 36 36 18 18 18 18 36 36 18 18 18 18 36 36 36 18 18 18 36 36 36 18 18 18 36 36 36 36 36 36 18 18 18 18", // warm 0
    ]
}

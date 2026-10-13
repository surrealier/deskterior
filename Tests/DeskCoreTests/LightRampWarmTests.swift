import Testing
@testable import DeskCore

/// The warm half of `LightRamp` at the bright levels (M10): lamplight and the night room light read warm, not just
/// dimmer. The full table is pinned by `LightRampTests.matchesGolden`; closure, monotony and hue coherence by the
/// other `LightRampTests`.
@Suite("LightRamp warm shift")
struct LightRampWarmTests {
    let ramp = LightRamp.shared

    private func family(_ i: Int, _ level: Int, _ tint: Tint) -> Apollo.Ramp {
        Apollo.ramp(of: ramp.map(i, level: level, tint: tint))
    }

    private func b(_ i: Int, _ level: Int, _ tint: Tint) -> Double {
        Apollo.oklab[ramp.map(i, level: level, tint: tint)].b
    }

    @Test("Lamp-lit oak turns toward walnut at 5 and its grain and edges at 6")
    func oak() {
        let desk = Role.desk.paletteIndex!, grain = Ink.oak3.paletteIndex!
        #expect(family(desk, 5, .warm) == .walnut)
        #expect(family(grain, 6, .warm) == .walnut && family(grain, 5, .warm) == .walnut)
        #expect(family(desk, 6, .warm) == .oak)
        for i in Apollo.Ramp.oak.indices where i > 12 {
            #expect(b(i, 5, .warm) > b(i, 5, .cool), "oak \(i) is yellower under the lamp than in moonlight")
        }
    }

    @Test("Walls, paper and light metal turn cream and tan at 6; the felt greys warm at 5")
    func greys() {
        let paper = Ink.neutral9.paletteIndex!, wallShade = Ink.neutral8.paletteIndex!
        #expect(ramp.map(paper, level: 6, tint: .warm) == Ink.oak5.paletteIndex!)
        #expect(family(wallShade, 6, .warm) == .oak)
        for felt in [Ink.neutral4, .neutral5].map({ $0.paletteIndex! }) {
            #expect(family(felt, 6, .warm) == .neutral, "a felt grey stays grey under a bright lamp")
            let warmed = family(felt, 5, .warm)
            #expect(warmed == .oak || warmed == .walnut, "felt \(felt) at warm 5 → \(warmed)")
            #expect(b(felt, 5, .warm) > b(felt, 6, .warm))
        }
        // Moonlight leaves the greys their own ramp at 6.
        #expect(family(paper, 6, .cool) == .neutral)
    }

    @Test("Blue, green and purple only dim under warm light (the chair stays blue)")
    func coolColoursKeepTheirHue() {
        for r in [Apollo.Ramp.blue, .green, .purple] {
            for i in r.indices {
                for level in 5...6 { #expect(family(i, level, .warm) == r, "\(r) \(i) at warm \(level)") }
            }
        }
    }

    @Test("The cool half and level 7 are untouched")
    func coolUnchanged() {
        // Spot values of the pre-M10 cool table (the golden pins all of it).
        #expect((0..<Apollo.count).map { ramp.map($0, level: 6, tint: .cool) }.prefix(12) == [0, 1, 2, 3, 4, 4, 6, 7, 8, 8, 9, 11])
        #expect(ramp.map(Role.desk.paletteIndex!, level: 5, tint: .cool) == Ink.oak2.paletteIndex!)
        for i in 0..<Apollo.count { #expect(ramp.map(i, level: 7, tint: .warm) == i) }
    }
}

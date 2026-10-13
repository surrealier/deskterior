import Metal
import Testing
@testable import DeskScene
import DeskCore

@Suite("PostPass (lit and upscale)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct PostPassTests {
    let gpu: GPU

    init() throws {
        gpu = try GPU()
    }

    /// All 46 Apollo colours in one row.
    static let paletteRow = PixelBuffer(width: Apollo.count, height: 1, pixels: Apollo.colors)

    @Test("Level 7 is an exact identity for every palette colour, both tints")
    func identity() throws {
        for tint in Tint.allCases {
            let out = try gpu.lit(Self.paletteRow, ambient: AmbientLight(level: 7, tint: tint))
            #expect(out == Self.paletteRow, "tint \(tint): \(diffCount(out, Self.paletteRow)) px differ")
        }
    }

    @Test("Colours one step off the palette snap back through the 64³ LUT")
    func driftSnapsBack() throws {
        func nudge(_ v: UInt8, _ d: Int) -> UInt8 { UInt8(min(max(Int(v) + d, 0), 255)) }
        let drifted = Apollo.colors.flatMap { c in
            [RGBA8(nudge(c.r, 1), c.g, c.b), RGBA8(c.r, nudge(c.g, -1), c.b), RGBA8(c.r, c.g, nudge(c.b, 1)),
             RGBA8(nudge(c.r, -1), nudge(c.g, 1), nudge(c.b, -1))]
        }
        let out = try gpu.lit(PixelBuffer(width: drifted.count, height: 1, pixels: drifted), ambient: .identity)
        let expected = Apollo.colors.flatMap { [$0, $0, $0, $0] }
        #expect(out.pixels == expected)
    }

    @Test("Ambient levels match LightRamp.mapColor for every colour, level and tint")
    func ambientMatchesRamp() throws {
        let ambient3 = try gpu.lit(Self.paletteRow, ambient: AmbientLight(level: 3, tint: .cool))
        #expect(ambient3.pixels == Apollo.colors.map { LightRamp.shared.mapColor($0, level: 3, tint: .cool) })
        for tint in Tint.allCases {
            for level in 0...LightRamp.maxLevel {
                let out = try gpu.lit(Self.paletteRow, ambient: AmbientLight(level: level, tint: tint))
                let expected = Apollo.colors.map { LightRamp.shared.mapColor($0, level: level, tint: tint) }
                #expect(out.pixels == expected, "level \(level) \(tint)")
            }
        }
    }

    @Test("The light mask wins where it is brighter and brings its own tint")
    func maskOverridesAmbient() throws {
        let c = Apollo.colors
        let row = PixelBuffer(width: 4, height: 1, pixels: [c[16], c[16], c[16], c[16]])
        // level 7 warm; level 5 warm; level 2 cool (dimmer than ambient); none.
        let mask: [UInt8] = [7 | 8, 5 | 8, 2, 0]
        let out = try gpu.lit(row, ambient: AmbientLight(level: 3, tint: .cool), mask: mask)
        let ramp = LightRamp.shared
        #expect(out.pixels == [
            c[16],
            ramp.mapColor(c[16], level: 5, tint: .warm),
            ramp.mapColor(c[16], level: 3, tint: .cool),
            ramp.mapColor(c[16], level: 3, tint: .cool),
        ])
    }

    /// A 4×3 image of distinct palette colours.
    static let small = PixelBuffer(width: 4, height: 3, pixels: (0..<12).map { Apollo.colors[($0 * 7) % Apollo.count] })

    @Test("Upscale: 4×3 at S = 3 with a 1-px crop matches the nearest-neighbour reference")
    func upscaleExact() throws {
        let params = UpscaleParams(scale: 3, cropLeft: 1, cropTop: 1)
        let out = try gpu.upscale(Self.small, width: 10, height: 7, params: params)
        let expected = Self.small.scaledNearest(3).cropped(to: ArtRect(1, 1, 10, 7))
        #expect(out == expected, "\(diffCount(out, expected)) px differ")
        // Spot checks: device (0,0) → art (0,0); device (1,0) → (2/3) → art 0; device (2,0) → art 1.
        #expect(out[0, 0] == Self.small[0, 0])
        #expect(out[1, 0] == Self.small[0, 0])
        #expect(out[2, 0] == Self.small[1, 0])
        #expect(out[9, 6] == Self.small[3, 2])
    }

    @Test("Upscale: shake offsets texels and clamps at the edges")
    func upscaleShake() throws {
        let params = UpscaleParams(scale: 3, cropLeft: 1, cropTop: 1, shake: ArtPoint(1, -1))
        let out = try gpu.upscale(Self.small, width: 10, height: 7, params: params)
        for y in 0..<7 {
            for x in 0..<10 {
                let tx = min(max((x + 1) / 3 - 1, 0), 3), ty = min(max((y + 1) / 3 + 1, 0), 2)
                #expect(out[x, y] == Self.small[tx, ty], "(\(x),\(y))")
            }
        }
    }

    @Test("Upscale with a real PixelGrid crop equals PixelGrid.deviceRect mapping")
    func upscaleGrid() throws {
        // 1540 = 3·513 + 1 and 964 = 3·321 + 1: S 3 with a 1-px crop on every side and whole 512×320 art px visible.
        let grid = PixelGrid(display: DisplayGeometry(
            frameWidthPx: 1540, frameHeightPx: 964, visibleRectPx: DeviceRect(0, 0, 1540, 964), backingScale: 1
        ))
        #expect(grid.scale == 3 && grid.cropLeft == 1 && grid.cropTop == 1)
        var art = PixelBuffer(width: grid.artSize.w, height: grid.artSize.h)
        for y in 0..<art.height {
            for x in 0..<art.width { art[x, y] = Apollo.colors[(x * 5 + y * 11) % Apollo.count] }
        }
        let out = try gpu.upscale(art, width: 1540, height: 964, params: UpscaleParams(grid: grid))
        let expected = art.scaledNearest(3).cropped(to: ArtRect(grid.cropLeft, grid.cropTop, 1540, 964))
        #expect(out == expected, "\(diffCount(out, expected)) px differ")
        let probe = ArtPoint(100, 57)
        let r = grid.deviceRect(forArt: ArtRect(probe.x, probe.y, 1, 1))
        #expect(out[r.x, r.y] == art[probe.x, probe.y] && out[r.maxX - 1, r.maxY - 1] == art[probe.x, probe.y])
    }
}

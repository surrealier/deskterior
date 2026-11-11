import Testing
@testable import DeskCore

@Suite("SoftRaster and SoftPost")
struct SoftRendererTests {
    static let a = Apollo.colors[5], b = Apollo.colors[20], c = Apollo.colors[33], bg = Apollo.colors[0]

    static func tex(_ w: Int, _ h: Int, _ color: RGBA8) -> PixelBuffer { PixelBuffer(width: w, height: h, fill: color) }

    /// An item placed at art pixel (x, y) from the top, `w`×`h` art px, in scene units.
    static func item(_ p: PixelBuffer, x: Double, y: Double, w: Double? = nil, h: Double? = nil, canvasH: Int,
                     z: Double = 0, order: Int = 0) -> DrawItem {
        let u = SoftRaster.unitsPerPixel
        let ww = w ?? Double(p.width), hh = h ?? Double(p.height)
        return DrawItem(x: x * u, y: (Double(canvasH) - y - hh) * u, width: ww * u, height: hh * u, pixels: p, z: z, order: order)
    }

    @Test("Higher z draws over lower; equal z keeps tree order")
    func order() {
        let items = [
            Self.item(Self.tex(4, 4, Self.a), x: 0, y: 0, canvasH: 6, z: 1, order: 0),
            Self.item(Self.tex(4, 4, Self.b), x: 2, y: 2, canvasH: 6, z: 0, order: 1),
            Self.item(Self.tex(2, 2, Self.c), x: 1, y: 1, canvasH: 6, z: 1, order: 2),
        ]
        let out = SoftRaster.composite(items, canvas: ArtSize(6, 6), clear: Self.bg)
        #expect(out[0, 0] == Self.a)         // z 1 over z 0
        #expect(out[3, 3] == Self.a)         // overlap of a (z 1) and b (z 0)
        #expect(out[5, 5] == Self.b)
        #expect(out[1, 1] == Self.c)         // same z as a, later in the tree
        #expect(out[5, 0] == Self.bg)
    }

    @Test("Clear texels are skipped; partial coverage is clipped to the canvas")
    func clearAndClip() {
        var t = Self.tex(3, 3, Self.a)
        t[1, 1] = .clear
        let out = SoftRaster.composite([Self.item(t, x: -1, y: 4, canvasH: 6)], canvas: ArtSize(6, 6), clear: Self.bg)
        #expect(out[0, 4] == Self.a)
        #expect(out[0, 5] == Self.bg)          // texel (1,1) is clear
        #expect(out[1, 4] == Self.a && out[2, 4] == Self.bg)
    }

    @Test("A stretched 1×1 fill covers its whole rectangle")
    func fill() {
        let out = SoftRaster.composite([Self.item(Self.tex(1, 1, Self.c), x: 1, y: 2, w: 3, h: 2, canvasH: 5)],
                                       canvas: ArtSize(5, 5), clear: Self.bg)
        for y in 0..<5 {
            for x in 0..<5 { #expect(out[x, y] == ((1..<4).contains(x) && (2..<4).contains(y) ? Self.c : Self.bg)) }
        }
    }

    @Test("Half-pixel offsets: a pixel is drawn when its centre is inside, left and top edges included")
    func halfPixel() {
        let out = SoftRaster.composite([Self.item(Self.tex(2, 2, Self.a), x: 0.5, y: 0.5, canvasH: 4)],
                                       canvas: ArtSize(4, 4), clear: Self.bg)
        // The rectangle spans 0.5…2.5: centres 0.5 and 1.5 are inside, 2.5 is on the far edge.
        #expect(out[0, 0] == Self.a && out[1, 1] == Self.a)
        #expect(out[2, 0] == Self.bg && out[0, 2] == Self.bg)
    }

    @Test("The straight-copy path and the sampling path agree")
    func pathsAgree() {
        var t = PixelBuffer(width: 5, height: 3)
        for y in 0..<3 { for x in 0..<5 { t[x, y] = Apollo.colors[x + y * 5] } }
        let aligned = SoftRaster.composite([Self.item(t, x: 2, y: 1, canvasH: 8)], canvas: ArtSize(9, 8), clear: Self.bg)
        // The same rectangle a hair off the grid takes the general path and samples the same texels.
        let nudged = SoftRaster.composite([Self.item(t, x: 2.0001, y: 1.0001, canvasH: 8)], canvas: ArtSize(9, 8), clear: Self.bg)
        #expect(aligned == nudged)
        // Doubled: every texel becomes 2×2.
        let doubled = SoftRaster.composite([Self.item(t, x: 0, y: 0, w: 10, h: 6, canvasH: 6)], canvas: ArtSize(10, 6), clear: Self.bg)
        #expect(doubled == t.scaledNearest(2))
    }

    @Test("Lit pass: level 7 is the identity; the mask raises the level and sets its tint where it wins")
    func lit() {
        var art = PixelBuffer(width: Apollo.count, height: 1)
        for i in 0..<Apollo.count { art[i, 0] = Apollo.colors[i] }
        let none = [UInt8](repeating: 0, count: Apollo.count)
        #expect(SoftPost.lit(art, mask: none, ambientLevel: 7, ambientTint: .cool) == art)
        let dark = SoftPost.lit(art, mask: none, ambientLevel: 0, ambientTint: .cool)
        for i in 0..<Apollo.count {
            #expect(dark[i, 0] == Apollo.colors[LightRamp.shared.map(i, level: 0, tint: .cool)])
        }
        let lamp = [UInt8](repeating: LightMask.encode(level: 6, tint: .warm), count: Apollo.count)
        let lampLit = SoftPost.lit(art, mask: lamp, ambientLevel: 2, ambientTint: .cool)
        for i in 0..<Apollo.count {
            #expect(lampLit[i, 0] == Apollo.colors[LightRamp.shared.map(i, level: 6, tint: .warm)])
        }
        // A mask that does not beat the ambient level leaves the ambient tint.
        let weak = [UInt8](repeating: LightMask.encode(level: 1, tint: .warm), count: Apollo.count)
        #expect(SoftPost.lit(art, mask: weak, ambientLevel: 3, ambientTint: .cool) == SoftPost.lit(art, mask: none, ambientLevel: 3, ambientTint: .cool))
    }

    @Test("Upscale: integer scale, crop and shake with clamped edges")
    func upscale() {
        var lit = PixelBuffer(width: 3, height: 2)
        for y in 0..<2 { for x in 0..<3 { lit[x, y] = Apollo.colors[x + y * 3] } }
        #expect(SoftPost.upscale(lit, width: 6, height: 4, scale: 2, cropLeft: 0, cropTop: 0) == lit.scaledNearest(2))
        let cropped = SoftPost.upscale(lit, width: 5, height: 3, scale: 2, cropLeft: 1, cropTop: 1)
        #expect(cropped[0, 0] == lit[0, 0] && cropped[1, 0] == lit[1, 0] && cropped[0, 1] == lit[0, 1])
        let shaken = SoftPost.shifted(lit, by: ArtPoint(1, 0))
        #expect(shaken[0, 0] == lit[0, 0] && shaken[1, 0] == lit[0, 0] && shaken[2, 0] == lit[1, 0])
    }
}

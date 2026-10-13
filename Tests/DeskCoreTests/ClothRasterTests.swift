import Foundation
import Testing
@testable import DeskCore

/// A mat with piles: coverage → bumps → cloth each frame, as the scene will run it.
struct ClothScene {
    var cloth: ClothSim
    var bumps = BumpField()
    var coverage = CoverageTracker()
    var piles: [PileInput] = []

    init(_ cloth: ClothSim = ClothSim(), piles: [PileInput] = [], covered: Bool = true) {
        self.cloth = cloth
        self.piles = piles
        if covered {
            for p in piles { coverage.setCovered(p.id, true) }
            bumps.setCoveredPiles(piles, animated: false)
        }
    }

    mutating func frames(_ n: Int) {
        for _ in 0..<n {
            coverage.update(piles: piles.map {
                CoveragePile(id: $0.id, position: $0.position, radius: 5)
            }, cloth: cloth)
            bumps.setCoveredPiles(piles.filter { coverage.isCovered($0.id) })
            bumps.advance()
            cloth.step(bumps: bumps)
        }
    }

    /// Revealed piles as billboards.
    var billboards: [PileBillboard] {
        piles.filter { !coverage.isCovered($0.id) }.compactMap {
            PileBillboard(id: $0.id, sprite: ClothFixtures.pileSprite, position: SIMD3($0.position.x, $0.position.y, 0))
        }
    }

    func render() -> DeskSurfaceRaster {
        var r = DeskSurfaceRaster()
        r.render(cloth: cloth, piles: billboards)
        return r
    }
}

@Suite("ClothRaster")
struct ClothRasterTests {
    static func flat() -> ClothScene {
        var s = ClothScene()
        s.frames(30)
        return s
    }

    static func bumps() -> ClothScene {
        var s = ClothScene(piles: [
            PileInput(id: 0, position: SIMD2(190, 40), count: 1),
            PileInput(id: 1, position: SIMD2(250, 48), count: 1), PileInput(id: 2, position: SIMD2(257, 52), count: 1),
            PileInput(id: 3, position: SIMD2(252, 57), count: 1),
            PileInput(id: 4, position: SIMD2(318, 44), count: 7),
        ])
        s.frames(60)
        return s
    }

    /// The front-left corner peeled up and in, held over a revealed pile.
    static func peel() -> ClothScene {
        var s = ClothScene(piles: [PileInput(id: 0, position: SIMD2(166, 18), count: 2)])
        s.frames(30)
        let corner = s.cloth.cornerIndices[0]
        let c0 = ClothFixtures.screen(s.cloth, corner)
        s.cloth.beginGrab(particle: corner, cursor: c0)
        for f in 1...30 {
            s.cloth.moveGrab(to: c0 + SIMD2(Float(f) * 0.7, -Float(f) * 0.75))
            s.frames(1)
        }
        return s
    }

    /// The front edge carried back past the middle of the mat and released: a folded strip, underside up.
    static func fold() -> ClothScene {
        var s = ClothScene()
        s.frames(30)
        let edge = s.cloth.index(col: 17, row: 0)
        let c0 = ClothFixtures.screen(s.cloth, edge)
        s.cloth.beginGrab(particle: edge, cursor: c0)
        for f in 1...40 {
            s.cloth.moveGrab(to: c0 + SIMD2(0, -Float(f)))
            s.frames(1)
        }
        s.cloth.endGrab()
        s.frames(120)
        return s
    }

    static func rotated() -> ClothScene {
        let ang: Float = .pi / 6, size = SIMD2<Float>(120, 48), centre = SIMD2<Float>(256, 52)
        let c = Float(cos(Double(ang))), s = Float(sin(Double(ang)))
        let origin = centre - SIMD2(size.x / 2 * c - size.y / 2 * s, size.x / 2 * s + size.y / 2 * c)
        var scene = ClothScene(ClothSim(origin: origin, size: size, angle: ang))
        scene.frames(30)
        return scene
    }

    static let names = ["cloth-flat", "cloth-bumps", "cloth-peel-pile", "cloth-fold", "cloth-rotated-30"]

    static func scene(_ k: Int) -> ClothScene {
        switch k {
        case 0: flat()
        case 1: bumps()
        case 2: peel()
        case 3: fold()
        default: rotated()
        }
    }

    @Test("Raster goldens (exact)", arguments: 0..<5)
    func goldens(_ k: Int) {
        let name = Self.names[k]
        let raster = Self.scene(k).render()
        #expect(raster.image.width == 496 && raster.image.height == 104)
        #expect(Golden.match(raster.image, name))
    }

    @Test("Every drawn pixel is an opaque Apollo colour; owners match what is drawn", arguments: 0..<5)
    func paletteAndOwners(_ k: Int) {
        let raster = Self.scene(k).render()
        for (i, c) in raster.image.pixels.enumerated() {
            #expect(c == .clear || Apollo.index(of: c) != nil)
            let o = raster.owner[i]
            if o >= 0 || o <= -2 { #expect(c.a == 255) }
        }
    }

    @Test("The flat mat: outlined, felt inside, owners near their particles")
    func flatMat() throws {
        let scene = Self.flat()
        let raster = scene.render()
        let o = DeskSurfaceRaster.origin
        func px(_ x: Int, _ y: Int) -> RGBA8 { raster.image.pixel(x - o.x, y - o.y) }
        // The mat lies 1 px up (z = 1), so its rows are 185…226: outlined at the silhouette, felt inside.
        #expect(px(256, 185) == Role.outline.color && px(256, 226) == Role.outline.color)
        // The short edges end in fringe: light threads alternating with gaps.
        let fringe = (190...220).map { px(155, $0) }
        #expect(fringe.contains(.clear) && fringe.contains(Role.feltMatLight.color))
        #expect(px(256, 184) == .clear && px(256, 227) == .clear)
        let felt = MatPattern.felt.topRamp.map(\.color)
        let inside = (190...220).allSatisfy { y in (170...340).allSatisfy { felt.contains(px($0, y)) } }
        #expect(inside)
        #expect(px(250, 207) == Role.feltMat.color)
        let cloth = scene.cloth
        for i in stride(from: 36, to: cloth.count - 36, by: 37) {
            let p = DeskProjection.snap(ClothFixtures.screen(cloth, i))
            let owner = raster.owner(atCore: p)
            #expect(owner >= 0)
            let a = cloth.uv[i], b = cloth.uv[Int(owner)]
            #expect(abs(a.x - b.x) <= 6 && abs(a.y - b.y) <= 6)
        }
        #expect(raster.owner(atCore: ArtPoint(100, 200)) == -1)
        #expect(raster.owner(atCore: ArtPoint(0, 0)) == -1)
        #expect(raster.owner(atCore: ArtPoint(600, 200)) == -1)
    }

    @Test("A peel reveals the pile: it is drawn, owns its pixels and the lifted cloth casts a shadow")
    func peelPicking() {
        let scene = Self.peel()
        #expect(!scene.coverage.isCovered(0))
        let raster = scene.render()
        let pileOwner = DeskSurfaceRaster.pileOwner(0)
        #expect(DeskSurfaceRaster.pileID(owner: pileOwner) == 0)
        #expect(DeskSurfaceRaster.pileID(owner: 5) == nil && DeskSurfaceRaster.pileID(owner: -1) == nil)
        let pilePixels = raster.owner.filter { $0 == pileOwner }.count
        #expect(pilePixels > 40)
        let under = MatPattern.felt.undersideRamp.map(\.color)
        let showsUnderside = raster.image.pixels.contains { under.contains($0) }
        #expect(showsUnderside)
    }

    @Test("Cloth lifted over the bare desk casts an opaque shadow")
    func shadow() {
        var scene = Self.flat()
        scene.cloth.peekUnder(SIMD2(256, 16))
        scene.frames(20)
        let raster = scene.render()
        let shadow = MatPattern.felt.deskShadow.color
        let count = raster.image.pixels.filter { $0 == shadow }.count
        #expect(count > 20)
        // Shadow pixels belong to nothing: clicks fall through to the desk.
        let owned = zip(raster.image.pixels, raster.owner).contains { $0.0 == shadow && $0.1 != -1 }
        #expect(!owned)
    }

    @Test("Rendering is deterministic and fully clears the previous frame")
    func deterministicAndClears() {
        let bumps = Self.bumps(), flat = Self.flat()
        var reused = DeskSurfaceRaster()
        reused.render(cloth: bumps.cloth, piles: bumps.billboards)
        let first = reused.image
        reused.render(cloth: bumps.cloth, piles: bumps.billboards)
        #expect(reused.image == first)
        var slid = flat.cloth
        ClothFixtures.drag(&slid, slid.index(col: 17, row: 7), by: SIMD2(-60, 6), frames: 3, modifiers: .option)
        reused.render(cloth: slid, piles: [])
        var fresh = DeskSurfaceRaster()
        fresh.render(cloth: slid, piles: [])
        #expect(reused.image == fresh.image)
        #expect(reused.owner == fresh.owner)
    }

    @Test("Billboards are depth-tested per pixel against the cloth")
    func billboardDepth() {
        let scene = Self.flat()
        var raster = DeskSurfaceRaster()
        func shown(_ id: Int) -> Int { raster.owner.filter { $0 == DeskSurfaceRaster.pileOwner(id) }.count }
        // Standing on the desk in front of the mat's front edge: the whole sprite shows.
        raster.render(cloth: scene.cloth, piles: [
            PileBillboard(id: 3, sprite: ClothFixtures.pileSprite, position: SIMD3(256, 4, 0))!,
        ])
        #expect(shown(3) == 10 * 12)
        // Standing on the desk under the flat mat, only its bottom row (z 0.5) is below the cloth (z 1): covered piles
        // are the caller's to hide.
        raster.render(cloth: scene.cloth, piles: [
            PileBillboard(id: 4, sprite: ClothFixtures.pileSprite, position: SIMD3(256, 50, 0))!,
        ])
        #expect(shown(4) == 10 * 11)
        // A pile standing behind the held, lifted front flap is partly hidden by it.
        var held = ClothScene()
        held.frames(30)
        let edge = held.cloth.index(col: 17, row: 0)
        let c0 = ClothFixtures.screen(held.cloth, edge)
        held.cloth.beginGrab(particle: edge, cursor: c0)
        for f in 1...40 {
            held.cloth.moveGrab(to: c0 + SIMD2(0, -Float(f) * 0.75))
            held.frames(1)
        }
        raster.render(cloth: held.cloth, piles: [
            PileBillboard(id: 5, sprite: ClothFixtures.pileSprite, position: SIMD3(256, 62, 0))!,
        ])
        #expect(shown(5) > 0 && shown(5) < 10 * 11)
    }

    /// Outline pixels whose four neighbours are all cloth: lines drawn inside the mat.
    static func interiorOutlines(_ raster: DeskSurfaceRaster) -> Int {
        let w = DeskSurfaceRaster.width, h = DeskSurfaceRaster.height, ink = MatPattern.felt.outline.color
        var n = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where raster.image.pixel(x, y) == ink {
                let i = y * w + x
                if [i - 1, i + 1, i - w, i + w].allSatisfy({ raster.owner[$0] >= 0 }) { n += 1 }
            }
        }
        return n
    }

    @Test("Single-layer cloth (bumps, carry wrinkles) draws no black lines inside the mat")
    func noCracksOnOneLayer() {
        #expect(Self.interiorOutlines(Self.bumps().render()) == 0)
        var wrinkled = DeskSurfaceRaster()
        wrinkled.render(cloth: ClothFixtures.wrinkled())
        #expect(Self.interiorOutlines(wrinkled) == 0)
        // A fold still outlines the flap where it lies over the base.
        #expect(Self.interiorOutlines(Self.fold().render()) > 50)
    }

    @Test("A flat face is one solid shade, not a dither checkerboard")
    func flatFacesAreSolid() throws {
        // A plane tilted toward the light, shading level ≈ 2.45 (inside the old dither band).
        let base = ClothSim()
        let tilted = base.positions.map { SIMD3($0.x, $0.y, 1 + 0.2 * ($0.x - 154)) }
        let cloth = ClothSim(positions: tilted, cols: 35, rows: 15, size: SIMD2(204, 84))
        var raster = DeskSurfaceRaster()
        raster.render(cloth: cloth)
        let lit = MatPattern.felt.topRamp[4].color, flat = MatPattern.felt.topRamp[3].color
        var counts = (flat: 0, lit: 0)
        let w = DeskSurfaceRaster.width
        for (i, c) in raster.image.pixels.enumerated() where raster.owner[i] >= 0 {
            let u = cloth.uv[Int(raster.owner[i])]
            guard u.x > 24 && u.x < 180 && u.y > 18 && u.y < 66, i % w > 0 else { continue }
            if c == flat { counts.flat += 1 } else if c == lit { counts.lit += 1 }
        }
        #expect(counts.flat > 1000)
        // Only the light fibre specks use the lit shade.
        #expect(Float(counts.lit) < Float(counts.flat) * 0.06, "flat \(counts.flat), lit \(counts.lit)")
    }

    @Test("Felt specks do not repeat per tile; the underside never glows amber")
    func patternDetails() {
        let felt = MatPattern.felt
        var differs = 0
        for v in 12..<70 {
            for u in 12..<170 where felt.top(u: u, v: v, width: 204, depth: 84) != felt.top(u: u + 16, v: v, width: 204, depth: 84) {
                differs += 1
            }
        }
        #expect(differs > 100)
        for ink in [Ink.walnut4, .walnut5, Role.ledAmber, Role.lampGlow] { #expect(!felt.undersideRamp.contains(ink)) }
        // Underside dots span two material rows, so the 2:1 squash keeps them at any phase.
        #expect(felt.underside(u: 10, v: 4, width: 204, depth: 84) == felt.underside(u: 10, v: 5, width: 204, depth: 84))
    }

    @Test("A revealed pile under lifted cloth is shaded; billboards need a non-negative id")
    func pileShadowAndIDs() {
        #expect(PileBillboard(id: -1, sprite: ClothFixtures.pileSprite, position: .zero) == nil)
        var scene = Self.flat()
        scene.cloth.peekUnder(SIMD2(256, 16))
        scene.frames(20)
        var raster = DeskSurfaceRaster()
        raster.render(cloth: scene.cloth, piles: [
            PileBillboard(id: 1, sprite: ClothFixtures.pileSprite, position: SIMD3(256, 12, 0))!,
        ])
        let owned = zip(raster.image.pixels, raster.owner).filter { $0.1 == DeskSurfaceRaster.pileOwner(1) }.map(\.0)
        #expect(owned.count > 40)
        let shaded = Ink.neutral9.darker(2).color
        #expect(owned.contains(shaded))
        #expect(!owned.contains(Ink.neutral9.color) || owned.filter { $0 == shaded }.count > 10)
    }
}

import DeskPixels
import Foundation
import Testing
@testable import DeskCore

/// The wave-6 polish after its visual review (Errata 26).
@Suite("Core polish review (wave 6)")
struct PolishReviewTests {
    static func layout(_ w: Double, _ h: Double, scale: Double) -> SceneLayout {
        LayoutSolver.solve(display: DisplayGeometry(widthPt: w, heightPt: h, backingScale: scale, topInsetPt: 25))
    }

    @Test("An overfull file drawer pulled open shows its front row of folders, not paper over them (21–26 folders)")
    func openOverfullDrawerHasNoPaper() {
        let travel = CoreLayout.cabinetTravels[2]
        let r = CoreLayout.cabinet, f0 = CoreLayout.cabinetFront(2).offsetBy(-r.x, -r.y + StorageArt.cabinetTopFace)
        for n in 21...ContainerID.cabinetFile.spec.hardCap {
            let items = PolishCoreTests.folders(n)
            let image = InteriorRaster.cabinet(p: [0, 0, travel], items: [[], [], items]).image
            let contents = InteriorRaster.drawerContents(.cabinetFile, items: items, opening: travel)
            let rows = travel - 1, top = contents.height - rows
            var covered = 0
            // Every folder pixel the open drawer shows (below its back edge's shadow row) is drawn as it is.
            for y in 1..<rows {
                for x in 0..<contents.width where contents[x, top + y].a != 0 {
                    if image[f0.x + 4 + x, f0.y + 1 + y] != contents[x, top + y] { covered += 1 }
                }
            }
            #expect(covered == 0, "\(n) folders: \(covered) folder pixels drawn over")
            // Ajar, it still pokes paper over the front.
            let ajar = InteriorRaster.cabinet(p: [0, 0, 5], items: [[], [], items]).image
            let shut = InteriorRaster.cabinet(p: [0, 0, 5], items: [[], [], PolishCoreTests.folders(5)]).image
            #expect(ajar != shut, "\(n) folders: no paper when ajar")
        }
    }

    @Test("What stands higher than the keys in front of the keyboard covers it; flat felt never does")
    func keyboardCover() throws {
        let cloth = ClothSim()
        var raster = DeskSurfaceRaster()
        raster.render(cloth: cloth)
        let mask = PropArt.keyboard().image, origin = CoreLayout.keyboard.origin
        #expect(raster.cover(mask, at: origin, height: DeskSurfaceRaster.keyboardTop) == nil)
        // A revealed card standing just in front of the keyboard rises over its front rows.
        let front = MatState.defaultKeyboard.y - MatState.keyboardSize.y / 2
        let sheet = PixelBuffer(width: 14, height: 18, fill: Ink.neutral9.color)
        let card = try #require(PileBillboard(id: 0, sprite: sheet,
                                              position: SIMD3(Float(CoreLayout.keyboard.midX), front - 3, 0)))
        raster.render(cloth: cloth, piles: [card])
        let cover = try #require(raster.cover(mask, at: origin, height: DeskSurfaceRaster.keyboardTop))
        let shown = cover.pixels.filter { $0.a != 0 }
        #expect(!shown.isEmpty && shown.allSatisfy { $0 == Ink.neutral9.color })
        // Only where the keyboard is drawn.
        for y in 0..<cover.height {
            for x in 0..<cover.width where cover[x, y].a != 0 { #expect(mask[x, y].a != 0) }
        }
    }

    @Test("Ceiling beams stay darker than the ceiling behind them by day and under the room light after dark")
    func beamsRelightWithTheirCeiling() {
        let size = ArtSize(160, 96)
        let ceiling = RoomArt.ceiling(size).image
        let x0 = DecorArt.beamXs(width: size.w)[0]
        func lightness(_ c: RGBA8) -> Double { 0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b) }
        for (level, tint) in [(7, Tint.cool), (6, .warm), (5, .cool), (3, .cool)] {
            for y in 0..<(size.h - 1) {
                // The beam's body against the plaster just left of it (undithered rows only).
                let body = ceiling[x0 + 4, y], plaster = ceiling[x0 - 3, y], left = ceiling[x0 - 4, y]
                guard plaster == left else { continue }
                let lb = lightness(LightRamp.shared.mapColor(body, level: level, tint: tint))
                let lp = lightness(LightRamp.shared.mapColor(plaster, level: level, tint: tint))
                #expect(lb < lp, "row \(y) at \(level) \(tint): beam \(lb) vs ceiling \(lp)")
            }
        }
    }

    @Test("A tall S = 1 portrait canvas keeps the ceiling under 240 rows and hangs a macramé between the pieces")
    func tallestWalls() throws {
        let layout = Self.layout(900, 1440, scale: 1)
        let top = max(layout.visible.minY, 0)
        let crown = try #require(layout.decor(.crown).first).rect
        #expect(crown.y - top <= LayoutSolver.maxCeiling)
        let hanging = try #require(layout.decor(.wallHanging).first).rect
        let gallery = try #require(layout.decor(.gallery).first).rect
        #expect(hanging.maxY < gallery.minY && abs(hanging.midX - layout.x(264)) <= 1)
        for piece in layout.decor(.pendant) + layout.decor(.hangingPlant) {
            #expect(piece.rect.maxY < hanging.minY && piece.rect.h <= LayoutSolver.maxCord + 28 + 30, "\(piece)")
        }
        // The portrait of the design table has no hanging: its wall is not past `maxTallWall`.
        #expect(LayoutSolver.solve(display: pixelGridDesignTable[8].display()).decor(.wallHanging).isEmpty)
    }

    @Test("A railed medium wall hangs the painting between the lights and the monitor (4:3 at 1×)")
    func railedWallPainting() throws {
        let layout = Self.layout(1366, 1024, scale: 1)
        #expect(!layout.decor(.rail).isEmpty)
        let painting = try #require(layout.decor(.painting).first).rect
        let lights = try #require(layout.decor(.stringLights).first).rect
        #expect(painting.minY > lights.maxY && painting.maxY < layout.y(CoreLayout.monitorBody.y))
        #expect(painting.h >= 40 && abs(painting.midX - layout.x(264)) <= 1)
        // The design table's walls keep what they had.
        for row in pixelGridDesignTable.dropLast() {
            let l = LayoutSolver.solve(display: row.display())
            for p in l.decor(.painting) { #expect(p.rect.h <= 64, "\(row.name)") }
        }
    }

    @Test("The upper shelf and the prints cast the wall shadows the lower wall's pieces do")
    func tallWallShadows() throws {
        let layout = LayoutSolver.solve(display: pixelGridDesignTable[8].display())
        let backdrop = RoomArt.backdrop(layout)
        let shade = RoomArt.wallShade.color
        let shelf = try #require(layout.decor(.upperShelf).first).rect
        let board = DecorArt.upperShelfBoard(in: shelf.size).offsetBy(shelf.x, shelf.y)
        #expect(backdrop[board.maxX + 1, board.minY + 4] == shade)
        let gallery = try #require(layout.decor(.gallery).first).rect
        for f in DecorArt.galleryFrames(in: gallery.size).map({ $0.offsetBy(gallery.x, gallery.y) }) {
            #expect(backdrop[f.maxX, f.midY] == shade && backdrop[f.midX, f.maxY] == shade, "\(f)")
        }
    }

    @Test("The hanging planter's pot is opaque terracotta, never the wall's colour")
    func hangingPotIsOpaque() {
        let size = ArtSize(32, 100)
        let plant = DecorArt.hangingPlant(size).image
        let pot = ArtRect(size.w / 2 - 6, size.h - 26, 12, 9)
        for y in pot.minY..<pot.maxY {
            for x in pot.minX..<pot.maxX {
                #expect(plant[x, y] != RoomArt.wall.color, "(\(x), \(y))")
            }
        }
    }
}

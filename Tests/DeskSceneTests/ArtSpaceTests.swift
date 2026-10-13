import CoreGraphics
import SpriteKit
import Testing
@testable import DeskScene
import DeskCore

@Suite("ArtSpace (art y-down ↔ SpriteKit y-up)")
struct ArtSpaceTests {
    let space = ArtSpace(canvas: ArtSize(10, 8))

    @Test("Scene size is canvas × U")
    func sceneSize() {
        #expect(ArtSpace.unitsPerPixel == 4)
        #expect(space.sceneSize == CGSize(width: 40, height: 32))
    }

    @Test("Rects flip y and scale by U")
    func rects() {
        #expect(space.sceneRect(ArtRect(0, 0, 10, 8)) == CGRect(x: 0, y: 0, width: 40, height: 32))
        // Top-left art pixel → top-left of the scene (high y).
        #expect(space.sceneRect(ArtRect(0, 0, 1, 1)) == CGRect(x: 0, y: 28, width: 4, height: 4))
        #expect(space.sceneRect(ArtRect(2, 3, 4, 5)) == CGRect(x: 8, y: 0, width: 16, height: 20))
        for r in [ArtRect(0, 0, 1, 1), ArtRect(2, 3, 4, 5), ArtRect(-3, -2, 7, 3), ArtRect(9, 7, 1, 1)] {
            #expect(space.artRect(space.sceneRect(r)) == r)
        }
        // Sub-pixel scene rects round to whole art pixels.
        #expect(space.artRect(CGRect(x: 8.9, y: 0.6, width: 15.8, height: 19.9)) == ArtRect(2, 3, 4, 5))
    }

    @Test("Points flip y and round-trip")
    func points() {
        #expect(space.scenePoint(SIMD2(0, 0)) == CGPoint(x: 0, y: 32))
        #expect(space.scenePoint(SIMD2(10, 8)) == CGPoint(x: 40, y: 0))
        #expect(space.scenePoint(SIMD2(2.5, 1.25)) == CGPoint(x: 10, y: 27))
        for p in [SIMD2<Float>(0, 0), SIMD2(3.25, 7.5), SIMD2(-1, 9)] {
            #expect(space.artPoint(space.scenePoint(p)) == p)
        }
        #expect(space.position(topLeft: ArtPoint(2, 3), height: 5) == CGPoint(x: 8, y: 0))
    }

    @Test("Snapping lands on whole art pixels")
    func snapping() {
        #expect(ArtSpace.snap(CGFloat(9.9)) == 8)
        #expect(ArtSpace.snap(CGFloat(10.1)) == 12)
        #expect(ArtSpace.snap(CGFloat(-5.9)) == -4)
        #expect(ArtSpace.snap(CGPoint(x: 1.9, y: 6.1)) == CGPoint(x: 0, y: 8))
    }

    @Test("place(_:at:) sizes and positions an anchor-zero sprite")
    func place() {
        let node = SKSpriteNode()
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        space.place(node, at: ArtRect(2, 3, 4, 5))
        #expect(node.anchorPoint == .zero)
        #expect(node.size == CGSize(width: 16, height: 20))
        #expect(node.position == CGPoint(x: 8, y: 0))
    }

    @Test("View points map to continuous art points inside PixelGrid's pixel")
    func viewPoints() {
        let grid = PixelGrid(display: DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2, topInsetPt: 33))
        #expect(grid.scale == 5 && grid.cropTop == 1)
        var y = 0.0
        while y < 956 {
            var x = 0.0
            while x < 1470 {
                let p = SIMD2(x, y)
                let art = ArtSpace.canvasArtPoint(fromViewPoint: p, grid: grid)
                let pixel = grid.artPoint(fromViewPoint: p)
                let event = InputEvent(.move, art: art)
                #expect(event.artPixel == pixel, "view \(p) → \(art)")
                x += 13.37
            }
            y += 7.31
        }
        // Device px 0 of row 0 sits 1 px (cropTop) into art row 0 → 1/5 px.
        let origin = ArtSpace.canvasArtPoint(fromViewPoint: SIMD2(0, 0), grid: grid)
        #expect(abs(origin.y - 0.2) < 1e-5 && origin.x == 0)
    }
}

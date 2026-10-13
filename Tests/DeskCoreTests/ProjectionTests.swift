import Testing
@testable import DeskCore

@Suite("DeskProjection")
struct ProjectionTests {
    let p = DeskProjection.standard

    @Test("Defaults match §1.3: X = x, Y = 232 − d/2 − z")
    func defaults() {
        #expect(p.frontY == 232 && p.k == 0.5)
        #expect(p.project(SIMD3(100, 0, 0)) == SIMD2(100, 232))
        #expect(p.project(SIMD3(100, 64, 0)) == SIMD2(100, 200))
        #expect(p.project(SIMD3(100, 64, 10)) == SIMD2(100, 190))
        // Desk top face spans d 0–128 → Y 232…168 (desk back edge).
        #expect(p.project(SIMD3(12, 128, 0)).y == 168)
    }

    @Test("§1.3 rects: default mat and keyboard footprints")
    func layoutRects() {
        // Mat: plane x154–358, d8–92 → screen 154,186,204,42.
        let matNear = p.projectToPixel(SIMD3(154, 8, 0))
        let matFar = p.projectToPixel(SIMD3(358, 92, 0))
        #expect(matFar.y == 186 && matNear.y == 228)
        #expect(ArtRect(matNear.x, matFar.y, matFar.x - matNear.x, matNear.y - matFar.y) == ArtRect(154, 186, 204, 42))
        // Keyboard: d40–64 → Y 212…200.
        #expect(p.project(SIMD3(206, 40, 0)).y == 212)
        #expect(p.project(SIMD3(302, 64, 0)).y == 200)
    }

    @Test("Round trips: unproject(project(p), z) == p")
    func roundTrips() {
        for x in stride(from: Float(-20), through: 520, by: 37) {
            for d in stride(from: Float(0), through: 128, by: 7.5) {
                for z in [Float(0), 1, 5.25, 20, 64] {
                    let q = SIMD3(x, d, z)
                    let back = p.unproject(p.project(q), z: z)
                    #expect(abs(back.x - q.x) < 1e-4 && abs(back.y - q.y) < 1e-4 && back.z == z)
                }
            }
        }
        // And the other way round, at a fixed height.
        for X in stride(from: Float(0), through: 512, by: 64) {
            for Y in stride(from: Float(100), through: 232, by: 11) {
                let s = SIMD2(X, Y)
                #expect(p.project(p.unproject(s, z: 3)) == s)
            }
        }
    }

    @Test("Custom parameters")
    func custom() {
        let q = DeskProjection(frontY: 100, k: 0.25)
        #expect(q.project(SIMD3(5, 40, 2)) == SIMD2(5, 88))
        #expect(q.unproject(SIMD2(5, 88), z: 2) == SIMD3(5, 40, 2))
    }

    @Test("Monotonic: deeper or higher moves up the screen; x passes through")
    func monotonic() {
        var lastY = Float.infinity
        for d in stride(from: Float(0), through: 128, by: 1) {
            let y = p.project(SIMD3(50, d, 0)).y
            #expect(y < lastY)
            lastY = y
        }
        lastY = .infinity
        for z in stride(from: Float(0), through: 40, by: 0.5) {
            let y = p.project(SIMD3(50, 30, z)).y
            #expect(y < lastY)
            lastY = y
        }
        for x in stride(from: Float(-10), through: 600, by: 3) {
            #expect(p.project(SIMD3(x, 17, 4)).x == x)
        }
    }

    @Test("Depth key: along one view ray, larger z is nearer (smaller d)")
    func depthAlongRay() {
        let screen = SIMD2<Float>(200, 180)
        var lastD = Float.infinity
        var lastKey = -Float.infinity
        for z in stride(from: Float(0), through: 40, by: 2) {
            let q = p.unproject(screen, z: z)
            #expect(p.project(q) == screen)
            #expect(q.y < lastD)
            #expect(p.depthKey(q) > lastKey)
            lastD = q.y
            lastKey = p.depthKey(q)
        }
    }

    @Test("Snapping rounds halves away from zero")
    func snapping() {
        #expect(DeskProjection.snap(Float(0.5)) == 1)
        #expect(DeskProjection.snap(Float(1.5)) == 2)
        #expect(DeskProjection.snap(Float(2.5)) == 3)
        #expect(DeskProjection.snap(Float(-0.5)) == -1)
        #expect(DeskProjection.snap(Float(-2.5)) == -3)
        #expect(DeskProjection.snap(Float(2.49)) == 2)
        #expect(DeskProjection.snap(Float(-2.49)) == -2)
        #expect(DeskProjection.snap(Float.nan) == 0)
        #expect(DeskProjection.snap(Float.infinity) == 0)
        #expect(DeskProjection.snap(SIMD2<Float>(10.5, 227.5)) == ArtPoint(11, 228))
        // d = 9 → Y = 227.5 → 228.
        #expect(p.projectToPixel(SIMD3(10.5, 9, 0)) == ArtPoint(11, 228))
    }
}

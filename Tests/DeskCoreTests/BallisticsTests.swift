import Testing
@testable import DeskCore

@Suite("Ballistics")
struct BallisticsTests {
    static let params = Ballistics.Params.standard

    /// A carry released at core point `p` with core velocity `v`.
    static func fling(_ p: SIMD2<Float>, _ v: SIMD2<Float> = .zero, seed: UInt64? = nil) -> Ballistics.Toss {
        let (pos, vel) = Ballistics.release(at: p, velocity: v)
        return Ballistics.toss(from: pos, velocity: vel, seed: seed)
    }

    @Test("A toss dropped above the basket ends inside it (swish)")
    func dropAboveBasket() {
        for x: Float in [56, 64, 72] {
            for y: Float in [240, 255, 265] {
                let t = Self.fling(SIMD2(x, y))
                #expect(t.landing == .basket && t.kind == .swish && t.isIn, "drop at \(x),\(y)")
                // It disappears below the rim inside the basket's walls.
                #expect(abs(t.end.x - Self.params.basketX) <= Self.params.rimRadius)
                #expect(t.end.z + Self.params.radius < Self.params.rimZ)
            }
        }
    }

    @Test("Identical inputs give identical arcs, seeded or not; seeds vary the arc")
    func deterministic() {
        let a = Self.fling(SIMD2(150, 236), SIMD2(-260, -300), seed: 77)
        let b = Self.fling(SIMD2(150, 236), SIMD2(-260, -300), seed: 77)
        #expect(a == b)
        #expect(a.screenPath() == b.screenPath())
        let plain = Self.fling(SIMD2(150, 236), SIMD2(-260, -300))
        #expect(plain == Self.fling(SIMD2(150, 236), SIMD2(-260, -300)))
        let varied = (0..<8).map { Self.fling(SIMD2(150, 236), SIMD2(-260, -300), seed: $0).end }
        #expect(Set(varied.map { "\($0)" }).count > 1)
    }

    @Test("Swish, rim-in, rim-out and miss all occur and classify consistently")
    func kinds() {
        var seen: [Ballistics.Kind: Ballistics.Toss] = [:]
        for vy in stride(from: -150, through: -500, by: -25) {
            for vx in stride(from: -100, through: -600, by: -20) {
                let t = Self.fling(SIMD2(150, 236), SIMD2(Float(vx), Float(vy)))
                switch t.kind {
                case .swish: #expect(t.landing == .basket && t.rimHits == 0)
                case .rimIn: #expect(t.landing == .basket && t.rimHits > 0)
                case .rimOut: #expect(t.landing != .basket && t.rimHits > 0)
                case .miss: #expect(t.landing != .basket && t.rimHits == 0)
                }
                #expect(t.rimHits <= Self.params.maxRimBounces)
                seen[t.kind] = t
            }
        }
        #expect(seen.count == 4)
    }

    @Test("A ball dropped onto a rim top bounces off it, deterministically in or out")
    func rimDrop() {
        for dx: Float in [-15, -13, 13, 15] {
            let t = Self.fling(SIMD2(Self.params.basketX + dx, 245))
            #expect(t.rimHits >= 1, "dx \(dx)")
            #expect(t.kind == .rimIn || t.kind == .rimOut)
            #expect(t == Self.fling(SIMD2(Self.params.basketX + dx, 245)))
        }
    }

    @Test("Pushed off the desk front over the basket it goes in; elsewhere it lands on the floor at x")
    func pushOff() {
        let inBasket = Ballistics.pushOff(at: SIMD2(66, 0), velocity: SIMD2(-20, -60))
        #expect(inBasket.isIn)
        let floor = Ballistics.pushOff(at: SIMD2(300, 0), velocity: SIMD2(40, -80))
        guard case let .floor(x) = floor.landing else {
            Issue.record("expected a floor landing, got \(floor.landing)")
            return
        }
        #expect(x > 300 && x < 340 && floor.kind == .miss)
        #expect(floor.end.z == Self.params.floorZ)
        // Off the left edge: floor, left of the desk.
        let side = Ballistics.pushOff(at: SIMD2(12, 40), velocity: SIMD2(-15, 0))
        if case let .floor(x) = side.landing { #expect(x < 12) } else { Issue.record("\(side.landing)") }
    }

    @Test("A fling over the desk top lands on the desk at a plane point; the back wall bounces")
    func deskLanding() {
        let t = Self.fling(SIMD2(250, 200), SIMD2(420, -60))
        guard case let .desk(p) = t.landing else {
            Issue.record("expected a desk landing, got \(t.landing)")
            return
        }
        #expect(p.x > 250 && p.y >= 0 && p.y <= 128)
        let lob = Ballistics.toss(from: SIMD3(200, 100, 10), velocity: SIMD3(0, 400, 200))
        guard case let .desk(q) = lob.landing else {
            Issue.record("expected a desk landing, got \(lob.landing)")
            return
        }
        #expect(q.y <= 128, "the back wall keeps it on the desk")
    }

    @Test("Positions are continuous in time and end at the landing")
    func timeline() {
        let t = Self.fling(SIMD2(150, 236), SIMD2(-300, -250))
        #expect(t.position(at: 0) == t.segments[0].start)
        #expect(t.position(at: t.duration) == t.end)
        #expect(t.position(at: t.duration + 5) == t.end)
        var last = t.position(at: 0)
        for i in 1...200 {
            let p = t.position(at: t.duration * Float(i) / 200)
            let d = p - last
            #expect((d * d).sum().squareRoot() < 12, "no jumps")
            last = p
        }
        let path = t.screenPath()
        #expect(path.count >= 2)
        #expect(path.last == DeskProjection.snap(t.screenPoint(at: t.duration)))
    }

    @Test("Releases map to desk space by band; non-finite input is safe")
    func releases() {
        let desk = Ballistics.release(at: SIMD2(200, 200), velocity: SIMD2(10, -20))
        #expect(desk.position == SIMD3(200, 60, 2) && desk.velocity == SIMD3(10, 40, 0))
        let wall = Ballistics.release(at: SIMD2(200, 100), velocity: SIMD2(0, -50))
        #expect(wall.position.y == 128 && wall.position.z == 68 && wall.velocity.z == 50)
        let below = Ballistics.release(at: SIMD2(64, 250), velocity: .zero)
        #expect(below.position == SIMD3(64, -2, -17))
        let nan = Ballistics.toss(from: SIMD3(.nan, 0, 0), velocity: SIMD3(.infinity, 0, 0))
        #expect(nan.duration.isFinite && nan.end.x.isFinite)
    }
}

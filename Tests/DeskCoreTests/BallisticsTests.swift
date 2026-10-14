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
        let varied = (0..<8).map { Self.fling(SIMD2(150, 236), SIMD2(-260, -300), seed: $0).segments[0].velocity }
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

    @Test("A slow release over the desk top lands on the desk at a plane point; the back wall bounces")
    func deskLanding() {
        let t = Self.fling(SIMD2(250, 200), SIMD2(200, -60))
        guard case let .desk(p) = t.landing else {
            Issue.record("expected a desk landing, got \(t.landing)")
            return
        }
        #expect(p.x > 250 && p.y >= 0 && p.y <= 128)
        // The touchdown velocity hands over to the pile's body: `slideCarry` of the hand's.
        #expect(t.landingVelocity.x == 200 * 0.3 && abs(t.landingVelocity.y - 120 * 0.3) < 1e-4 && t.landingVelocity.z < 0)
        #expect(t.velocity(at: 0) == t.segments[0].velocity && t.velocity(at: t.duration) == .zero)
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
        // Over the desk top, slow or fast: on the plane, keeping `slideCarry` (0.3) of the hand's velocity.
        let desk = Ballistics.release(at: SIMD2(200, 200), velocity: SIMD2(10, -20))
        #expect(desk.position == SIMD3(200, 60, 2) && desk.velocity == SIMD3(10, 40, 0) * 0.3)
        let flick = Ballistics.release(at: SIMD2(200, 200), velocity: SIMD2(-200, -180))
        #expect(flick.position == SIMD3(200, 60, 2) && flick.velocity == SIMD3(-200, 360, 0) * 0.3)
        // Over the wall, slow or fast: against the back wall, dropping onto the desk's back.
        let wall = Ballistics.release(at: SIMD2(200, 100), velocity: SIMD2(0, -50))
        #expect(wall.position == SIMD3(200, 128, 68) && wall.velocity == SIMD3(0, 0, 50) * 0.3)
        let wallFlick = Ballistics.release(at: SIMD2(200, 100), velocity: SIMD2(0, 900))
        #expect(wallFlick.position == SIMD3(200, 128, 68) && wallFlick.velocity == SIMD3(0, 0, -900) * 0.3)
        // Below the front edge, or flicked down just above it: the front plane, moving as the hand did on screen.
        let below = Ballistics.release(at: SIMD2(64, 250), velocity: .zero)
        #expect(below.position == SIMD3(64, -2, -17))
        let lip = Ballistics.release(at: SIMD2(200, 228), velocity: SIMD2(-100, 400))
        #expect(lip.position == SIMD3(200, -2, 5) && lip.velocity == SIMD3(-100, 0, -400))
        #expect(Self.params.projection.project(lip.position) == SIMD2(200, 228))
        let slowLip = Ballistics.release(at: SIMD2(200, 228), velocity: SIMD2(0, 200))
        #expect(slowLip.position.y >= 0, "slow at the lip: on the desk")
        let nan = Ballistics.toss(from: SIMD3(.nan, 0, 0), velocity: SIMD3(.infinity, 0, 0))
        #expect(nan.duration.isFinite && nan.end.x.isFinite)
    }

    @Test("The basket's walls are solid from either side: nothing ends on the floor inside them or passes through")
    func solidWalls() {
        let p = Self.params
        var ins = 0, outs = 0
        for x in stride(from: 90, through: 200, by: 10) {
            for vx in stride(from: -900, through: -50, by: 50) {
                for vy in stride(from: -600, through: 200, by: 50) {
                    let t = Self.fling(SIMD2(Float(x), 240), SIMD2(Float(vx), Float(vy)))
                    if t.isIn { ins += 1 } else { outs += 1 }
                    if case let .floor(fx) = t.landing {
                        #expect(FloorLine.isFree(Int(fx)), "x\(x) v(\(vx),\(vy)): floor x \(fx)")
                    }
                    guard !t.isIn else { continue }
                    // A ball that did not go in is never below the rim between the walls within the basket's depth.
                    for i in 0...Int(t.duration * 240) {
                        let q = t.position(at: Float(i) / 240)
                        let between = abs(q.x - p.basketX) < p.rimRadius - 0.5
                        let below = q.z + p.radius < p.rimZ - 0.5
                        #expect(!(between && below && abs(q.y - p.basketD) <= p.rimRadius),
                                "x\(x) v(\(vx),\(vy)) through the wall at \(q)")
                    }
                }
            }
        }
        #expect(ins > 0 && outs > 0)
        // The reviewer's case: off the left room wall, back into the basket's left side below the rim.
        let wall = Ballistics.toss(from: SIMD3(35.5, -8, -9), velocity: SIMD3(-570, 0, 20))
        guard case let .floor(x) = wall.landing else {
            Issue.record("expected a floor landing, got \(wall.landing)")
            return
        }
        #expect(x <= Float(CoreLayout.wastebasket.minX - FloorLine.tokenWidth / 2))
        #expect(wall.segments.contains { $0.start.x <= p.basketX - p.rimRadius - p.radius && $0.velocity.x < 0 })
    }

    @Test("A ball that uses up its rim bounces settles in or out by the side its centre is on")
    func rimExhaustion() {
        let p = Self.params
        for dx: Float in [-15, -14.5, 14.5, 15, -16, 16] {
            for h: Float in [5, 20, 40] {
                let t = Ballistics.toss(from: SIMD3(p.basketX + dx, p.basketD, p.rimZ + h), velocity: .zero)
                #expect(t.rimHits >= 1 && t.rimHits <= p.maxRimBounces)
                if abs(dx) < p.rimRadius {
                    #expect(t.isIn, "dx \(dx) h \(h): centred inside the rim, it drops in")
                } else if case let .floor(x) = t.landing {
                    #expect(abs(x - p.basketX) >= p.rimRadius + Float(FloorLine.tokenWidth / 2), "dx \(dx) h \(h): \(x)")
                } else {
                    Issue.record("dx \(dx) h \(h): \(t.landing)")
                }
            }
        }
    }

    @Test("Releases over the wall or the desk land on the desk however fast; from below the front edge, or flicked down over it, they reach the basket")
    func flicksReachBasket() {
        var below = 0, lip = 0
        for vx in stride(from: -1200, through: 0, by: 100) {
            for vy in stride(from: -600, through: 900, by: 100) {
                let v = SIMD2(Float(vx), Float(vy))
                for y: Float in [100, 140, 160, 180, 200, 220] {
                    // It starts on (or over) the desk, never in front of it: only sliding or flying off an edge
                    // takes it away.
                    #expect(Self.fling(SIMD2(120, y), v).segments[0].start.y >= 0, "y \(y) v \(v)")
                    // Mid-desk at a brisk hand speed it stays.
                    let mid = SIMD2(Float(vx), Float(vy)) / 2
                    let t = Self.fling(SIMD2(250, y), mid)
                    guard case .desk = t.landing else {
                        Issue.record("released at 250,\(y) with \(mid): \(t.landing)")
                        continue
                    }
                }
                if Self.fling(SIMD2(120, 229), v).isIn { lip += 1 }
                for y: Float in [236, 250] where Self.fling(SIMD2(120, y), v).isIn { below += 1 }
            }
        }
        #expect(below > 0 && lip > 0, "below \(below), lip \(lip)")
    }

    @Test("Off the desk's front it falls in the front plane: never below the floor line on screen")
    func frontPlaneFall() {
        for x in stride(from: Float(100), through: 380, by: 20) {
            for vd in stride(from: Float(-600), through: -20, by: 60) {
                let t = Ballistics.pushOff(at: SIMD2(x, 0), velocity: SIMD2(30, vd))
                for i in 0...Int(t.duration * 240) {
                    let q = t.position(at: Float(i) / 240)
                    #expect(q.y >= Self.params.frontPlaneD - 1e-3, "x\(x) vd\(vd): d \(q.y)")
                    #expect(t.projection.project(q).y <= Float(CoreLayout.floorY) + 1.01, "x\(x) vd\(vd): \(q)")
                }
            }
        }
    }

    @Test("A landing in front of furniture bounces clear of it, higher the farther it goes")
    func floorBounce() {
        let near = Ballistics.pushOff(at: SIMD2(395, 0), velocity: SIMD2(0, -80))
        let far = Ballistics.pushOff(at: SIMD2(430, 0), velocity: SIMD2(0, -80))
        func apex(_ t: Ballistics.Toss) -> Float {
            let hop = t.segments.last!
            return hop.velocity.z * hop.velocity.z / (2 * t.gravity)
        }
        #expect(near.landing == .floor(x: 384) && far.landing == .floor(x: 384))
        #expect(apex(near) >= Self.params.minHopHeight - 0.01 && apex(far) > apex(near) && apex(far) >= 0.35 * 46 - 0.1)
    }

    @Test("Rim contacts are timed on the toss (the basket jiggles there)")
    func rimContacts() {
        let p = Self.params
        let t = Ballistics.toss(from: SIMD3(p.basketX + 15, p.basketD, p.rimZ + 20), velocity: .zero)
        #expect(t.rimHits >= 1 && t.rimContacts.count == t.rimHits)
        #expect(t.rimContacts.allSatisfy { $0 > 0 && $0 < t.duration })
        let swish = Self.fling(SIMD2(64, 250))
        #expect(swish.rimContacts.isEmpty)
    }

    @Test("Floor landings end at a free spot: in front of the cabinet or the basket the token hops clear")
    func floorSpots() {
        let cab = Ballistics.pushOff(at: SIMD2(430, 0), velocity: SIMD2(0, -80))
        #expect(cab.landing == .floor(x: 384) && cab.kind == .miss)
        #expect(cab.end == SIMD3(384, cab.end.y, Self.params.floorZ))
        #expect(cab.position(at: cab.duration) == cab.end && cab.landingVelocity.z < 0)
        // The hop is continuous and stays above the floor.
        let hop = cab.segments.last!
        for i in 0...20 {
            let q = cab.position(at: hop.t0 + (cab.duration - hop.t0) * Float(i) / 20)
            #expect(q.z >= Self.params.floorZ - 0.01)
        }
        for x in stride(from: Float(380), through: 480, by: 5) {
            let t = Ballistics.pushOff(at: SIMD2(x, 0), velocity: SIMD2(0, -120))
            guard case let .floor(fx) = t.landing else { continue }
            #expect(FloorLine.isFree(Int(fx)) && fx == fx.rounded(), "\(x) → \(fx)")
        }
        // In front of the basket, below its rim: a drop there goes in; one in front of it lands clear of it.
        let drop = Self.fling(SIMD2(64, 290))
        #expect(drop.isIn)
        let front = Ballistics.toss(from: SIMD3(64, -40, -60), velocity: .zero)
        #expect(front.landing == .floor(x: 40) || front.landing == .floor(x: 88))
    }
}

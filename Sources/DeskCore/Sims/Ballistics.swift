import simd

/// Analytic toss arcs (DESIGN §2.2 E8, E10, E11): flings, tokens pushed off the desk, and paper balls aimed at the
/// wastebasket, without Box2D.
///
/// Motion is in desk space `(x, d, z)` (`DeskProjection`): `x` across, `d` depth back from the desk's front edge,
/// `z` height above the desk top, so the floor is `z = floorZ` (−80: the front floor line, core y 312) and the
/// back wall is `d = backD`. The tracked point is the token's **bottom**; the ball's centre sits `radius` above
/// it. Between events the path is an exact parabola under gravity `g`; events are found by sampling at
/// `eventStep` and bisecting, so the same inputs always give the same arc.
///
/// The wastebasket is a cylinder under the desk front. In the side view (x, z) each of its walls is a vertical
/// segment at `basketX ± rimRadius` from the floor up to its rim top at `rimZ`, solid from either side while the
/// ball is within the basket's depth: the rim tops bounce with `rimRestitution` (at most `maxRimBounces` count;
/// the last one settles the ball in or out by the side its centre is on), the walls with `wallRestitution`. A ball
/// whose centre is below the rim between the walls is in. A floor landing in front of furniture hops on to the
/// nearest free spot (`FloorLine`), so every miss ends as a visible, safe token.
public enum Ballistics {
    public struct Params: Hashable, Sendable {
        public var gravity: Float = 940
        /// Ball / token radius (a crumpled ball is 8 px).
        public var radius: Float = 4
        public var rimRestitution: Float = 0.4
        public var maxRimBounces = 3
        /// Walls (back wall, room sides, the basket's walls).
        public var wallRestitution: Float = 0.3
        /// A ball that used up its rim bounces on the outside rolls off the rim at least this fast (px/s).
        public var rollOffSpeed: Float = 40
        public var floorZ: Float = Float(CoreLayout.deskFrontY - CoreLayout.floorY)
        public var deskX: ClosedRange<Float> = Float(CoreLayout.deskTop.minX)...Float(CoreLayout.deskTop.maxX)
        public var backD: Float = 128
        /// Releases below the desk's front edge, and fast ones above it, start in this vertical plane just in
        /// front of the desk.
        public var frontPlaneD: Float = -2
        /// A release above the desk's front edge faster than this (px/s) starts in the front plane, so its arc
        /// follows the hand on screen; slower ones drop onto the desk (or down the back wall).
        public var frontFlingSpeed: Float = 250
        /// Room sides tokens stay within (core x).
        public var roomX: ClosedRange<Float> = 4...Float(CoreLayout.size.w - 4)
        /// Basket: centre x and depth (just in front of the desk's front edge), rim radius, and rim height (where
        /// its mouth line, core y 275, lies at that depth).
        public var basketX: Float = Float(CoreLayout.wastebasketMouth.midX)
        public var basketD: Float = -8
        public var rimRadius: Float = Float(CoreLayout.wastebasketMouth.w) / 2 - 1
        public var rimZ: Float = Float(CoreLayout.deskFrontY - (CoreLayout.wastebasketMouth.minY + 3)) + 8 * 0.5
        /// A ball that went in is followed this far below the rim (then it is behind the basket's front).
        public var sinkDepth: Float = 12
        /// Floor furniture a landing hops clear of (`FloorLine`): seconds of hop, plus this per px of hop.
        public var floorAvoid: [Range<Int>] = FloorLine.furniture
        public var hopTime: Float = 0.1
        public var hopTimePerPx: Float = 1.0 / 300
        /// Seeded variation: velocity components scale by up to ± this fraction, rim restitution by ± `rimJitter`.
        public var velocityJitter: Float = 0.04
        public var rimJitter: Float = 0.06
        public var maxTime: Float = 4
        /// Event search resolution (s).
        public var eventStep: Float = 1.0 / 480
        public var projection = DeskProjection.standard

        public init() {}

        public static let standard = Params()
    }

    /// Where a toss ends.
    public enum Landing: Hashable, Sendable {
        case basket
        /// Desk-plane point `(x, d)`.
        case desk(SIMD2<Float>)
        /// Core x of the token's centre on the floor: a whole px, clear of the floor furniture (`FloorLine`).
        case floor(x: Float)
    }

    public enum Kind: String, Hashable, Sendable {
        /// Into the basket without touching the rim ("SWISH!").
        case swish
        /// Touched the rim, then dropped in.
        case rimIn
        /// Touched the rim and fell out.
        case rimOut
        /// Never touched the rim and did not go in (desk or floor).
        case miss
    }

    /// One parabolic piece: from `start` at time `t0` with velocity `velocity`.
    public struct Segment: Hashable, Sendable {
        public var t0: Float
        public var start: SIMD3<Float>
        public var velocity: SIMD3<Float>
    }

    /// A computed arc: time-parameterized positions plus its classification.
    public struct Toss: Hashable, Sendable {
        public var segments: [Segment]
        public var duration: Float
        public var landing: Landing
        public var kind: Kind
        public var rimHits: Int
        /// Where the toss ends (the bottom point).
        public var end: SIMD3<Float>
        /// Desk-space velocity at touchdown (on the desk: hand it to the pile's body; on the floor: before any hop
        /// to a free spot; in the basket: as it sinks out of sight).
        public var landingVelocity: SIMD3<Float>
        public var gravity: Float
        public var projection: DeskProjection

        public var isIn: Bool { landing == .basket }

        /// Bottom point at time `t` (clamped to `0…duration`).
        public func position(at t: Float) -> SIMD3<Float> {
            let t = min(max(t, 0), duration)
            if t >= duration { return end }
            let seg = segments.last { $0.t0 <= t } ?? segments[0]
            return Ballistics.evaluate(seg, t, gravity)
        }

        /// Desk-space velocity at time `t` (zero once it has ended).
        public func velocity(at t: Float) -> SIMD3<Float> {
            guard t < duration else { return .zero }
            let t = max(t, 0)
            let seg = segments.last { $0.t0 <= t } ?? segments[0]
            return Ballistics.velocityOf(seg, t, gravity)
        }

        /// Core art point of the bottom at time `t`.
        public func screenPoint(at t: Float) -> SIMD2<Float> {
            projection.project(position(at: t))
        }

        /// Whole-px core points sampled `fps` times a second, end included.
        public func screenPath(fps: Float = 60) -> [ArtPoint] {
            let n = max(1, Int((duration * fps).rounded(.up)))
            return (0...n).map { DeskProjection.snap(screenPoint(at: Float($0) / fps)) }
        }
    }

    // MARK: Release

    /// Turns a carry release at core point `point` with core velocity `velocity` (px/s, y-down) into a desk-space
    /// start. Below the desk's front edge, or above it faster than `frontFlingSpeed`, it starts just in front of
    /// the desk (`frontPlaneD`) moving as the hand did on screen, so it can reach the basket and the floor. Slower
    /// releases over the desk top face start on the plane at height `lift` with `vd = −2·vy`; above the desk's
    /// back edge, against the back wall.
    public static func release(
        at point: SIMD2<Float>, velocity: SIMD2<Float>, lift: Float = 2, params: Params = .standard
    ) -> (position: SIMD3<Float>, velocity: SIMD3<Float>) {
        let proj = params.projection
        let backY = proj.frontY - params.backD * proj.k
        let fast = velocity.isFinite && (velocity * velocity).sum() > params.frontFlingSpeed * params.frontFlingSpeed
        if point.y >= backY, point.y <= proj.frontY, !fast {
            let p = proj.unproject(point, z: lift)
            return (SIMD3(p.x, min(max(p.y, 0), params.backD), lift), SIMD3(velocity.x, -velocity.y / proj.k, 0))
        }
        let d: Float = point.y < backY && !fast ? params.backD : params.frontPlaneD
        let z = proj.frontY - point.y - d * proj.k
        return (SIMD3(point.x, d, z), SIMD3(velocity.x, 0, -velocity.y))
    }

    /// A token pushed off the desk at plane point `(x, d)` with plane velocity `(vx, vd)`.
    public static func pushOff(at plane: SIMD2<Float>, velocity: SIMD2<Float>, params: Params = .standard) -> Toss {
        toss(from: SIMD3(plane.x, plane.y, 0), velocity: SIMD3(velocity.x, velocity.y, 0), params: params)
    }

    // MARK: Toss

    /// The arc from bottom point `start` with `velocity` (desk space). A `seed` applies the seeded variation.
    public static func toss(
        from start: SIMD3<Float>, velocity: SIMD3<Float>, seed: UInt64? = nil, params: Params = .standard
    ) -> Toss {
        var p0 = start.isFiniteVector ? start : SIMD3(params.basketX, 0, 0)
        var v0 = velocity.isFiniteVector ? velocity : .zero
        var rimE = params.rimRestitution
        if let seed {
            var rng = SplitMix64(seed: seed)
            func jitter(_ f: Float) -> Float { 1 + f * (2 * rng.nextFloat01() - 1) }
            v0 = SIMD3(v0.x * jitter(params.velocityJitter), v0.y * jitter(params.velocityJitter),
                       v0.z * jitter(params.velocityJitter))
            rimE = min(max(rimE * jitter(params.rimJitter), 0), 1)
        }
        p0.x = min(max(p0.x, params.roomX.lowerBound), params.roomX.upperBound)
        p0.y = min(p0.y, params.backD)
        p0.z = max(p0.z, params.floorZ)

        let g = params.gravity, r = params.radius, h = params.eventStep
        let walls = [params.basketX - params.rimRadius, params.basketX + params.rimRadius]
        var segments = [Segment(t0: 0, start: p0, velocity: v0)]
        var rimHits = 0
        var entered = false
        var t: Float = 0

        func inBasketDepth(_ p: SIMD3<Float>) -> Bool { abs(p.y - params.basketD) <= params.rimRadius }
        func overDesk(_ p: SIMD3<Float>) -> Bool {
            params.deskX.contains(p.x) && p.y >= 0 && p.y <= params.backD
        }
        func centre(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2(p.x, p.z + r) }
        /// The point of basket wall `k` (its rim top, or the wall below it) nearest to ball centre `c`.
        func wallPoint(_ k: Int, _ c: SIMD2<Float>) -> SIMD2<Float> { SIMD2(walls[k], min(c.y, params.rimZ)) }
        func touches(_ k: Int, _ p: SIMD3<Float>) -> Bool {
            guard inBasketDepth(p) else { return false }
            let c = centre(p)
            return simd_length(c - wallPoint(k, c)) < r
        }
        func isInside(_ p: SIMD3<Float>) -> Bool {
            inBasketDepth(p) && centre(p).y < params.rimZ && abs(p.x - params.basketX) < params.rimRadius
        }
        func finish(_ landing: Landing, at end: SIMD3<Float>, time: Float, impact: SIMD3<Float>) -> Toss {
            let kind: Kind = landing == .basket ? (rimHits == 0 ? .swish : .rimIn) : (rimHits == 0 ? .miss : .rimOut)
            return Toss(segments: segments, duration: time, landing: landing, kind: kind, rimHits: rimHits, end: end,
                        landingVelocity: impact, gravity: g, projection: params.projection)
        }
        /// Lands on the floor at `e` (time `te`), hopping on to the nearest free spot when furniture stands there.
        func floorLanding(_ e: SIMD3<Float>, _ te: Float, impact: SIMD3<Float>) -> Toss {
            let spot = Float(FloorLine.freeSpot(near: e.x, avoiding: params.floorAvoid))
            var end = SIMD3(e.x, e.y, params.floorZ)
            let gap = spot - end.x
            guard abs(gap) > 0.5 else {
                end.x = spot
                return finish(.floor(x: spot), at: end, time: te, impact: impact)
            }
            let hop = params.hopTime + params.hopTimePerPx * abs(gap)
            segments.append(Segment(t0: te, start: end, velocity: SIMD3(gap / hop, 0, g * hop / 2)))
            end.x = spot
            return finish(.floor(x: spot), at: end, time: te + hop, impact: impact)
        }

        while t < params.maxTime {
            let seg = segments[segments.count - 1]
            let a = evaluate(seg, t, g)
            let t1 = t + h
            let b = evaluate(seg, t1, g)
            let vb = velocityOf(seg, t1, g)

            // Bisect the first time in (t, t1] at which `hit` turns true.
            func refine(_ hit: (SIMD3<Float>) -> Bool) -> Float {
                var lo = t, hi = t1
                for _ in 0..<16 {
                    let mid = (lo + hi) / 2
                    if hit(evaluate(seg, mid, g)) { hi = mid } else { lo = mid }
                }
                return hi
            }
            func restart(at te: Float, position pe: SIMD3<Float>, velocity ve: SIMD3<Float>) {
                segments.append(Segment(t0: te, start: pe, velocity: ve))
                t = te
            }

            if entered {
                // Inside the basket: bounce off the inner walls until it sinks out of sight.
                if b.z + r <= params.rimZ - params.sinkDepth {
                    let te = refine { $0.z + r <= params.rimZ - params.sinkDepth }
                    var e = evaluate(seg, te, g)
                    e.x = min(max(e.x, params.basketX - params.rimRadius + r), params.basketX + params.rimRadius - r)
                    return finish(.basket, at: e, time: te, impact: velocityOf(seg, te, g))
                }
                let inner = params.rimRadius - r
                if abs(b.x - params.basketX) > inner, (b.x - params.basketX) * vb.x > 0 {
                    let te = refine { abs($0.x - params.basketX) > inner }
                    var ve = velocityOf(seg, te, g)
                    ve.x = -ve.x * params.wallRestitution
                    restart(at: te, position: evaluate(seg, te, g), velocity: ve)
                    continue
                }
                t = t1
                continue
            }

            // The basket's walls and rim tops, from either side, while within its depth.
            if let k = walls.indices.first(where: { touches($0, b) }) {
                let te = refine { touches(k, $0) }
                let pe = evaluate(seg, te, g)
                var ve = velocityOf(seg, te, g)
                let c = centre(pe), q = wallPoint(k, c)
                var n = c - q
                let len = simd_length(n)
                n = len > 1e-4 ? n / len : SIMD2(a.x < walls[k] ? -1 : 1, 0)
                let vn = ve.x * n.x + ve.z * n.y
                if vn < 0 {
                    if q.y >= params.rimZ {
                        ve.x -= (1 + rimE) * vn * n.x
                        ve.z -= (1 + rimE) * vn * n.y
                        if rimHits < params.maxRimBounces {
                            rimHits += 1
                            // The last counted bounce settles it by the side of the rim its centre is on.
                            if rimHits == params.maxRimBounces, abs(c.x - params.basketX) < params.rimRadius {
                                entered = true
                                let inward: Float = c.x < params.basketX ? 1 : -1
                                ve.x = inward * abs(ve.x)
                            }
                        }
                        if rimHits == params.maxRimBounces, !entered {
                            let outward: Float = c.x < params.basketX ? -1 : 1
                            if ve.x * outward < params.rollOffSpeed { ve.x = outward * params.rollOffSpeed }
                        }
                    } else {
                        ve.x = -ve.x * params.wallRestitution
                    }
                    // Nudge out of contact so the next search starts clear of the wall.
                    let out = entered ? .zero : n * (r - len + 0.01)
                    restart(at: te, position: pe + SIMD3(out.x, 0, out.y), velocity: ve)
                    continue
                }
            }
            // A wall line crossed below the rim within one search step (far too fast to touch): bounce back.
            if inBasketDepth(b), let k = walls.indices.first(where: { (a.x - walls[$0]) * (b.x - walls[$0]) < 0 }) {
                let side: Float = a.x < walls[k] ? -1 : 1
                let te = refine { ($0.x - walls[k]) * side <= 0 }
                var pe = evaluate(seg, te, g)
                if centre(pe).y < params.rimZ {
                    var ve = velocityOf(seg, te, g)
                    ve.x = -ve.x * params.wallRestitution
                    pe.x = walls[k] + side * (r + 0.01)
                    restart(at: te, position: pe, velocity: ve)
                    continue
                }
            }
            // Below the rim between the walls: in (the walls keep anything else out, so it came through the mouth).
            if isInside(b) {
                entered = true
                t = t1
                continue
            }

            // Landing on the desk top (coming down onto it from above, or starting on it).
            if a.z >= 0, b.z < 0, vb.z < 0, overDesk(b) {
                let te = refine { $0.z <= 0 }
                var e = evaluate(seg, te, g)
                e.z = 0
                return finish(.desk(SIMD2(e.x, e.y)), at: e, time: te, impact: velocityOf(seg, te, g))
            }
            // The underside of the desk top.
            if a.z < 0, b.z >= 0, vb.z > 0, overDesk(b) {
                let te = refine { $0.z >= 0 }
                var ve = velocityOf(seg, te, g)
                ve.z = -ve.z * params.wallRestitution
                restart(at: te, position: evaluate(seg, te, g), velocity: ve)
                continue
            }
            // The floor.
            if b.z <= params.floorZ {
                let te = refine { $0.z <= params.floorZ }
                return floorLanding(evaluate(seg, te, g), te, impact: velocityOf(seg, te, g))
            }
            // Back wall and room sides.
            if b.y > params.backD, vb.y > 0 {
                let te = refine { $0.y > params.backD }
                var ve = velocityOf(seg, te, g)
                ve.y = -ve.y * params.wallRestitution
                restart(at: te, position: evaluate(seg, te, g), velocity: ve)
                continue
            }
            if (b.x < params.roomX.lowerBound && vb.x < 0) || (b.x > params.roomX.upperBound && vb.x > 0) {
                let left = b.x < params.roomX.lowerBound
                let te = refine { left ? $0.x < params.roomX.lowerBound : $0.x > params.roomX.upperBound }
                var ve = velocityOf(seg, te, g)
                ve.x = -ve.x * params.wallRestitution
                restart(at: te, position: evaluate(seg, te, g), velocity: ve)
                continue
            }
            t = t1
        }
        // Out of time (cannot happen under gravity within `maxTime` from the room): drop where it is.
        let last = segments[segments.count - 1]
        return floorLanding(evaluate(last, t, g), t, impact: .zero)
    }

    @inline(__always)
    static func evaluate(_ s: Segment, _ t: Float, _ g: Float) -> SIMD3<Float> {
        let u = t - s.t0
        return SIMD3(s.start.x + s.velocity.x * u, s.start.y + s.velocity.y * u,
                     s.start.z + s.velocity.z * u - 0.5 * g * u * u)
    }

    @inline(__always)
    static func velocityOf(_ s: Segment, _ t: Float, _ g: Float) -> SIMD3<Float> {
        SIMD3(s.velocity.x, s.velocity.y, s.velocity.z - g * (t - s.t0))
    }
}

extension SIMD3<Float> {
    /// Every component is finite.
    var isFiniteVector: Bool { x.isFinite && y.isFinite && z.isFinite }
}

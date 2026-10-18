import Foundation

/// The pen cup (DESIGN §2.2 E7): `upright → wobble → tipping (3 frames) → lying(dir) → righting → upright`.
///
/// It tips **only** from a deliberate gesture: a carry released faster than `tipSpeed` holding at least
/// `tipMinPens` pens, or the menu's Tip Out. Knocks, bonks and slow releases only wobble it. Reaching `lying` emits
/// `spill`; `spill(count:from:right:seed:)` gives every pen a seeded impulse and its deterministic landing spot.
/// A click on the lying cup stands it back up. Its position always keeps the cup on the desk and clear of the
/// furniture. Resting states commit through `settled` (dispatch `.cupState`).
public struct PenCupMachine: Sendable, Equatable {
    public struct Params: Hashable, Sendable {
        public var tipSpeed: Float = 400
        public var tipMinPens = 3
        /// Seconds per tipping / righting frame.
        public var frameDuration: Float = 1.0 / 12
        public var wobbleDuration: Float = 0.5
        /// Wobble frequency (Hz) and peak lean (frames).
        public var wobbleFrequency: Float = 7
        public var wobbleLean: Float = 2
        /// A release this fast without tipping wobbles the cup.
        public var wobbleSpeed: Float = 120
        /// Carry acceleration (px/s²) per frame of lean.
        public var leanAcceleration: Float = 1500
        // Spill.
        public var spillSpeed: ClosedRange<Float> = 150...300
        public var spillSpreadDegrees: Float = 30
        /// Pens slide like piles: linear damping (1/s), so they travel `speed / damping`.
        public var spillDamping: Float = DeskPlanePhysics.pileLinearDamping
        /// Where pens leave a lying cup, from its position (plane px, along the tip direction): just past its mouth
        /// (`lyingFootprint`), so a spilled pen never lands on the cup.
        public var mouthReach: Float = 31

        public init() {}

        public static let standard = Params()
    }

    public enum Phase: Hashable, Sendable {
        case upright
        case wobble(elapsed: Float, amplitude: Float)
        case tipping(elapsed: Float, right: Bool)
        case lying(right: Bool)
        case righting(elapsed: Float, right: Bool)
    }

    public enum Event: Equatable, Sendable {
        case wobble
        /// A 7th pen (or a drop while lying) was refused.
        case bonk
        /// Started tipping over toward the right (`true`) or left.
        case tipped(right: Bool)
        /// Lying on its side: spill the pens now.
        case spill(right: Bool)
        case righted
        /// A resting state to commit (dispatch `.cupState`).
        case settled(PenCupState)
    }

    /// One spilled pen.
    public struct Spill: Hashable, Sendable {
        /// Pen order in the cup (0 = first in).
        public var index: Int
        /// Desk-plane start (the cup's mouth, squeezed clear of furniture) and impulse velocity `(vx, vd)`.
        public var start: SIMD2<Float>
        public var velocity: SIMD2<Float>
        /// Where it comes to rest: a desk point, or off the edge onto the floor or into the basket.
        public var landing: Ballistics.Landing
        /// Where it left the desk, if it did.
        public var edge: SIMD2<Float>?
    }

    public var params: Params
    public private(set) var phase: Phase
    /// Desk-plane position `(x, d)`.
    public private(set) var position: SIMD2<Float>
    /// Lean while carried (−2…2 frames).
    public private(set) var carryLean = 0
    // MARK: tidy (0.3.0)
    /// Put-away objects, whose footprints the cup need not keep clear of (an away plant or phone stand, Erratum 30).
    public var stowed: Set<StowID> = []

    /// Persisted `state` strings.
    public static let uprightName = "upright", lyingLeftName = "lyingLeft", lyingRightName = "lyingRight"

    public init(_ state: PenCupState = PenCupState(), params: Params = .standard, stowed: Set<StowID> = []) {
        self.params = params
        self.stowed = stowed
        let pos = Self.onDesk(state.pos.isFinite ? state.pos : PenCupState().pos)
        self.position = Self.isClear(pos, stowed: stowed) ? pos : PenCupState().pos
        switch state.state {
        case Self.lyingLeftName: phase = .lying(right: false)
        case Self.lyingRightName: phase = .lying(right: true)
        default: phase = .upright
        }
    }

    /// The state to persist (a transition's destination).
    public var state: PenCupState {
        let name: String
        switch phase {
        case .upright, .wobble, .righting: name = Self.uprightName
        case let .tipping(_, right), let .lying(right): name = right ? Self.lyingRightName : Self.lyingLeftName
        }
        return PenCupState(state: name, pos: position)
    }

    /// The sprite pose.
    public var pose: PropArt.PenCupPose {
        switch phase {
        case .upright, .wobble: return .upright
        case let .lying(right): return .lying(right: right)
        case let .tipping(elapsed, _): return .tipping(min(2, Int(elapsed / params.frameDuration)))
        case let .righting(elapsed, _): return .tipping(2 - min(2, Int(elapsed / params.frameDuration)))
        }
    }

    /// Mirror the tipping frames (PropArt draws them tipping right).
    public var mirrored: Bool {
        switch phase {
        case let .tipping(_, right), let .righting(_, right): !right
        default: false
        }
    }

    /// Lean in frames (−2…2): the wobble, or the carry's acceleration.
    public var lean: Int {
        guard case let .wobble(t, amp) = phase else { return carryLean }
        let decay = max(0, 1 - t / params.wobbleDuration)
        let s = Float(sin(Double(2 * Float.pi * params.wobbleFrequency * t)))
        return Int((amp * decay * s).rounded())
    }

    public var isUpright: Bool {
        switch phase {
        case .upright, .wobble: true
        default: false
        }
    }

    public var isLying: Bool { if case .lying = phase { true } else { false } }

    public var needsFrames: Bool {
        switch phase {
        case .upright, .lying: false
        default: true
        }
    }

    /// A pen can go in: upright with room.
    public func canAccept(count: Int) -> Bool { isUpright && count < ContainerSpec.penCup.hardCap }

    /// The last pen can be pulled out (LIFO).
    public func canPull(count: Int) -> Bool { isUpright && count > 0 }

    // MARK: Inputs

    /// A refused drop: the cup wobbles.
    public mutating func bonk() -> [Event] {
        guard isUpright else { return [.bonk] }
        phase = .wobble(elapsed: 0, amplitude: params.wobbleLean)
        return [.bonk, .wobble]
    }

    // MARK: harden
    /// Ends a wobble at once, upright (Reduce Motion).
    public mutating func stillWobble() {
        if case .wobble = phase { phase = .upright }
    }

    /// A desk knock: wobbles an upright cup. Never tips it.
    public mutating func knock(strength: Float = 1) -> [Event] {
        guard isUpright else { return [] }
        let s = strength.isFinite ? min(max(strength, 0), 1) : 0
        phase = .wobble(elapsed: 0, amplitude: max(1, (params.wobbleLean * s).rounded()))
        return [.wobble]
    }

    /// Whether the cup's footprint at `pos` lies on the desk, clear of the furniture (but for put-away objects').
    public static func isValidPosition(_ pos: SIMD2<Float>, stowed: Set<StowID> = []) -> Bool {
        pos.isFinite && onDesk(pos) == pos && isClear(pos, stowed: stowed)
    }

    /// `pos` moved onto the desk so the whole footprint stands on it.
    static func onDesk(_ pos: SIMD2<Float>) -> SIMD2<Float> {
        let desk = DeskPlanePhysics.desk, f = DeskPlanePhysics.penCupFootprint(at: pos)
        let half = f.width / 2
        return SIMD2(min(max(pos.x, desk.x + half), desk.x + desk.width - half),
                     min(max(pos.y, desk.d), desk.d + desk.depth - f.depth))
    }

    /// The cup's footprint on the plane: standing (and while tipping), around its position; lying, beside it on
    /// the side it fell, from its bottom to its mouth (`lyingFootprint`).
    public var footprint: DeskPlaneRect {
        if case let .lying(right) = phase { return Self.lyingFootprint(at: position, right: right) }
        return DeskPlanePhysics.penCupFootprint(at: position)
    }

    /// Where the cup lies after tipping toward the right (`right`) or left from `pos`: it turns about its bottom
    /// corner on that side, so its body spans 4…23 px out from where its centre stood (`PropArt.penCup` lying).
    public static func lyingFootprint(at pos: SIMD2<Float>, right: Bool) -> DeskPlaneRect {
        let up = DeskPlanePhysics.penCupFootprint(at: pos)
        let near: Float = 4, far: Float = 23
        return DeskPlaneRect(x: right ? pos.x + near : pos.x - far, d: up.d, width: far - near, depth: up.depth)
    }

    /// Whether the cup's footprint at `pos` keeps clear of the furniture that is out.
    static func isClear(_ pos: SIMD2<Float>, stowed: Set<StowID> = []) -> Bool {
        let f = DeskPlanePhysics.penCupFootprint(at: pos)
        return !DeskPlanePhysics.footprints(stowed: stowed).values.contains { $0.intersects(f) }
    }

    /// While carried as a prop: follows `position` as far as the desk and the furniture let it (sliding along
    /// what it meets), leaning against the acceleration.
    public mutating func carry(to position: SIMD2<Float>, acceleration: SIMD2<Float>) {
        guard isUpright, position.isFinite else { return }
        let target = Self.onDesk(position)
        if Self.isClear(target, stowed: stowed) {
            self.position = target
        } else if Self.isClear(SIMD2(target.x, self.position.y), stowed: stowed) {
            self.position.x = target.x
        } else if Self.isClear(SIMD2(self.position.x, target.y), stowed: stowed) {
            self.position.y = target.y
        }
        let a = acceleration.isFinite ? acceleration.x : 0
        carryLean = Int(min(max(-a / params.leanAcceleration, -2), 2).rounded())
    }

    /// The carry ended with plane velocity `velocity`: a deliberate flick (faster than `tipSpeed` with at least
    /// `tipMinPens` pens) tips the cup that way; otherwise it stands (wobbling after a brisk release).
    public mutating func release(velocity: SIMD2<Float>, count: Int) -> [Event] {
        guard isUpright else { return [] }
        carryLean = 0
        let v = velocity.isFinite ? velocity : .zero
        let speed = (v * v).sum().squareRoot()
        if speed > params.tipSpeed && count >= params.tipMinPens {
            return startTip(right: v.x >= 0)
        }
        if speed > params.wobbleSpeed {
            phase = .wobble(elapsed: 0, amplitude: params.wobbleLean)
            return [.wobble, .settled(state)]
        }
        phase = .upright
        return [.settled(state)]
    }

    /// The menu's Tip Out.
    public mutating func tipOut(right: Bool = true) -> [Event] {
        guard isUpright else { return [] }
        carryLean = 0
        return startTip(right: right)
    }

    /// Click on the lying cup: it rights itself.
    public mutating func standUp() -> [Event] {
        guard case let .lying(right) = phase else { return [] }
        phase = .righting(elapsed: 0, right: right)
        return []
    }

    /// The model changed under the machine (undo): jump to it.
    public mutating func sync(_ state: PenCupState) {
        guard state != self.state else { return }
        self = PenCupMachine(state, params: params, stowed: stowed)
    }

    mutating func startTip(right: Bool) -> [Event] {
        phase = .tipping(elapsed: 0, right: right)
        return [.tipped(right: right)]
    }

    public mutating func step(_ dt: Float) -> [Event] {
        guard let dt = SimClock.step(dt) else { return [] }
        let total = 3 * params.frameDuration
        switch phase {
        case .upright, .lying:
            return []
        case let .wobble(t, amp):
            let n = t + dt
            phase = n >= params.wobbleDuration ? .upright : .wobble(elapsed: n, amplitude: amp)
            return []
        case let .tipping(t, right):
            let n = t + dt
            guard n >= total else {
                phase = .tipping(elapsed: n, right: right)
                return []
            }
            phase = .lying(right: right)
            return [.spill(right: right), .settled(state)]
        case let .righting(t, right):
            let n = t + dt
            guard n >= total else {
                phase = .righting(elapsed: n, right: right)
                return []
            }
            phase = .upright
            return [.righted, .settled(state)]
        }
    }

    // MARK: Spill

    /// Where `count` pens go when the cup at `position` tips toward the right (`right`) or left: each leaves the
    /// mouth with a seeded impulse of `spillSpeed` within ±`spillSpreadDegrees` of `direction` (the flick that
    /// tipped it, plane px/s; nil or zero: straight out of the mouth) and slides as a pile would (stopping at the
    /// back wall's line and short of furniture and the cup; an away plant's or phone stand's strip is free, `stowed`);
    /// pens that cross the desk's front or side edge fly off on a `Ballistics` arc. Deterministic for a seed.
    public static func spill(
        count: Int, from position: SIMD2<Float>, right: Bool, seed: UInt64, direction: SIMD2<Float>? = nil,
        params: Params = .standard, ballistics: Ballistics.Params = .standard, stowed: Set<StowID> = []
    ) -> [Spill] {
        guard count > 0, position.isFinite else { return [] }
        var rng = SplitMix64(seed: seed)
        let dir: Float = right ? 1 : -1
        let desk = DeskPlanePhysics.desk
        let half = DeskPlanePhysics.pileSize / 2
        let own = lyingFootprint(at: position, right: right)
        // The aim: along the flick (its sideways part never against the side the cup fell to), else out of the mouth.
        var aim = SIMD2<Float>(dir, 0)
        if let f = direction, f.isFinite, (f * f).sum() > 1e-6 {
            let g = SIMD2(f.x * dir < 0 ? 0 : f.x, f.y)
            let len = (g * g).sum().squareRoot()
            if len > 1e-3 { aim = g / len }
        }
        let base = Float(atan2(Double(aim.y), Double(aim.x)))
        let mouth = SIMD2(position.x + dir * params.mouthReach, position.y + 4)
        let backLimit = desk.d + desk.depth - half.y
        var out: [Spill] = []
        for i in 0..<count {
            let spread = (2 * rng.nextFloat01() - 1) * params.spillSpreadDegrees * .pi / 180
            let speed = params.spillSpeed.lowerBound
                + (params.spillSpeed.upperBound - params.spillSpeed.lowerBound) * rng.nextFloat01()
            var u = SIMD2(Float(cos(Double(base + spread))), Float(sin(Double(base + spread))))
            let velocity = u * speed
            var reach = speed / max(params.spillDamping, 0.01)
            func blocked(_ q: SIMD2<Float>, moved: Float) -> Bool {
                let body = DeskPlaneRect.centred(at: q, size: DeskPlanePhysics.pileSize)
                return DeskPlanePhysics.footprints(stowed: stowed).values.contains { $0.intersects(body) }
                    || (moved > 2 && own.intersects(body))
            }
            var p = mouth
            p.y = min(p.y, backLimit)
            // A mouth against furniture: the pen squeezes out toward the front first.
            var squeeze = 0
            while blocked(p, moved: 0), squeeze < 24 {
                p.y -= 1
                squeeze += 1
            }
            let start = p
            var landing: Ballistics.Landing?
            var edge: SIMD2<Float>?
            var s: Float = 0
            var bounces = 0
            while s < reach {
                let step = min(1, reach - s)
                var q = p + u * step
                if q.y > backLimit {
                    // Slides along the back wall.
                    q.y = backLimit
                    u = SIMD2(u.x, 0)
                    if u.x == 0 { break }
                }
                if blocked(q, moved: s) {
                    // Bounces off furniture and scatters toward the front, losing half its way.
                    guard bounces < 2 else { break }
                    bounces += 1
                    let b = SIMD2(-u.x * 0.3, -max(abs(u.y), 0.6))
                    u = b / (b * b).sum().squareRoot()
                    reach = s + (reach - s) * 0.5
                    continue
                }
                if q.y < desk.d || q.x < desk.x || q.x > desk.x + desk.width {
                    let left = max(0, speed - params.spillDamping * s)
                    let toss = Ballistics.pushOff(at: q, velocity: u * left, params: ballistics)
                    landing = toss.landing
                    edge = q
                    break
                }
                p = q
                s += step
            }
            out.append(Spill(index: i, start: start, velocity: velocity, landing: landing ?? .desk(p), edge: edge))
        }
        return out
    }
}

import Foundation

/// The pen cup (DESIGN §2.2 E7): `upright → wobble → tipping (3 frames) → lying(dir) → righting → upright`.
///
/// It tips **only** from a deliberate gesture: a carry released faster than `tipSpeed` holding at least
/// `tipMinPens` pens, or the menu's Tip Out. Knocks, bonks and slow releases only wobble it. Reaching `lying` emits
/// `spill`; `spill(count:from:right:seed:)` gives every pen a seeded impulse and its deterministic landing spot.
/// A click on the lying cup stands it back up. Resting states commit through `settled` (dispatch `.cupState`).
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
        /// Where pens leave a lying cup, from its position (plane px, along the tip direction).
        public var mouthReach: Float = 15

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
        /// Desk-plane start (the cup's mouth) and impulse velocity `(vx, vd)`.
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

    /// Persisted `state` strings.
    public static let uprightName = "upright", lyingLeftName = "lyingLeft", lyingRightName = "lyingRight"

    public init(_ state: PenCupState = PenCupState(), params: Params = .standard) {
        self.params = params
        self.position = state.pos.isFinite ? state.pos : PenCupState().pos
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

    /// A desk knock: wobbles an upright cup. Never tips it.
    public mutating func knock(strength: Float = 1) -> [Event] {
        guard isUpright else { return [] }
        let s = strength.isFinite ? min(max(strength, 0), 1) : 0
        phase = .wobble(elapsed: 0, amplitude: max(1, (params.wobbleLean * s).rounded()))
        return [.wobble]
    }

    /// While carried as a prop: follows `position`, leaning against the acceleration.
    public mutating func carry(to position: SIMD2<Float>, acceleration: SIMD2<Float>) {
        guard isUpright, position.isFinite else { return }
        self.position = position
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
        self = PenCupMachine(state, params: params)
    }

    mutating func startTip(right: Bool) -> [Event] {
        phase = .tipping(elapsed: 0, right: right)
        return [.tipped(right: right)]
    }

    public mutating func step(_ dt: Float) -> [Event] {
        guard dt > 0 else { return [] }
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

    /// Where `count` pens go when the cup at `position` tips toward the right (`right`) or left: each gets a seeded
    /// impulse of `spillSpeed` within ±`spillSpreadDegrees` of the tip direction and slides as a pile would
    /// (stopping at the back wall's line and short of furniture); pens that cross the desk's front or side edge
    /// fly off on a `Ballistics` arc. Deterministic for a seed.
    public static func spill(
        count: Int, from position: SIMD2<Float>, right: Bool, seed: UInt64, params: Params = .standard,
        ballistics: Ballistics.Params = .standard
    ) -> [Spill] {
        guard count > 0, position.isFinite else { return [] }
        var rng = SplitMix64(seed: seed)
        let dir: Float = right ? 1 : -1
        let desk = DeskPlanePhysics.desk
        let half = DeskPlanePhysics.pileSize / 2
        let own = DeskPlanePhysics.penCupFootprint(at: position)
        let mouth = SIMD2(position.x + dir * params.mouthReach, position.y + 4)
        let backLimit = desk.d + desk.depth - half.y
        var out: [Spill] = []
        for i in 0..<count {
            let spread = (2 * rng.nextFloat01() - 1) * params.spillSpreadDegrees * .pi / 180
            let speed = params.spillSpeed.lowerBound
                + (params.spillSpeed.upperBound - params.spillSpeed.lowerBound) * rng.nextFloat01()
            var u = SIMD2(dir * Float(cos(Double(spread))), Float(sin(Double(spread))))
            let velocity = u * speed
            var reach = speed / max(params.spillDamping, 0.01)
            func blocked(_ q: SIMD2<Float>, moved: Float) -> Bool {
                let body = DeskPlaneRect.centred(at: q, size: DeskPlanePhysics.pileSize)
                return DeskPlanePhysics.footprints.values.contains { $0.intersects(body) }
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
            out.append(Spill(index: i, start: mouth, velocity: velocity, landing: landing ?? .desk(p), edge: edge))
        }
        return out
    }
}

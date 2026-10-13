import Foundation

/// The rolling chair (DESIGN §2.2 E6): its left edge `x` (core px) rolls within `CoreLayout.chairTravel`.
///
/// A drag moves it directly; a release keeps 60% of the release velocity and coasts with rolling friction,
/// bouncing off the travel ends (the desk leg and the cabinet side) and off a cabinet drawer that is open past the
/// chair-block limit (E5). Rolling faster than `spinSpeed` spins it through the four facing frames; the spin decays
/// and lands on a whole frame. `settled` fires once per rest (dispatch `.chair(x, facing)`). Pure and deterministic.
public struct RollerSim: Sendable, Equatable {
    public struct Params: Hashable, Sendable {
        /// Left-edge travel (errata 7).
        public var travel: ClosedRange<Float> =
            Float(CoreLayout.chairTravel.lowerBound)...Float(CoreLayout.chairTravel.upperBound)
        /// Velocity lost per second, plus a small constant rolling resistance (px/s²) so it stops.
        public var friction: Float = 1.5
        public var rollingResistance: Float = 30
        /// Share of the pointer's release velocity the chair keeps.
        public var releaseKeep: Float = 0.6
        public var restitution: Float = 0.3
        public var maxSpeed: Float = 1200
        /// Facing frames cycle while rolling faster than this.
        public var spinSpeed: Float = 80
        /// Quarter turns per px rolled while spinning.
        public var spinPerPx: Float = 1.0 / 28
        /// Spin rate lost per second once slower than `spinSpeed`.
        public var spinDecay: Float = 3
        /// Below this spin rate (quarter turns/s) the chair eases onto the nearest frame.
        public var spinSnapRate: Float = 0.6
        public var restSpeed: Float = 2
        /// Slower contacts make no bump event.
        public var bumpSpeed: Float = 20
        /// A cabinet drawer that hits the chair pushes it away at least this fast (E5).
        public var drawerPush: Float = 120

        public init() {}

        public static let standard = Params()
    }

    public enum Event: Hashable, Sendable {
        /// Hit a travel end (`side` −1 left, +1 right).
        case bump(speed: Float, side: Int)
        /// Hit a cabinet drawer that is open past the block limit.
        case blockedByDrawer(speed: Float)
        /// Came to rest: whole-px `x` and facing frame (0 back, 1 right, 2 front, 3 left).
        case settled(x: Float, facing: Int)
    }

    public var params: Params
    /// Left edge (core px).
    public private(set) var x: Float
    public private(set) var v: Float = 0
    /// Facing in quarter turns (any real; `facing` is it rounded, mod 4).
    public private(set) var spin: Float
    public private(set) var spinRate: Float = 0
    public private(set) var isAsleep = true
    /// While set, the chair's left edge cannot pass this from the left (an open cabinet drawer).
    public private(set) var blockX: Float?
    var dragTarget: Float?
    var grabOffset: Float = 0
    var restCount = 0

    public init(x: Float = Float(CoreLayout.chair.x), facing: Int = 0, params: Params = .standard) {
        self.params = params
        let x0 = x.isFinite ? x : Float(CoreLayout.chair.x)
        self.x = min(max(x0, params.travel.lowerBound), params.travel.upperBound)
        self.spin = Float(((facing % 4) + 4) % 4)
    }

    public init(_ state: ChairState, params: Params = .standard) {
        self.init(x: state.x, facing: state.facing, params: params)
    }

    /// The facing frame (0 back, 1 right, 2 front, 3 left), as `PropArt.ChairFacing` raw values.
    public var facing: Int { ((Int(spin.rounded()) % 4) + 4) % 4 }
    public var chairFacing: PropArt.ChairFacing { PropArt.ChairFacing(rawValue: facing) ?? .back }
    /// Left edge in whole px for the sprite.
    public var pixelX: Int { Int(x.rounded()) }
    public var state: ChairState { ChairState(x: x.rounded(), facing: facing) }
    public var isDragging: Bool { dragTarget != nil }
    public var needsFrames: Bool { !isAsleep }

    /// The chair's right edge may not pass into the cabinet front by more than the block overlap.
    public static func cabinetBlockX(drawers: DrawerSim.Params = .standard) -> Float {
        Float(CoreLayout.cabinet.minX + drawers.chairBlockOverlap - CoreLayout.chair.w)
    }

    // MARK: Inputs

    /// The pointer grabbed the chair at core x `pointerX`.
    public mutating func beginDrag(pointerX: Float) {
        guard pointerX.isFinite else { return }
        grabOffset = pointerX - x
        dragTarget = x
        wake()
    }

    public mutating func drag(pointerX: Float) {
        guard dragTarget != nil, pointerX.isFinite else { return }
        dragTarget = pointerX - grabOffset
        wake()
    }

    /// Release with the pointer's fling velocity (px/s); the chair keeps `releaseKeep` of it.
    public mutating func endDrag(releaseVelocity: Float) {
        guard dragTarget != nil else { return }
        dragTarget = nil
        let rv = releaseVelocity.isFinite ? releaseVelocity : 0
        v = min(max(rv * params.releaseKeep, -params.maxSpeed), params.maxSpeed)
        wake()
    }

    /// Adds `dv` px/s (e.g. a drawer thunk).
    public mutating func push(_ dv: Float) {
        guard dv.isFinite, dragTarget == nil else { return }
        v = min(max(v + dv, -params.maxSpeed), params.maxSpeed)
        wake()
    }

    /// A cabinet drawer hit the chair: roll away from the cabinet, fast enough to clear the block.
    public mutating func pushedByDrawer() {
        let distance = max(0, x - (Self.cabinetBlockX() - 2))
        push(-max(params.drawerPush, speedToCoast(distance) * 1.05))
    }

    /// How far a chair rolling at `v0` coasts before it stops (`dv/dt = −f·v − r`).
    public func coastDistance(_ v0: Float) -> Float {
        let f = params.friction, r = params.rollingResistance, v = abs(v0)
        guard f > 0 else { return r > 0 ? v * v / (2 * r) : .infinity }
        guard r > 0 else { return v / f }
        return v / f - r / (f * f) * Float(log(Double(1 + f * v / r)))
    }

    /// The speed that coasts `distance` px (bisection on `coastDistance`).
    public func speedToCoast(_ distance: Float) -> Float {
        guard distance > 0 else { return 0 }
        var lo: Float = 0, hi = params.maxSpeed
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if coastDistance(mid) < distance { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// An open cabinet drawer blocks the chair (nil clears it). Applies only while the chair is left of it.
    public mutating func setBlock(_ maxX: Float?) {
        let b = maxX.flatMap { $0.isFinite ? $0 : nil }
        guard b != blockX else { return }
        blockX = b
        wake()
    }

    mutating func wake() {
        isAsleep = false
        restCount = 0
    }

    /// Hard sleep: stops where it is on a whole px and frame.
    public mutating func forceRest() -> [Event] {
        guard !isAsleep else { return [] }
        dragTarget = nil
        v = 0
        spinRate = 0
        spin = spin.rounded()
        x = min(max(x.rounded(), params.travel.lowerBound), params.travel.upperBound)
        isAsleep = true
        return [.settled(x: x, facing: facing)]
    }

    // MARK: Step

    public mutating func step(_ dt: Float) -> [Event] {
        guard !isAsleep, dt > 0 else { return [] }
        var events: [Event] = []
        let lo = params.travel.lowerBound
        let hiTravel = params.travel.upperBound
        // The drawer block only stops a chair that is left of it.
        let hi = blockX.map { x <= $0 + 0.5 ? min(hiTravel, $0) : hiTravel } ?? hiTravel
        let x0 = x

        if let target = dragTarget {
            x = min(max(target, lo), hi)
            let measured = (x - x0) / dt
            v = min(max(v + (measured - v) * 0.5, -params.maxSpeed), params.maxSpeed)
        } else {
            v /= 1 + params.friction * dt
            let drop = params.rollingResistance * dt
            v = abs(v) <= drop ? 0 : v - (v > 0 ? drop : -drop)
            x += v * dt
            if x < lo {
                x = lo
                if v < 0 {
                    if -v > params.bumpSpeed { events.append(.bump(speed: -v, side: -1)) }
                    v = -v * params.restitution
                }
            } else if x > hi {
                x = hi
                if v > 0 {
                    if v > params.bumpSpeed {
                        events.append(hi < hiTravel ? .blockedByDrawer(speed: v) : .bump(speed: v, side: 1))
                    }
                    v = -v * params.restitution
                }
            }
        }

        // Facing: spin with the roll while fast, then decay onto a whole frame.
        if abs(v) > params.spinSpeed {
            spinRate = v * params.spinPerPx
        } else {
            spinRate /= 1 + params.spinDecay * dt
            if abs(spinRate) < params.spinSnapRate {
                let target = spin.rounded()
                spinRate = 0
                spin += (target - spin) * min(1, 12 * dt)
                if abs(target - spin) < 0.02 { spin = target }
            }
        }
        spin += spinRate * dt
        if abs(spin) > 4096 { spin = spin.truncatingRemainder(dividingBy: 4) }

        if dragTarget == nil, abs(v) < params.restSpeed, spinRate == 0, spin == spin.rounded() {
            restCount += 1
            if restCount >= 3 {
                v = 0
                x = min(max(x.rounded(), lo), hiTravel)
                isAsleep = true
                events.append(.settled(x: x, facing: facing))
            }
        } else {
            restCount = 0
        }
        return events
    }
}

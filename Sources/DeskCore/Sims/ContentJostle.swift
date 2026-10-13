/// What lies inside a drawer slides as the drawer moves (DESIGN §2.2 E3): each item is a 1D damped spring along
/// the rail, driven by the drawer's acceleration (`−a`: a drawer yanked open leaves its contents behind, a slam
/// throws them to the back), bouncing off the interior's back and front walls.
///
/// Positions are content rows (y-down, larger = nearer the drawer front) of each item's base; `pixelOffsets` are
/// what the interior draws. Deterministic (per-item stiffness varies by a seeded hash, never by a clock), bounded
/// (every position stays inside `bounds`) and it sleeps once everything is still.
public struct ContentJostle: Sendable, Equatable {
    public struct Params: Hashable, Sendable {
        /// Spring back to the home row (1/s²) and damping (1/s).
        public var stiffness: Float = 260
        public var damping: Float = 9
        /// Each item's stiffness is scaled by a seeded factor in `1 ± stiffnessSpread`, so items move out of step.
        public var stiffnessSpread: Float = 0.3
        /// Fraction of the drawer's acceleration felt by the contents (friction lets heavy pulls through).
        public var coupling: Float = 1
        /// Accelerations below this (px/s²) are not felt: a gently drawn drawer leaves its contents in place
        /// (static friction).
        public var stiction: Float = 900
        /// Bounce off the interior walls.
        public var restitution: Float = 0.35
        public var maxSpeed: Float = 240
        /// Asleep when every item is within `sleepOffset` rows of home and slower than `sleepSpeed`.
        public var sleepOffset: Float = 0.3
        public var sleepSpeed: Float = 2
        /// Knock: per-item kick speed range (rows/s), signs seeded.
        public var knockKick: ClosedRange<Float> = 25...60

        public init() {}

        public static let standard = Params()
    }

    public var params: Params
    /// Rows an item's base may occupy (the interior's back to front wall).
    public private(set) var bounds: ClosedRange<Float>
    public private(set) var homes: [Float]
    /// Current base rows.
    public private(set) var positions: [Float]
    public private(set) var velocities: [Float]
    public private(set) var isAsleep = true
    let seed: UInt64

    /// Items resting at `homes` (clamped into `bounds`). `seed` varies the per-item springs.
    public init(homes: [Float], bounds: ClosedRange<Float>, seed: UInt64 = 0, params: Params = .standard) {
        self.params = params
        self.bounds = bounds
        self.seed = seed
        let h = homes.map { $0.isFinite ? min(max($0, bounds.lowerBound), bounds.upperBound) : bounds.upperBound }
        self.homes = h
        self.positions = h
        self.velocities = Array(repeating: 0, count: h.count)
    }

    public var count: Int { homes.count }
    public var needsFrames: Bool { !isAsleep }

    /// Displacement from home, rounded to whole rows.
    public var pixelOffsets: [Int] {
        zip(positions, homes).map { Int(($0 - $1).rounded()) }
    }

    /// Base rows rounded to whole rows.
    public var pixelPositions: [Int] { positions.map { Int($0.rounded()) } }

    /// Membership changed: new homes. Items that stay (by index) keep their motion; new ones start at home.
    public mutating func setHomes(_ newHomes: [Float]) {
        let h = newHomes.map { $0.isFinite ? min(max($0, bounds.lowerBound), bounds.upperBound) : bounds.upperBound }
        var pos = h, vel = Array(repeating: Float(0), count: h.count)
        for i in 0..<min(h.count, positions.count) {
            pos[i] = positions[i]
            vel[i] = velocities[i]
        }
        homes = h
        positions = pos
        velocities = vel
        if zip(positions, homes).contains(where: { abs($0 - $1) > params.sleepOffset }) { isAsleep = false }
    }

    /// Gives every item a velocity kick (rows/s), e.g. from a knock.
    public mutating func kick(_ dv: [Float]) {
        for i in velocities.indices where i < dv.count && dv[i].isFinite {
            velocities[i] = min(max(velocities[i] + dv[i], -params.maxSpeed), params.maxSpeed)
        }
        if dv.contains(where: { $0 != 0 }) { isAsleep = false }
    }

    /// A desk knock: each item hops by a seeded kick in `knockKick`, scaled by `strength` (0…1).
    public mutating func knock(strength: Float = 1, seed knockSeed: UInt64) {
        var rng = SplitMix64(seed: knockSeed ^ seed)
        let s = min(max(strength.isFinite ? strength : 0, 0), 1)
        let span = params.knockKick.upperBound - params.knockKick.lowerBound
        kick(homes.indices.map { _ in
            let speed = params.knockKick.lowerBound + span * rng.nextFloat01()
            return (rng.nextBool() ? speed : -speed) * s
        })
    }

    /// Hard sleep (DESIGN §4.6): everything back home and still.
    public mutating func forceRest() {
        positions = homes
        velocities = Array(repeating: 0, count: homes.count)
        isAsleep = true
    }

    /// The per-item stiffness factor (seeded, stable for an index).
    func stiffnessFactor(_ i: Int) -> Float {
        let u = Float(SplitMix64.mix(seed &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15) >> 40) * 0x1p-24
        return 1 + params.stiffnessSpread * (2 * u - 1)
    }

    /// Advances by `dt` with the drawer's acceleration `drawerAcceleration` (px/s², positive = speeding up while
    /// opening).
    public mutating func step(drawerAcceleration a: Float, _ dt: Float) {
        guard let dt = SimClock.step(dt), !homes.isEmpty else { return }
        let a = a.isFinite ? a : 0
        let felt = abs(a) > params.stiction ? -a * params.coupling : 0
        if isAsleep && felt == 0 { return }
        isAsleep = false
        let lo = bounds.lowerBound, hi = bounds.upperBound
        var calm = true
        for i in homes.indices {
            let k = params.stiffness * stiffnessFactor(i)
            var v = velocities[i]
            var x = positions[i]
            let force = felt - k * (x - homes[i])
            v = (v + force * dt) / (1 + params.damping * dt)
            v = min(max(v, -params.maxSpeed), params.maxSpeed)
            x += v * dt
            if x < lo {
                x = lo
                if v < 0 { v = -v * params.restitution }
            } else if x > hi {
                x = hi
                if v > 0 { v = -v * params.restitution }
            }
            positions[i] = x
            velocities[i] = v
            if abs(v) > params.sleepSpeed || abs(x - homes[i]) > params.sleepOffset { calm = false }
        }
        if calm && felt == 0 {
            positions = homes
            velocities = Array(repeating: 0, count: homes.count)
            isAsleep = true
        }
    }
}

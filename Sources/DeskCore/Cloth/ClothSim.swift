import Foundation

/// Tunable constants for `ClothSim` (DESIGN §2.2 E9). These are starting values; the cloth tests are the
/// contract, not the exact numbers.
public struct ClothParams: Hashable, Sendable, Codable {
    // Solver.
    public var substeps = 8
    public var gravity: Float = -600
    public var stretchCompliance: Float = 0
    /// Tuned in the M8 review from the spec's starting 1e-4 / 1e-2: heavy felt barely shears (so the mat moves as
    /// a whole instead of skewing) and holds a broad curve when lifted, yet still buckles into wrinkles.
    public var shearCompliance: Float = 1e-6
    public var bendCompliance: Float = 1e-3
    public var staticFriction: Float = 0.7
    public var kineticFriction: Float = 0.45
    /// Felt on wood is sticky: a resting particle ignores in-plane pushes below this many px per substep (scaled
    /// by the friction scale), so pushes buckle the cloth locally instead of shoving the whole mat, and wrinkles
    /// and folds stay put.
    public var stiction: Float = 0.03
    /// Fraction of in-plane motion removed per substep while in contact (sliding felt stops quickly).
    public var contactDamping: Float = 0.02
    /// Extra floor penetration (px) the keyboard's weight adds under it, so its region grips the desk harder than
    /// bare felt (a weighted particle is otherwise held to the floor but free in xy).
    public var keyboardPressure: Float = 0.2
    /// Floor offset of a face-up particle (`z ≥ H + thickness`).
    public var thickness: Float = 1
    /// Floor offset of an underside-up particle, so a folded flap lies on top of the layer below.
    public var foldedThickness: Float = 2
    /// Per-substep displacement clamp (px), a guard against blow-ups.
    public var maxSubstepMove: Float = 4
    public var initialJitter: Float = 0.01

    // Bounds (desk plane).
    public var xRange: ClosedRange<Float> = 12...500
    public var dRange: ClosedRange<Float> = 0...104
    public var zMax: Float = 72

    // Sleep.
    public var sleepSpeed: Float = 0.5
    public var sleepFrames = 30

    // Grabs.
    public var decideDistance: Float = 4
    public var edgeBand: Float = 10
    public var carryRadius: Float = 12
    /// Shape-matching gain per substep at the grab point.
    public var carryStiffness: Float = 0.06
    /// The gain falls off (Gaussian, this σ in material px) toward `carryFarFraction` far from the grab, so the far
    /// side lags like a rug dragged against friction and buckles into trailing wrinkles.
    public var carryFalloff: Float = 40
    public var carryFarFraction: Float = 0.1
    /// While the cursor is still, shape matching fades out with this time constant (s), so wrinkles left by the
    /// drag stay put instead of being ironed flat.
    public var carryStillFade: Float = 0.1
    public var carryLift: Float = 6
    /// The grabbed patch chases the pointer at most this fast (px/s): heavy felt follows a flick with a lag instead of
    /// whipping over into folds (M9 review).
    public var carrySpeed: Float = 300
    /// Bending compliance while carried, as a fraction of `bendCompliance`: felt held in the hand stays stiff.
    public var carryBendScale: Float = 0.1
    public var releaseKeep: Float = 0.4
    /// A carry faster than `creaseSpeed` (px/s) leaves a crease up to `creaseHeight` px (at `carrySpeed`); for
    /// `unflipFrames` after letting go, a corner it flips over lays back.
    public var creaseSpeed: Float = 90
    public var creaseHeight: Float = 5
    public var unflipFrames = 60
    public var peelHeight: Float = 12
    /// Half-width of the edge segment an edge peel holds. It also seeds the taper of the fold the peel guides along
    /// the edge (σ = this + reach²/8), so pulling one point lifts a tongue that widens as the pull goes further.
    public var peelEdgeHalfWidth: Float = 18
    public var tugHeight: Float = 1.5
    public var tugConeDegrees: Float = 60
    /// Frames over which a released peel is finished: laid down folded, or laid back flat (slower, as felt settles).
    public var layDownFrames = 8
    public var layBackFrames = 16
    /// A peel held still this long (frames) before it is let go stays propped up for `proppedFrames`, so a pile it
    /// uncovered can be picked out (O7), then lays back.
    public var propStillFrames = 18
    public var proppedFrames = 90
    /// Peel fold guide: below this many px between the grab point's flat place and the held point, the lift is pure
    /// physics; beyond it the flap follows a paper fold at `foldGain` per substep.
    public var foldMinDistance: Float = 6
    public var foldGain: Float = 0.35
    /// A fold's direction stays within this of the grabbed corner's bisector (or edge's inward normal).
    public var foldConeDegrees: Float = 30
    /// On release a peel stays folded only when it turned past this angle and the held point crossed this fraction of
    /// the mat along the fold (O8, "past the middle"); otherwise it lays back flat (O7).
    public var foldKeepDegrees: Float = 120
    public var foldKeepFraction: Float = 0.5
    /// Speed cap for pinned particles chasing their targets (px/s).
    public var pinSpeed: Float = 720

    // Transform.
    public var widthRange: ClosedRange<Float> = 96...300
    public var depthRange: ClosedRange<Float> = 48...104
    public var sizeSnap: Float = 6
    public var angleSnapDegrees: Float = 15
    public var transformSeconds: Float = 0.2

    // Scripts.
    public var smoothFrames = 20
    public var smoothPull: Float = 4
    public var smoothFriction: Float = 0.5
    public var unfoldSeconds: Float = 0.3
    public var peekSeconds: Float = 1.5
    public var peekHeight: Float = 16
    public var peekReach: Float = 30
    /// How far past the peeked point (plane px) the lifted edge is drawn back. The scene's mat draws it back 16 px,
    /// a pile's footprint and then some, so a pile tucked deeper under the edge is revealed too (M9).
    public var peekBeyond: Float = 8
    /// How far a peeked flap turns up (radians): up and leaning back past vertical; a back edge's lies over (so it
    /// never stands in front of what it uncovers).
    public var peekAngle: Float = 0.78 * .pi
    public var peekBackAngle: Float = 0.94 * .pi
    /// Desk knock: hop height (px), duration and the wavelength (px) of its ripple.
    public var knockHeight: Float = 2
    public var knockFrames = 12
    public var knockWavelength: Float = 40

    /// `matMode=flat` (DESIGN E9 fallbacks): bumps and covering stay; peel, fold, carry lift and Peek Under are off.
    public var flatMode = false

    public var projection = DeskProjection.standard

    public init() {}

    public static let standard = ClothParams()
}

/// A rectangle in the desk plane (`x`, `d` in art px).
public struct DeskPlaneRect: Hashable, Sendable, Codable {
    public var x: Float
    public var d: Float
    public var width: Float
    public var depth: Float

    public init(x: Float, d: Float, width: Float, depth: Float) {
        self.x = x
        self.d = d
        self.width = width
        self.depth = depth
    }

    public var center: SIMD2<Float> { SIMD2(x + width / 2, d + depth / 2) }

    public func contains(_ p: SIMD2<Float>) -> Bool {
        p.x >= x && p.x <= x + width && p.y >= d && p.y <= d + depth
    }
}

/// One cloth particle. `x` is desk-plane `(x, d, z)` with **z measured above the bump floor**, so the solver sees a
/// flat desk and draping over a bump never pulls material in; the absolute height is `x.z + ground`.
struct ClothParticle {
    var x: SIMD3<Float>
    /// Position at the start of the current substep.
    var p: SIMD3<Float>
    var v: SIMD3<Float>
    /// Inverse mass; 0 while pinned by a grab or script.
    var w: Float
    /// Floor offset above `H(x, d)`: `thickness`, or `foldedThickness` when underside-up.
    var floorOffset: Float
    /// Bump height `H(x, d)` under the particle, sampled at the end of the last step.
    var ground: Float
    /// Held to the floor by the keyboard.
    var weighted: Bool
    /// Moved by this frame's fold guide; its constraints with unguided particles only resist stretching.
    var guided = false
}

/// An XPBD distance constraint between two particles.
struct DistanceConstraint {
    var i: Int32
    var j: Int32
    var rest: Float
}

/// A particle driven kinematically toward a target for the current frame.
struct ClothPin {
    var index: Int32
    var from: SIMD3<Float>
    var to: SIMD3<Float>
}

/// Carry runtime: Gaussian patch plus global shape matching toward the grab-start pose + drag delta.
struct CarryRuntime {
    var hit: Int32
    /// Patch lift (px); grows with the drag so a press without motion does not tent the mat.
    var lift: Float
    /// Grab-start xy of every particle.
    var rest: [SIMD2<Float>]
    var restCentroid: SIMD2<Float>
    var patch: [(index: Int32, weight: Float)]
    /// Per-particle shape-matching gain.
    var gain: [Float]
    /// 1 while the cursor moves, fading to 0 while it is still.
    var activity: Float
    var targetFrom: SIMD2<Float>
    var targetTo: SIMD2<Float>
}

/// The desk mat cloth (DESIGN §2.2 E9): a pure, deterministic XPBD grid in the desk plane.
///
/// Particles live at `(x, d, z)` art px (`DeskProjection.standard`). The grid is `cols × rows`; particle
/// `(c, r)` is index `r · cols + c` with rest material coordinates `uv = (c · W/(cols−1), r · D/(rows−1))`.
/// `uv (0, 0)` is the corner the mat's `origin` refers to; `u` runs along the mat's width.
public struct ClothSim: Sendable {
    public var params: ClothParams
    public let cols: Int
    public let rows: Int
    /// Rest size (W, D) in art px.
    public internal(set) var restSize: SIMD2<Float>
    /// Rest material coordinates (art px) per particle; the pattern tiles by these.
    public internal(set) var uv: [SIMD2<Float>]
    public internal(set) var isAsleep = false
    /// Steps taken (asleep frames are not counted).
    public internal(set) var frameIndex = 0
    /// Max particle speed (px/s) over the last step.
    public internal(set) var lastMaxSpeed: Float = 0

    var parts: [ClothParticle]
    var stretch: [DistanceConstraint] = []
    var shear: [DistanceConstraint] = []
    var bend: [DistanceConstraint] = []
    var calmFrames = 0
    var seenBumpRevision: UInt64 = 0

    // Frame-level drive, rebuilt by `prepareFrame` from the grab/script state (ClothGrabs.swift).
    var grab: GrabState?
    var script: ScriptState?
    var pins: [ClothPin] = []
    var carry: CarryRuntime?
    /// This frame's fold guide (persistent storage): guided particles, their targets (relative z) and, per particle,
    /// its slot in those arrays (−1 when unguided).
    var guideIndices: [Int32] = []
    var guideTargets: [SIMD3<Float>] = []
    var guideSlot: [Int32] = []
    var frictionScale: Float = 1
    var keyboardOffset: SIMD2<Float>?
    var transformRun: TransformRun?
    /// Frames left in which whatever flips over after a carry lays back, and the folded count it started from.
    var postCarry: (frames: Int, folded: Int)?

    public var count: Int { cols * rows }

    /// A flat mat with its `uv (0,0)` corner at desk `origin`, rotated by `angle` (radians, counter-clockwise
    /// in the `x`/`d` plane), resting on a flat desk. `seed` drives the ±`initialJitter` z jitter.
    public init(
        origin: SIMD2<Float> = SIMD2(154, 8), size: SIMD2<Float> = SIMD2(204, 84), angle: Float = 0,
        cols: Int = 35, rows: Int = 15, seed: UInt64 = 1, params: ClothParams = .standard
    ) {
        precondition(cols >= 3 && rows >= 3, "cloth grid must be at least 3×3")
        self.params = params
        self.cols = cols
        self.rows = rows
        self.restSize = size
        self.uv = Self.restUV(cols: cols, rows: rows, size: size)
        var rng = SplitMix64(seed: seed)
        let c = Float(cos(Double(angle))), s = Float(sin(Double(angle)))
        var parts: [ClothParticle] = []
        parts.reserveCapacity(cols * rows)
        for q in uv {
            let jitter = (rng.nextFloat01() * 2 - 1) * params.initialJitter
            let x = SIMD3(origin.x + q.x * c - q.y * s, origin.y + q.x * s + q.y * c, params.thickness + jitter)
            parts.append(ClothParticle(
                x: x, p: x, v: .zero, w: 1, floorOffset: params.thickness, ground: 0, weighted: false
            ))
        }
        self.parts = parts
        guideSlot = Array(repeating: -1, count: cols * rows)
        rebuildConstraints()
    }

    /// Restores a mat from explicit absolute particle positions (row-major, `cols × rows`) over `bumps`; it starts
    /// asleep.
    public init(
        positions: [SIMD3<Float>], cols: Int, rows: Int, size: SIMD2<Float>, bumps: BumpField? = nil,
        params: ClothParams = .standard
    ) {
        precondition(cols >= 3 && rows >= 3 && positions.count == cols * rows, "bad cloth grid")
        self.params = params
        self.cols = cols
        self.rows = rows
        self.restSize = size
        self.uv = Self.restUV(cols: cols, rows: rows, size: size)
        self.parts = positions.map {
            let h = bumps?.height(x: $0.x, d: $0.y) ?? 0
            let x = SIMD3($0.x, $0.y, max($0.z - h, 0))
            return ClothParticle(x: x, p: x, v: .zero, w: 1, floorOffset: params.thickness, ground: h, weighted: false)
        }
        if let bumps { seenBumpRevision = bumps.revision }
        guideSlot = Array(repeating: -1, count: cols * rows)
        self.isAsleep = true
        rebuildConstraints()
        updateLayering()
    }

    // MARK: - Read access

    /// Absolute particle positions `(x, d, z)`, row-major.
    public var positions: [SIMD3<Float>] { parts.map { SIMD3($0.x.x, $0.x.y, $0.x.z + $0.ground) } }

    /// Particle velocities (px/s).
    public var velocities: [SIMD3<Float>] { parts.map(\.v) }

    /// Absolute position of particle `i`.
    public func position(_ i: Int) -> SIMD3<Float> {
        SIMD3(parts[i].x.x, parts[i].x.y, parts[i].x.z + parts[i].ground)
    }

    /// Height of particle `i` above its floor (`z − (H + offset)`, ≥ 0 when resting).
    public func lift(_ i: Int) -> Float { parts[i].x.z - parts[i].floorOffset }

    /// Whether particle `i` is held by the keyboard.
    public func isWeighted(_ i: Int) -> Bool { parts[i].weighted }

    public func index(col: Int, row: Int) -> Int { row * cols + col }

    /// The four corner particle indices: uv (0,0), (W,0), (W,D), (0,D).
    public var cornerIndices: [Int] { [0, cols - 1, count - 1, count - cols] }

    /// Unnormalized surface normal at particle `i` (central differences over the grid).
    public func normal(_ i: Int) -> SIMD3<Float> {
        let c = i % cols, r = i / cols
        let a = parts[r * cols + min(c + 1, cols - 1)].x - parts[r * cols + max(c - 1, 0)].x
        let b = parts[min(r + 1, rows - 1) * cols + c].x - parts[max(r - 1, 0) * cols + c].x
        return SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    // MARK: - Sleep

    /// Accepts the current pose as rest: zero velocity and sleep until woken.
    public mutating func forceSleep() {
        guard grab == nil, script == nil else { return }
        for i in parts.indices {
            parts[i].v = .zero
            parts[i].p = parts[i].x
        }
        isAsleep = true
        calmFrames = 0
        lastMaxSpeed = 0
    }

    /// Wakes the cloth (input, pile change).
    public mutating func wake() {
        isAsleep = false
        calmFrames = 0
    }

    // MARK: - Step

    /// Advances one frame (`dt`, default 1/60 s) of `params.substeps` XPBD substeps over the bump field's floor.
    /// A changed bump field (new `revision`) wakes the cloth; asleep cloth returns immediately.
    ///
    /// Pass the scene's one field every frame: particle heights are stored above the floor, so `nil` (a flat desk)
    /// after a field with bumps drops the mat by their height.
    public mutating func step(dt: Float = 1.0 / 60, bumps: BumpField? = nil) {
        if let bumps, bumps.revision != seenBumpRevision {
            seenBumpRevision = bumps.revision
            wake()
        }
        guard !isAsleep, dt > 0, dt.isFinite else { return }
        frameIndex += 1
        prepareFrame(dt: dt, bumps: bumps)
        updateLayering()
        simulate(dt: dt)
        if let bumps {
            bumps.withSampler { sampleGround($0) }
        } else {
            sampleGround(HeightSampler.flat)
        }
        // A released carry whose patch has caught up with where the pointer let go lets go now.
        if grab?.caughtUp == true { endGrab() }
        if let pc = postCarry, grab == nil, script == nil {
            if ClothMetrics.foldedCount(self) > pc.folded {
                postCarry = nil
                unflipFolds()
            } else {
                postCarry = pc.frames > 1 ? (pc.frames - 1, pc.folded) : nil
            }
        } else if grab != nil {
            postCarry = nil
        }
        updateSleep()
    }

    private mutating func updateSleep() {
        if grab == nil && script == nil && transformRun == nil && lastMaxSpeed < params.sleepSpeed {
            calmFrames += 1
            if calmFrames >= params.sleepFrames { forceSleep() }
        } else {
            calmFrames = 0
        }
    }

    /// Recomputes which particles are underside-up (normal z < 0) and so rest on the raised fold floor.
    mutating func updateLayering() {
        let cols = cols, rows = rows, up = params.thickness, folded = params.foldedThickness
        parts.withUnsafeMutableBufferPointer { P in
            for r in 0..<rows {
                let r0 = max(r - 1, 0) * cols, r1 = min(r + 1, rows - 1) * cols, row = r * cols
                for c in 0..<cols {
                    let a = P[row + min(c + 1, cols - 1)].x - P[row + max(c - 1, 0)].x
                    let b = P[r1 + c].x - P[r0 + c].x
                    let nz = a.x * b.y - a.y * b.x
                    P[row + c].floorOffset = nz < 0 ? folded : up
                }
            }
        }
    }

    /// Samples the bump floor under every particle (absolute height = relative z + ground).
    private mutating func sampleGround(_ floor: HeightSampler) {
        parts.withUnsafeMutableBufferPointer { P in
            for i in 0..<P.count { P[i].ground = floor.height(P[i].x.x, P[i].x.y) }
        }
    }

    private mutating func simulate(dt: Float) {
        let n = count, substeps = max(1, params.substeps)
        let h = dt / Float(substeps), invH = 1 / h, damp = 1 - 2 * h
        let gravity = params.gravity
        let muS = params.staticFriction * frictionScale, muK = params.kineticFriction * frictionScale
        let stick = params.stiction * frictionScale, slip = 1 - params.contactDamping * frictionScale
        let maxMove = params.maxSubstepMove
        let xr = params.xRange, dr = params.dRange, zMax = params.zMax
        let pinStep = params.pinSpeed * h
        let bendScale = carry != nil ? params.carryBendScale : 1
        let alphas = (params.stretchCompliance / (h * h), params.shearCompliance / (h * h),
                      params.bendCompliance * bendScale / (h * h))
        let stretch = stretch, shear = shear, bend = bend
        let pins = pins
        let carry = carry, guideIndices = guideIndices, guideTargets = guideTargets, foldGain = params.foldGain
        let press = params.keyboardPressure
        var maxSpeed2: Float = 0

        parts.withUnsafeMutableBufferPointer { P in
            for s in 0..<substeps {
                let frac = Float(s + 1) / Float(substeps)
                // Integrate free particles.
                for i in 0..<n {
                    P[i].p = P[i].x
                    guard P[i].w > 0 else { continue }
                    P[i].v.z += gravity * h
                    P[i].x += P[i].v * h
                }
                // Pinned particles chase their (sub-frame interpolated) targets at a capped speed.
                for pin in pins {
                    let i = Int(pin.index)
                    let target = pin.from + (pin.to - pin.from) * frac
                    let delta = target - P[i].x
                    let dist = length3(delta)
                    if dist > pinStep && dist > 0 {
                        P[i].x += delta * (pinStep / dist)
                    } else {
                        P[i].x = target
                    }
                }
                // Distance constraints, one Gauss-Seidel sweep.
                stretch.withUnsafeBufferPointer { solve($0, P, alphas.0) }
                shear.withUnsafeBufferPointer { solve($0, P, alphas.1) }
                bend.withUnsafeBufferPointer { solve($0, P, alphas.2, acrossFolds: false) }
                if let carry { applyCarry(carry, P, frac: frac) }
                for k in 0..<guideIndices.count {
                    let i = Int(guideIndices[k])
                    guard P[i].w > 0 else { continue }
                    P[i].x += (guideTargets[k] - P[i].x) * foldGain
                }
                // Floor, friction, bounds, displacement clamp.
                for i in 0..<n {
                    var x = P[i].x
                    let p = P[i].p
                    if !(x.x.isFinite && x.y.isFinite && x.z.isFinite) { x = p }
                    let floorZ = P[i].floorOffset
                    var contact = false
                    if P[i].w > 0 {
                        let weighted = P[i].weighted
                        if weighted || x.z < floorZ {
                            // The keyboard holds its particles to the floor and presses them into it.
                            contact = true
                            let pen = max(floorZ - x.z, 0) + (weighted ? press : 0)
                            x.z = floorZ
                            let tx = x.x - p.x, ty = x.y - p.y
                            let tl = (tx * tx + ty * ty).squareRoot()
                            if tl < max(muS * pen, stick) {
                                x.x = p.x
                                x.y = p.y
                            } else if tl > 0 {
                                let k = 1 - min(1, muK * pen / tl)
                                x.x = p.x + tx * k * slip
                                x.y = p.y + ty * k * slip
                            }
                        }
                        let m = x - p
                        let ml = length3(m)
                        if ml > maxMove { x = p + m * (maxMove / ml) }
                    }
                    x.x = min(max(x.x, xr.lowerBound), xr.upperBound)
                    x.y = min(max(x.y, dr.lowerBound), dr.upperBound)
                    x.z = min(x.z, zMax)
                    P[i].x = x
                    if P[i].w > 0 {
                        // Inelastic contact: being pushed out of the floor never launches the cloth.
                        var v = (x - p) * (invH * damp)
                        if contact && v.z > 0 { v.z = 0 }
                        P[i].v = v
                        if s == substeps - 1 {
                            let sp = v.x * v.x + v.y * v.y + v.z * v.z
                            if sp > maxSpeed2 { maxSpeed2 = sp }
                        }
                    } else {
                        P[i].v = (x - p) * invH
                    }
                }
            }
        }
        lastMaxSpeed = maxSpeed2.squareRoot()
    }

    // MARK: - Construction helpers

    static func restUV(cols: Int, rows: Int, size: SIMD2<Float>) -> [SIMD2<Float>] {
        let su = size.x / Float(cols - 1), sv = size.y / Float(rows - 1)
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(cols * rows)
        for r in 0..<rows {
            for c in 0..<cols { out.append(SIMD2(Float(c) * su, Float(r) * sv)) }
        }
        return out
    }

    /// Builds stretch (structural), shear (diagonal) and bend (skip-one) constraints with rest lengths from `uv`.
    mutating func rebuildConstraints() {
        var st: [DistanceConstraint] = [], sh: [DistanceConstraint] = [], bd: [DistanceConstraint] = []
        func add(_ list: inout [DistanceConstraint], _ a: Int, _ b: Int) {
            let d = uv[a] - uv[b]
            list.append(DistanceConstraint(i: Int32(a), j: Int32(b), rest: (d.x * d.x + d.y * d.y).squareRoot()))
        }
        for r in 0..<rows {
            for c in 0..<cols {
                let i = r * cols + c
                if c + 1 < cols { add(&st, i, i + 1) }
                if r + 1 < rows { add(&st, i, i + cols) }
                if c + 1 < cols && r + 1 < rows {
                    add(&sh, i, i + cols + 1)
                    add(&sh, i + 1, i + cols)
                }
                if c + 2 < cols { add(&bd, i, i + 2) }
                if r + 2 < rows { add(&bd, i, i + 2 * cols) }
            }
        }
        stretch = st
        shear = sh
        bend = bd
    }

    /// Updates rest size, `uv` and every constraint rest length (used by transforms).
    mutating func setRestSize(_ size: SIMD2<Float>) {
        restSize = size
        uv = Self.restUV(cols: cols, rows: rows, size: size)
        func refresh(_ list: inout [DistanceConstraint]) {
            for k in list.indices {
                let d = uv[Int(list[k].i)] - uv[Int(list[k].j)]
                list[k].rest = (d.x * d.x + d.y * d.y).squareRoot()
            }
        }
        refresh(&stretch)
        refresh(&shear)
        refresh(&bend)
    }
}

// MARK: - Solver kernels

@inline(__always)
func length3(_ a: SIMD3<Float>) -> Float { (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() }

/// One Gauss-Seidel sweep. Across a fold (one end face-up, the other underside-up) a constraint only resists
/// stretching, since a 6-px grid cannot hold a sharp crease at rest length; with `acrossFolds: false` it is skipped
/// entirely, so felt keeps its crease and a fold does not spring back open.
@inline(__always)
private func solve(
    _ cons: UnsafeBufferPointer<DistanceConstraint>, _ P: UnsafeMutableBufferPointer<ClothParticle>, _ alpha: Float,
    acrossFolds: Bool = true
) {
    for c in cons {
        let i = Int(c.i), j = Int(c.j)
        let crease = P[i].floorOffset != P[j].floorOffset || P[i].guided != P[j].guided
        if crease && !acrossFolds { continue }
        let wi = P[i].w, wj = P[j].w
        let ws = wi + wj
        guard ws > 0 else { continue }
        let d = P[i].x - P[j].x
        let len = length3(d)
        guard len > 1e-6, !crease || len > c.rest else { continue }
        let lambda = -(len - c.rest) / (ws + alpha)
        let corr = d * (lambda / len)
        P[i].x += corr * wi
        P[j].x -= corr * wj
    }
}

/// Carry: best-fit-rotation shape matching of every particle toward the grab-start pose moved by the drag,
/// anchored at the grabbed particle, plus Gaussian-weighted patch targets that lift slightly.
@inline(__always)
private func applyCarry(_ carry: CarryRuntime, _ P: UnsafeMutableBufferPointer<ClothParticle>, frac: Float) {
    let lift = carry.lift
    let n = P.count
    var cx: Float = 0, cy: Float = 0
    for i in 0..<n {
        cx += P[i].x.x
        cy += P[i].x.y
    }
    cx /= Float(n)
    cy /= Float(n)
    var sCross: Float = 0, sDot: Float = 0
    carry.rest.withUnsafeBufferPointer { R in
        for i in 0..<n {
            let qx = R[i].x - carry.restCentroid.x, qy = R[i].y - carry.restCentroid.y
            let rx = P[i].x.x - cx, ry = P[i].x.y - cy
            sCross += qx * ry - qy * rx
            sDot += qx * rx + qy * ry
        }
        let theta = atan2(Double(sCross), Double(sDot))
        let cs = Float(cos(theta)), sn = Float(sin(theta))
        let target = carry.targetFrom + (carry.targetTo - carry.targetFrom) * frac
        let hit = R[Int(carry.hit)]
        @inline(__always) func goal(_ i: Int) -> SIMD2<Float> {
            let ox = R[i].x - hit.x, oy = R[i].y - hit.y
            return SIMD2(target.x + ox * cs - oy * sn, target.y + ox * sn + oy * cs)
        }
        for i in 0..<n where P[i].w > 0 {
            let g = goal(i), k = carry.gain[i] * carry.activity
            P[i].x.x += (g.x - P[i].x.x) * k
            P[i].x.y += (g.y - P[i].x.y) * k
        }
        for (index, weight) in carry.patch {
            let i = Int(index)
            guard P[i].w > 0 else { continue }
            let g = goal(i)
            P[i].x.x += (g.x - P[i].x.x) * weight
            P[i].x.y += (g.y - P[i].x.y) * weight
            if !P[i].weighted {
                let zt = P[i].floorOffset + lift * weight
                if P[i].x.z < zt { P[i].x.z += (zt - P[i].x.z) * weight }
            }
        }
    }
}

/// Bilinear floor-height lookup over a `BumpField` grid (or a flat desk).
struct HeightSampler {
    let base: UnsafePointer<Float>?
    let nx: Int
    let ny: Int
    let x0: Float
    let d0: Float
    let invCell: Float

    static var flat: HeightSampler { HeightSampler(base: nil, nx: 0, ny: 0, x0: 0, d0: 0, invCell: 0) }

    @inline(__always)
    func height(_ x: Float, _ d: Float) -> Float {
        guard let base else { return 0 }
        var gx = (x - x0) * invCell, gy = (d - d0) * invCell
        guard gx.isFinite && gy.isFinite else { return 0 }
        let maxX = Float(nx - 1), maxY = Float(ny - 1)
        gx = gx < 0 ? 0 : (gx > maxX ? maxX : gx)
        gy = gy < 0 ? 0 : (gy > maxY ? maxY : gy)
        let ix = min(Int(gx), nx - 2), iy = min(Int(gy), ny - 2)
        let fx = gx - Float(ix), fy = gy - Float(iy)
        let i = iy * nx + ix
        let a = base[i], b = base[i + 1], c = base[i + nx], e = base[i + nx + 1]
        let top = a + (b - a) * fx, bottom = c + (e - c) * fx
        return top + (bottom - top) * fy
    }
}

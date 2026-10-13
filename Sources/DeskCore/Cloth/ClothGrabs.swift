import Foundation

/// How a mat grab drives the cloth (DESIGN §2.2 E9, grab modes).
public enum ClothGrabMode: String, Sendable, Hashable, CaseIterable {
    /// Waiting for the first `decideDistance` px of motion to pick peel, tug, unpeel or carry.
    case pending
    case carry, slide, peel, tug, transform
    /// Dragging a folded flap back open (the reverse of a peel).
    case unpeel
}

/// Modifier keys that affect a grab.
public struct ClothGrabModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// ⌥: rigid slide (interior) or transform (corner).
    public static let option = ClothGrabModifiers(rawValue: 1)
    /// ⇧: snap the transform angle to 15°.
    public static let shift = ClothGrabModifiers(rawValue: 2)
}

/// Where a grab started, from the hit particle's rest uv.
public enum ClothGrabRegion: Hashable, Sendable {
    case interior
    /// Within `edgeBand` of one edge; `inward` is the uv-space inward normal.
    case edge(inward: SIMD2<Float>)
    /// Within `edgeBand` of two edges; the index into `cornerIndices`.
    case corner(Int)
}

/// Mat frame: where uv (0, 0) sits on the desk and the mat's rotation (radians, CCW in the x/d plane).
public struct ClothFrame: Hashable, Sendable {
    public var origin: SIMD2<Float>
    public var angle: Float

    /// Desk xy of a material point.
    public func point(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        let c = Float(cos(Double(angle))), s = Float(sin(Double(angle)))
        return SIMD2(origin.x + uv.x * c - uv.y * s, origin.y + uv.x * s + uv.y * c)
    }

    /// Material coordinates of a desk xy point.
    public func material(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let c = Float(cos(Double(angle))), s = Float(sin(Double(angle)))
        let q = p - origin
        return SIMD2(q.x * c + q.y * s, -q.x * s + q.y * c)
    }
}

struct TransformGrab {
    var anchorCorner: Int
    var startAngle: Float
    var startSize: SIMD2<Float>
    var startDiagonal: SIMD2<Float>
}

/// A frame-by-frame eased resize/rotation about a desk point (the material point `anchorUV01 · size`), which may
/// itself ease from `fromAnchor` to `toAnchor` so the result fits the desk.
struct TransformRun {
    var anchor: SIMD2<Float>
    var anchorUV01: SIMD2<Float>
    var size: SIMD2<Float>
    var angle: Float
    var fromSize: SIMD2<Float>
    var fromAngle: Float
    var fromAnchor: SIMD2<Float>
    var toSize: SIMD2<Float>
    var toAngle: Float
    var toAnchor: SIMD2<Float>
    var progress: Float
}

/// Where a transform ends: size, angle (unwrapped near the current one) and anchor travel.
struct TransformPlan {
    var size: SIMD2<Float>
    var angle: Float
    var anchorUV01: SIMD2<Float>
    var from: SIMD2<Float>
    var to: SIMD2<Float>
}

/// An existing fold as a guide, plus the screen axis (the tip's folded → flat place) dragging along opens it.
struct UnpeelPlan {
    var spec: FoldSpec
    var from: SIMD2<Float>
    var to: SIMD2<Float>
}

struct GrabState {
    var mode: ClothGrabMode
    var hit: Int
    var region: ClothGrabRegion
    var startCursor: SIMD2<Float>
    var cursor: SIMD2<Float>
    var appliedCursor: SIMD2<Float>
    var modifiers: ClothGrabModifiers
    /// Absolute position of the hit particle at grab start.
    var hitStart: SIMD3<Float>
    /// Farthest the cursor has been from `startCursor` (px).
    var maxTravel: Float = 0
    var pinOffsets: [(index: Int32, offset: SIMD2<Float>)] = []
    var lastTarget: SIMD3<Float>?
    /// Flat frame of the mat when a peel started, the fold direction's axis, and the last fold it guided.
    var foldFrame: ClothFrame?
    var foldAxis = SIMD2<Float>(0, 1)
    var lastFold: FoldSpec?
    /// Set when the hit particle lies underside-up in a fold.
    var unpeel: UnpeelPlan?
    var carryRest: [SIMD2<Float>] = []
    var carryCentroid: SIMD2<Float> = .zero
    /// Bounding box of the grab-start pose, for keeping the carry on the desk.
    var carryLo: SIMD2<Float> = .zero
    var carryHi: SIMD2<Float> = .zero
    var carryPatch: [(index: Int32, weight: Float)] = []
    var carryGain: [Float] = []
    var carryActivity: Float = 1
    var lastCarryTarget: SIMD2<Float>?
    var transform: TransformGrab?
}

/// A paper fold (R2 §5.4): material on the flap side of a line in the mat's flat frame (`dot(p, normal) < line`)
/// turns about that line by `angle` as a rigid sheet (0 = flat, π = folded flat on top).
struct FoldSpec {
    var frame: ClothFrame
    var normal: SIMD2<Float>
    var line: Float
    var angle: Float
    /// With a finite `spread` the crease curves: its reach past `focus` (the grab point's flat xy) shrinks by a
    /// Gaussian (σ = `spread`) of the distance along the line, so a pulled edge point folds a tongue that tapers
    /// into the flat edge instead of the whole edge.
    var focus: SIMD2<Float> = .zero
    var spread: Float = .infinity
    /// Explicit flap members (empty: the flap side) and each member's offset from the ideal fold at angle π, which
    /// fades out as the fold opens, so an existing, imperfect fold turns back from exactly where it lies.
    var members: [Int32] = []
    var residual: [SIMD3<Float>] = []
}

extension FoldSpec {
    /// The fold that carries the grab point, flat at `frame.point(grabUV)`, toward `target` (xy) at `height` above
    /// the base layer: its line is equidistant from both, so the flap keeps its shape. Cloth folds locally, so the
    /// fold direction stays within `halfAngle` of `axis` (a corner's inward bisector or an edge's inward normal) and
    /// the reach along it is the drag projected onto that direction. With `band` (an edge peel) the crease tapers
    /// along the edge with σ = `band + reach² / 8`: a short pull lifts a local tongue, a pull past the middle folds
    /// nearly the whole edge. Nil below `minDistance`.
    init?(frame: ClothFrame, grabUV: SIMD2<Float>, target: SIMD2<Float>, height: Float, axis: SIMD2<Float>,
          halfAngle: Float, minDistance: Float, band: Float?) {
        let p0 = frame.point(grabUV), delta = target - p0
        guard length2(delta) > 1e-4 else { return nil }
        let base = atan2(Double(axis.y), Double(axis.x))
        var off = atan2(Double(delta.y), Double(delta.x)) - base
        off = atan2(sin(off), cos(off))
        let clamped = base + min(max(off, -Double(halfAngle)), Double(halfAngle))
        let n = SIMD2(Float(cos(clamped)), Float(sin(clamped)))
        let dist = dot2(delta, n)
        guard dist >= minDistance else { return nil }
        let h = max(0, height)
        let reach = (dist * dist + h * h) / (2 * dist)
        self.init(frame: frame, normal: n, line: dot2(p0, n) + reach,
                  angle: Float(atan2(Double(h), Double(-(dist * dist - h * h) / (2 * dist)))),
                  focus: p0, spread: band.map { $0 + reach * reach / 8 } ?? .infinity)
    }
}

enum ScriptState {
    case smooth(frame: Int, corners: [Int32], starts: [SIMD3<Float>], outward: [SIMD2<Float>])
    /// Turns a held fold to `toAngle` (π: folded flat; 0: laid back) over `frames`, then lets go.
    case layFold(frame: Int, frames: Int, spec: FoldSpec, toAngle: Float, pins: [Int32])
    case path(frame: Int, frames: Int, holdFrames: Int, indices: [Int32], from: [SIMD3<Float>], to: [SIMD3<Float>],
              arc: [Float])
}

extension ClothSim {
    // MARK: - Queries

    // Kept out of line: inlining these optional-struct reads into other modules trips a Swift 6.2.3 SIL ownership
    // verifier crash (CopyPropagation) in `-c release` test builds.
    public var grabMode: ClothGrabMode? {
        @inline(never) get { grab?.mode }
    }
    public var grabbedParticle: Int? {
        @inline(never) get { grab?.hit }
    }
    public var isScriptRunning: Bool {
        @inline(never) get { script != nil }
    }
    public var isTransforming: Bool {
        @inline(never) get { transformRun != nil }
    }
    /// Particles currently pinned (w = 0) by a grab or script.
    public var pinnedParticles: [Int] { pins.map { Int($0.index) } }

    /// Whether particle `i` lies underside-up (part of a folded flap).
    public func isFolded(_ i: Int) -> Bool { parts[i].floorOffset != params.thickness }

    /// The region of particle `i` by its rest uv.
    public func region(of i: Int) -> ClothGrabRegion {
        let q = uv[i], band = params.edgeBand
        let du = min(q.x, restSize.x - q.x), dv = min(q.y, restSize.y - q.y)
        let right = q.x > restSize.x / 2, back = q.y > restSize.y / 2
        if du <= band && dv <= band {
            switch (right, back) {
            case (false, false): return .corner(0)
            case (true, false): return .corner(1)
            case (true, true): return .corner(2)
            case (false, true): return .corner(3)
            }
        }
        if du <= band || dv <= band {
            if du < dv { return .edge(inward: SIMD2(right ? -1 : 1, 0)) }
            return .edge(inward: SIMD2(0, back ? -1 : 1))
        }
        return .interior
    }

    /// Best-fit rigid frame of the current pose (uv → desk xy).
    public func matFrame() -> ClothFrame { fitFrame(0..<count) }

    /// Mean xy of all particles.
    public var centroid: SIMD2<Float> {
        var c = SIMD2<Float>.zero
        for p in parts { c += SIMD2(p.x.x, p.x.y) }
        return c / Float(count)
    }

    // MARK: - Grabs

    /// Starts a grab on particle `particle` (from the raster's `owner[]`) with the cursor at core art point `cursor`.
    /// ⌥ picks slide (interior) or transform (corner) at once; interior grabs carry at once; edges, corners and folded
    /// flaps wait for `decideDistance` px of motion. Cancels a running script.
    public mutating func beginGrab(particle: Int, cursor: SIMD2<Float>, modifiers: ClothGrabModifiers = []) {
        guard particle >= 0 && particle < count, cursor.x.isFinite && cursor.y.isFinite else { return }
        if grab != nil { endGrab() }
        cancelScript()
        wake()
        let region = region(of: particle)
        var g = GrabState(
            mode: .pending, hit: particle, region: region, startCursor: cursor, cursor: cursor,
            appliedCursor: cursor, modifiers: modifiers, hitStart: position(particle)
        )
        if modifiers.contains(.option) {
            if case .corner(let k) = region {
                g.mode = .transform
                let anchorCorner = (k + 2) % 4
                let a = parts[cornerIndices[anchorCorner]].x, h = parts[particle].x
                g.transform = TransformGrab(
                    anchorCorner: anchorCorner, startAngle: matFrame().angle, startSize: restSize,
                    startDiagonal: SIMD2(h.x - a.x, h.y - a.y)
                )
            } else {
                g.mode = .slide
            }
        } else if isFolded(particle), !params.flatMode, let plan = unpeelPlan(hit: particle) {
            g.unpeel = plan
        } else if case .interior = region {
            g.mode = .carry
        }
        grab = g
        if g.mode == .carry { startCarry() }
    }

    /// Moves the grab cursor (core art px). Applied on the next `step`.
    public mutating func moveGrab(to cursor: SIMD2<Float>, modifiers: ClothGrabModifiers = []) {
        guard var g = grab, cursor.x.isFinite && cursor.y.isFinite else { return }
        wake()
        g.cursor = cursor
        g.maxTravel = max(g.maxTravel, length2(cursor - g.startCursor))
        g.modifiers = modifiers.union(g.modifiers.intersection(.option))
        grab = g
        if g.mode == .pending { decideMode() }
        if grab?.mode == .transform { updateTransformTarget() }
    }

    /// Ends the grab. Carry keeps `releaseKeep` of the velocity; a tug's corner falls where it is. A guided peel is
    /// finished over `layDownFrames`: a deliberate fold (turned past `foldKeepDegrees` with the held point carried
    /// past the middle of the mat) is laid down folded, straight, and stays folded; anything less lays back flat
    /// (O7: lifting part of the mat to reach a pile never leaves it dog-eared). An unpeel
    /// finishes whichever way it is nearer: open past vertical lays flat, otherwise it folds back down.
    public mutating func endGrab() {
        guard let g = grab else { return }
        wake()
        var lay: (FoldSpec, Float)?
        switch g.mode {
        case .carry:
            for i in parts.indices { parts[i].v *= params.releaseKeep }
        case .peel:
            for pin in pins { parts[Int(pin.index)].v = .zero }
            if var fold = g.lastFold, let target = g.lastTarget {
                let keep = fold.angle > params.foldKeepDegrees * .pi / 180
                    && pastMiddle(SIMD2(target.x, target.y), frame: fold.frame, region: g.region)
                // A kept fold settles with a straight crease (a tapered one cannot lie flat without stretching).
                if keep { fold.spread = .infinity }
                lay = (fold, keep ? .pi : 0)
            }
        case .unpeel:
            for pin in pins { parts[Int(pin.index)].v = .zero }
            if let fold = g.lastFold { lay = (fold, fold.angle > .pi / 2 ? .pi : 0) }
        case .tug:
            for pin in pins { parts[Int(pin.index)].v = .zero }
        default:
            break
        }
        let held = g.pinOffsets.map(\.index)
        releasePins()
        carry = nil
        clearGuide()
        grab = nil
        if let (spec, to) = lay {
            script = .layFold(frame: 0, frames: params.layDownFrames, spec: spec, toAngle: to, pins: held)
        }
    }

    /// Whether desk point `p` lies past the mat's middle as seen from the grabbed edge or corner (O8): beyond
    /// `foldKeepFraction` of the width or depth, measured from that side in the mat's flat `frame`.
    func pastMiddle(_ p: SIMD2<Float>, frame: ClothFrame, region: ClothGrabRegion) -> Bool {
        let q = frame.material(p), f = params.foldKeepFraction, w = restSize.x, d = restSize.y
        let fromLeft = q.x >= w * f, fromRight = q.x <= w * (1 - f)
        let fromFront = q.y >= d * f, fromBack = q.y <= d * (1 - f)
        switch region {
        case .edge(let inward):
            if inward.x > 0 { return fromLeft }
            if inward.x < 0 { return fromRight }
            return inward.y > 0 ? fromFront : fromBack
        case .corner(let k):
            return ((k == 0 || k == 3) ? fromLeft : fromRight) || ((k == 0 || k == 1) ? fromFront : fromBack)
        case .interior:
            return false
        }
    }

    private mutating func decideMode() {
        guard var g = grab else { return }
        let m = g.cursor - g.startCursor
        guard (m.x * m.x + m.y * m.y).squareRoot() >= params.decideDistance else { return }
        if let plan = g.unpeel {
            // Dragging a folded flap toward its flat place opens it; any other drag treats it as plain cloth.
            if dot2(m, plan.to - plan.from) > 0 {
                g.mode = .unpeel
                g.pinOffsets = [(Int32(g.hit), .zero)]
                grab = g
                return
            }
            g.unpeel = nil
        }
        let motion = SIMD2(m.x, -m.y / params.projection.k)
        let hitXY = SIMD2(parts[g.hit].x.x, parts[g.hit].x.y)
        let canPeel = !parts[g.hit].weighted && !params.flatMode
        switch g.region {
        case .corner:
            let out = hitXY - centroid
            let cosLimit = Float(cos(Double(params.tugConeDegrees) * .pi / 180))
            let ml = length2(motion), ol = length2(out)
            let cosA = ml > 0 && ol > 0 ? dot2(motion, out) / (ml * ol) : 0
            g.mode = cosA >= cosLimit ? .tug : (canPeel ? .peel : .carry)
        case .edge(let inwardUV):
            let frame = matFrame()
            let c = Float(cos(Double(frame.angle))), s = Float(sin(Double(frame.angle)))
            let inward = SIMD2(inwardUV.x * c - inwardUV.y * s, inwardUV.x * s + inwardUV.y * c)
            let upward = m.y < -0.5 * abs(m.x)
            g.mode = canPeel && (dot2(motion, inward) > 0 || upward) ? .peel : .carry
        case .interior:
            g.mode = .carry
        }
        grab = g
        switch g.mode {
        case .peel: startPeel()
        case .tug: startTug()
        case .carry: startCarry()
        default: break
        }
    }

    private mutating func startCarry() {
        guard var g = grab else { return }
        g.carryRest = parts.map { SIMD2($0.x.x, $0.x.y) }
        g.carryCentroid = g.carryRest.reduce(SIMD2<Float>.zero, +) / Float(count)
        g.carryLo = g.carryRest.reduce(SIMD2(repeating: .infinity)) { pointwiseMin($0, $1) }
        g.carryHi = g.carryRest.reduce(SIMD2(repeating: -.infinity)) { pointwiseMax($0, $1) }
        let sigma = params.carryRadius / 2, r2max = params.carryRadius * params.carryRadius
        var patch: [(index: Int32, weight: Float)] = []
        for i in 0..<count {
            let d = uv[i] - uv[g.hit]
            let r2 = d.x * d.x + d.y * d.y
            if r2 <= r2max { patch.append((Int32(i), Float(exp(Double(-r2 / (2 * sigma * sigma)))))) }
        }
        g.carryPatch = patch
        let s2 = 2 * params.carryFalloff * params.carryFalloff, far = params.carryFarFraction
        g.carryGain = uv.map { q in
            let d = q - uv[g.hit]
            let near = Float(exp(Double(-(d.x * d.x + d.y * d.y) / s2)))
            return params.carryStiffness * (far + (1 - far) * near)
        }
        grab = g
    }

    private mutating func startPeel() {
        guard var g = grab else { return }
        var members = [g.hit]
        if case .edge(let inward) = g.region {
            let alongU = inward.x == 0
            for i in 0..<count where i != g.hit && !parts[i].weighted {
                let d = uv[i] - uv[g.hit]
                let sameLine = alongU ? abs(d.y) < 1e-3 : abs(d.x) < 1e-3
                if sameLine && length2(d) <= params.peelEdgeHalfWidth { members.append(i) }
            }
        }
        g.pinOffsets = pinOffsets(members, hit: g.hit)
        let frame = matFrame()
        g.foldFrame = frame
        let inwardUV: SIMD2<Float>
        switch g.region {
        case .edge(let inward): inwardUV = inward
        case .corner(let k):
            let bisectors: [SIMD2<Float>] = [SIMD2(1, 1), SIMD2(-1, 1), SIMD2(-1, -1), SIMD2(1, -1)]
            inwardUV = bisectors[k] * (0.5 as Float).squareRoot()
        case .interior: inwardUV = SIMD2(0, 1)
        }
        let c = Float(cos(Double(frame.angle))), s = Float(sin(Double(frame.angle)))
        g.foldAxis = SIMD2(inwardUV.x * c - inwardUV.y * s, inwardUV.x * s + inwardUV.y * c)
        grab = g
    }

    /// Tug holds a single point, so the mat can swing around the held corner.
    private mutating func startTug() {
        guard var g = grab else { return }
        g.pinOffsets = pinOffsets([g.hit], hit: g.hit)
        grab = g
    }

    private func pinOffsets(_ members: [Int], hit: Int) -> [(index: Int32, offset: SIMD2<Float>)] {
        let h = parts[hit].x
        return members.map { (Int32($0), SIMD2(parts[$0].x.x - h.x, parts[$0].x.y - h.y)) }
    }

    /// The fold that underside-up particle `hit` belongs to, as a guide reproducing the current pose at angle π
    /// and lying flat at 0: members (folded or displaced particles) turn about the fold line fitted to them over the
    /// face-up base. The drag axis runs from the flap tip (the member farthest past the line) to its flat place.
    func unpeelPlan(hit: Int) -> UnpeelPlan? {
        let up = (0..<count).filter { !isFolded($0) }
        guard up.count >= 3 else { return nil }
        let frame = fitFrame(up)
        var members: [Int32] = [], flats: [SIMD2<Float>] = []
        var dir = SIMD2<Float>.zero
        for i in 0..<count {
            let f = frame.point(uv[i]), cur = SIMD2(parts[i].x.x, parts[i].x.y)
            guard isFolded(i) || length2(cur - f) > 3 else { continue }
            members.append(Int32(i))
            flats.append(f)
            if isFolded(i) { dir += cur - f }
        }
        let len = length2(dir)
        guard len > 1e-3, members.contains(Int32(hit)) else { return nil }
        let n = dir / len
        var line: Float = 0, folded = 0
        for (k, index) in members.enumerated() where isFolded(Int(index)) {
            let cur = SIMD2(parts[Int(index)].x.x, parts[Int(index)].x.y)
            line += dot2((flats[k] + cur) / 2, n)
            folded += 1
        }
        line /= Float(folded)
        var residual: [SIMD3<Float>] = [], tip = 0, reach = -Float.infinity
        residual.reserveCapacity(members.count)
        for (k, index) in members.enumerated() {
            let i = Int(index), r = line - dot2(flats[k], n)
            let ideal = flats[k] + n * (2 * r)
            residual.append(SIMD3(parts[i].x.x - ideal.x, parts[i].x.y - ideal.y, parts[i].x.z - params.foldedThickness))
            if r > reach {
                reach = r
                tip = k
            }
        }
        let t = Int(members[tip]), proj = params.projection
        let spec = FoldSpec(frame: frame, normal: n, line: line, angle: .pi, members: members, residual: residual)
        return UnpeelPlan(
            spec: spec, from: proj.project(position(t)),
            to: proj.project(SIMD3(flats[tip].x, flats[tip].y, parts[t].ground + params.thickness))
        )
    }

    // MARK: - Transform

    private mutating func updateTransformTarget() {
        guard let g = grab, let t = g.transform else { return }
        let anchorIndex = cornerIndices[t.anchorCorner]
        let a = SIMD2(parts[anchorIndex].x.x, parts[anchorIndex].x.y)
        let cursorDesk = params.projection.unproject(g.cursor, z: params.thickness)
        let start = params.projection.unproject(g.startCursor, z: params.thickness)
        let hit0 = SIMD2(g.hitStart.x, g.hitStart.y)
        let diag = hit0 + SIMD2(cursorDesk.x - start.x, cursorDesk.y - start.y) - a
        let r0 = length2(t.startDiagonal), r = length2(diag)
        guard r0 > 1e-3, r > 1e-3 else { return }
        let scale = r / r0
        var angle = t.startAngle
            + Float(atan2(Double(diag.y), Double(diag.x)) - atan2(Double(t.startDiagonal.y), Double(t.startDiagonal.x)))
        let snap: Float? = g.modifiers.contains(.shift) ? params.angleSnapDegrees * .pi / 180 : nil
        if let step = snap { angle = (angle / step).rounded() * step }
        let size = SIMD2(
            snapSize(t.startSize.x * scale, params.widthRange), snapSize(t.startSize.y * scale, params.depthRange)
        )
        startTransform(transformPlan(size: size, angle: wrapAngle(angle), anchorCorner: t.anchorCorner,
                                     canShift: false, snap: snap))
    }

    private func snapSize(_ v: Float, _ range: ClosedRange<Float>) -> Float {
        let q = params.sizeSnap
        var s = (min(max(v, range.lowerBound), range.upperBound) / q).rounded() * q
        if s > range.upperBound { s -= q }
        if s < range.lowerBound { s += q }
        return s
    }

    private func clampSize(_ size: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(min(max(size.x, params.widthRange.lowerBound), params.widthRange.upperBound),
              min(max(size.y, params.depthRange.lowerBound), params.depthRange.upperBound))
    }

    /// Eases the mat to `size` and `angle` over `transformSeconds` about the material point at `anchorCorner` (an
    /// index into `cornerIndices`; nil: the centre). Rest lengths and uv rescale with it, so the pattern never
    /// stretches. The pose is fitted to the desk first (`fittedTransform`): the mat turns only as far as its
    /// footprint fits the desk depth and slides as needed to stay on it.
    public mutating func transform(size: SIMD2<Float>, angle: Float, anchorCorner: Int? = nil) {
        guard size.x.isFinite, size.y.isFinite, angle.isFinite else { return }
        wake()
        startTransform(transformPlan(size: clampSize(size), angle: wrapAngle(angle), anchorCorner: anchorCorner,
                                     canShift: true))
    }

    /// The size and angle `transform(size:angle:)` would end at.
    public func fittedTransform(size: SIMD2<Float>, angle: Float) -> (size: SIMD2<Float>, angle: Float) {
        let plan = transformPlan(size: clampSize(size), angle: wrapAngle(angle), anchorCorner: nil, canShift: true)
        return (plan.size, wrapAngle(plan.angle))
    }

    /// Whether `transform(size:angle:)` would visibly change the mat; menu items (Rotate ±15°, Size S/M/L) are
    /// disabled when it would not.
    public func canTransform(size: SIMD2<Float>, angle: Float) -> Bool {
        let fit = fittedTransform(size: size, angle: angle)
        let current = transformRun.map { ($0.toSize, $0.toAngle) } ?? (restSize, matFrame().angle)
        return abs(wrapAngle(fit.angle - current.1)) > 0.25 * .pi / 180 || abs(fit.size.x - current.0.x) >= 1
            || abs(fit.size.y - current.0.y) >= 1
    }

    private static func anchorUV01(_ corner: Int?) -> SIMD2<Float> {
        switch corner {
        case 0: SIMD2(0, 0)
        case 1: SIMD2(1, 0)
        case 2: SIMD2(1, 1)
        case 3: SIMD2(0, 1)
        default: SIMD2(0.5, 0.5)
        }
    }

    /// Desk bounding box of a `size` mat at `angle` whose material point `anchorUV01 · size` sits at `anchor`.
    private func footprint(_ size: SIMD2<Float>, _ angle: Float, anchor: SIMD2<Float>,
                           anchorUV01: SIMD2<Float>) -> (lo: SIMD2<Float>, hi: SIMD2<Float>) {
        let c = Float(cos(Double(angle))), s = Float(sin(Double(angle)))
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for corner in [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)] {
            let q = (corner - anchorUV01) * size
            let p = anchor + SIMD2(q.x * c - q.y * s, q.x * s + q.y * c)
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        return (lo, hi)
    }

    /// The pose a transform toward `size`/`angle` ends at. A pose whose footprint leaves the desk turns only as far
    /// as fits (from the current angle, or from straight when even that does not fit the new size and the mat may
    /// move); an anchored grab that cannot fit the size at its current angle grows or shrinks only as far as fits.
    /// With `canShift` the anchor then slides so the footprint lies on the desk.
    private func transformPlan(size: SIMD2<Float>, angle: Float, anchorCorner: Int?, canShift: Bool,
                               snap: Float? = nil) -> TransformPlan {
        let fromSize: SIMD2<Float>, fromAngle: Float, anchor: SIMD2<Float>, auv: SIMD2<Float>
        if let run = transformRun {
            (fromSize, fromAngle, anchor, auv) = (run.size, run.angle, run.anchor, run.anchorUV01)
        } else {
            let frame = matFrame()
            auv = Self.anchorUV01(anchorCorner)
            (fromSize, fromAngle, anchor) = (restSize, frame.angle, frame.point(auv * restSize))
        }
        let margin: Float = 0.5
        let xr = params.xRange, dr = params.dRange
        func fits(_ s: SIMD2<Float>, _ a: Float) -> Bool {
            let (lo, hi) = footprint(s, a, anchor: anchor, anchorUV01: auv)
            if canShift {
                return hi.x - lo.x <= xr.upperBound - xr.lowerBound - 2 * margin
                    && hi.y - lo.y <= dr.upperBound - dr.lowerBound - 2 * margin
            }
            return lo.x >= xr.lowerBound + margin && hi.x <= xr.upperBound - margin
                && lo.y >= dr.lowerBound + margin && hi.y <= dr.upperBound - margin
        }
        let target = unwrap(angle, near: fromAngle)
        var outSize = size, outAngle = target
        if !fits(size, target) {
            let straight = unwrap(0, near: fromAngle)
            if fits(size, fromAngle) {
                outAngle = farthest(from: fromAngle, to: target) { fits(size, $0) }
            } else if canShift && fits(size, straight) {
                outAngle = farthest(from: straight, to: target) { fits(size, $0) }
            } else if fits(fromSize, fromAngle) {
                outAngle = fromAngle
                let t = farthest(from: 0, to: 1) { fits(fromSize + (size - fromSize) * $0, fromAngle) }
                outSize = fromSize
                let q = params.sizeSnap
                var grid = fromSize + (size - fromSize) * t
                for k in 0..<2 {
                    let up = size[k] > fromSize[k]
                    grid[k] = ((grid[k] / q).rounded(up ? .down : .up)) * q
                    grid[k] = up ? max(grid[k], fromSize[k]) : min(grid[k], fromSize[k])
                }
                if fits(grid, fromAngle) { outSize = grid }
            } else {
                (outSize, outAngle) = (fromSize, fromAngle)
            }
            if let step = snap, outAngle != target {
                // ⇧: the nearest whole step that still fits, or no turn at all.
                let k = outAngle / step
                let snapped = (outAngle > fromAngle ? k.rounded(.down) : k.rounded(.up)) * step
                let between = (snapped - fromAngle) * (outAngle - fromAngle) >= 0
                outAngle = between && fits(outSize, snapped) ? snapped : fromAngle
            }
        }
        var to = anchor
        if canShift {
            let (lo, hi) = footprint(outSize, outAngle, anchor: anchor, anchorUV01: auv)
            to.x += max(xr.lowerBound + margin - lo.x, 0) - max(hi.x - (xr.upperBound - margin), 0)
            to.y += max(dr.lowerBound + margin - lo.y, 0) - max(hi.y - (dr.upperBound - margin), 0)
        }
        return TransformPlan(size: outSize, angle: outAngle, anchorUV01: auv, from: anchor, to: to)
    }

    /// The point nearest `b` on the way from `a` (assumed to pass `ok`) before `ok` first fails.
    private func farthest(from a: Float, to b: Float, _ ok: (Float) -> Bool) -> Float {
        let steps = max(1, Int((abs(b - a) / (0.5 * .pi / 180)).rounded(.up)))
        var good = a
        for k in 1...steps {
            let x = a + (b - a) * Float(k) / Float(steps)
            if ok(x) {
                good = x
                continue
            }
            var lo = good, hi = x
            for _ in 0..<16 {
                let mid = (lo + hi) / 2
                if ok(mid) { lo = mid } else { hi = mid }
            }
            return lo
        }
        return good
    }

    private mutating func startTransform(_ plan: TransformPlan) {
        if var run = transformRun {
            if run.toSize == plan.size && run.toAngle == plan.angle && run.toAnchor == plan.to { return }
            run.fromSize = run.size
            run.fromAngle = run.angle
            run.fromAnchor = run.anchor
            run.toSize = plan.size
            run.toAngle = plan.angle
            run.toAnchor = plan.to
            run.progress = 0
            transformRun = run
            return
        }
        let frame = matFrame()
        transformRun = TransformRun(
            anchor: plan.from, anchorUV01: plan.anchorUV01, size: restSize, angle: frame.angle, fromSize: restSize,
            fromAngle: frame.angle, fromAnchor: plan.from, toSize: plan.size, toAngle: plan.angle, toAnchor: plan.to,
            progress: 0
        )
    }

    /// Advances the transform easing one frame and maps every particle (x and prev, xy only).
    private mutating func advanceTransform(dt: Float) {
        guard var run = transformRun else { return }
        run.toAngle = unwrap(run.toAngle, near: run.fromAngle)
        run.progress = min(1, run.progress + dt / max(params.transformSeconds, 1e-3))
        let t = run.progress * run.progress * (3 - 2 * run.progress)
        let size = run.fromSize + (run.toSize - run.fromSize) * t
        let angle = run.fromAngle + (run.toAngle - run.fromAngle) * t
        let anchor = run.fromAnchor + (run.toAnchor - run.fromAnchor) * t
        let c0 = Float(cos(Double(run.angle))), s0 = Float(sin(Double(run.angle)))
        let c1 = Float(cos(Double(angle))), s1 = Float(sin(Double(angle)))
        let scale = size / run.size
        let a = run.anchor
        func map(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let dx = p.x - a.x, dy = p.y - a.y
            let lu = (dx * c0 + dy * s0) * scale.x, lv = (-dx * s0 + dy * c0) * scale.y
            return SIMD3(anchor.x + lu * c1 - lv * s1, anchor.y + lu * s1 + lv * c1, p.z)
        }
        for i in parts.indices {
            parts[i].x = map(parts[i].x)
            parts[i].p = map(parts[i].p)
        }
        setRestSize(size)
        run.size = size
        run.angle = angle
        run.anchor = anchor
        // A finished run ends unless the ⌥-corner grab that drives it is still held.
        transformRun = run.progress >= 1 && grab?.mode != .transform ? nil : run
    }

    // MARK: - Scripts

    /// Smooth Mat: the face-up corners tugged `smoothPull` px outward for `smoothFrames` frames with friction
    /// × `smoothFriction`. Bumps and folds remain.
    public mutating func smooth() {
        if grab != nil { endGrab() }
        let corners = cornerIndices.filter { !isFolded($0) }
        guard !corners.isEmpty else { return }
        wake()
        let c = centroid
        let starts = corners.map { parts[$0].x }
        let outward = starts.map { p -> SIMD2<Float> in
            let o = SIMD2(p.x, p.y) - c
            let l = length2(o)
            return l > 0 ? o / l : .zero
        }
        script = .smooth(frame: 0, corners: corners.map { Int32($0) }, starts: starts, outward: outward)
    }

    /// Unfold: every displaced (flap) particle swings back to its flat place across the fold line over
    /// `unfoldSeconds`, along a half-turn arc. Does nothing when nothing is folded.
    public mutating func unfold() {
        if grab != nil { endGrab() }
        updateLayering()
        // Fit the base layer: particles still face-up.
        let up = (0..<count).filter { !isFolded($0) }
        guard up.count >= 3 else { return }
        let frame = fitFrame(up)
        var indices: [Int32] = [], from: [SIMD3<Float>] = [], to: [SIMD3<Float>] = [], arc: [Float] = []
        for i in 0..<count {
            let target = frame.point(uv[i])
            let cur = parts[i].x
            let dxy = length2(SIMD2(cur.x, cur.y) - target)
            guard dxy > 3 || isFolded(i) else { continue }
            indices.append(Int32(i))
            from.append(cur)
            to.append(SIMD3(target.x, target.y, params.thickness))
            arc.append(dxy / 2)
        }
        guard !indices.isEmpty else { return }
        wake()
        let frames = max(1, Int((params.unfoldSeconds * 60).rounded()))
        script = .path(frame: 0, frames: frames, holdFrames: 0, indices: indices, from: from, to: to, arc: arc)
    }

    /// Peek Under: lifts the edge nearest desk point `point` back over it for `peekSeconds`, then lays it down.
    /// Off in `flatMode`.
    public mutating func peekUnder(_ point: SIMD2<Float>) {
        guard !params.flatMode, point.x.isFinite, point.y.isFinite else { return }
        if grab != nil { endGrab() }
        let frame = matFrame()
        let q = frame.material(point)
        let w = restSize.x, dd = restSize.y
        let dists: [Float] = [q.x, w - q.x, q.y, dd - q.y]
        let edge = dists.indices.min { dists[$0] < dists[$1] } ?? 2
        let depthIn = max(0, dists[edge])
        let c = Float(cos(Double(frame.angle))), s = Float(sin(Double(frame.angle)))
        let inwardUV: SIMD2<Float> = [SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)][edge]
        let inward = SIMD2(inwardUV.x * c - inwardUV.y * s, inwardUV.x * s + inwardUV.y * c)
        var indices: [Int32] = [], from: [SIMD3<Float>] = [], to: [SIMD3<Float>] = []
        for i in 0..<count {
            let m = uv[i]
            let onEdge: Bool, along: Float
            switch edge {
            case 0: onEdge = m.x < 1e-3; along = m.y - q.y
            case 1: onEdge = m.x > w - 1e-3; along = m.y - q.y
            case 2: onEdge = m.y < 1e-3; along = m.x - q.x
            default: onEdge = m.y > dd - 1e-3; along = m.x - q.x
            }
            guard onEdge, abs(along) <= params.peekReach, !parts[i].weighted else { continue }
            let fall = 0.5 + 0.5 * Float(cos(Double(along / params.peekReach) * .pi))
            let cur = parts[i].x
            let reach = (depthIn + 8) * fall
            indices.append(Int32(i))
            from.append(cur)
            to.append(SIMD3(cur.x + inward.x * reach, cur.y + inward.y * reach,
                            cur.z + (params.peekHeight + depthIn * 0.4) * fall))
        }
        guard !indices.isEmpty else { return }
        wake()
        let rise = 15, total = max(rise + 1, Int((params.peekSeconds * 60).rounded()))
        script = .path(frame: 0, frames: rise, holdFrames: total - rise, indices: indices, from: from, to: to,
                       arc: Array(repeating: 0, count: indices.count))
    }

    /// Stops a running script and lets its pinned particles fall.
    public mutating func cancelScript() {
        guard script != nil else { return }
        script = nil
        releasePins()
        clearGuide()
        frictionScale = 1
    }

    /// Desk knock (E11): the cloth hops straight up and lands where it was over `knockFrames`, higher in a ripple
    /// of `knockWavelength` around desk point `point`. Weighted particles stay down; ignored during a grab or script.
    public mutating func knock(from point: SIMD2<Float>, strength: Float = 1) {
        guard grab == nil, script == nil, strength > 0, strength.isFinite, point.x.isFinite, point.y.isFinite else {
            return
        }
        let k = 2 * Float.pi / max(params.knockWavelength, 1), height = params.knockHeight * min(strength, 3)
        var indices: [Int32] = [], at: [SIMD3<Float>] = [], arc: [Float] = []
        for i in parts.indices where !parts[i].weighted {
            let r = length2(SIMD2(parts[i].x.x, parts[i].x.y) - point)
            indices.append(Int32(i))
            at.append(parts[i].x)
            arc.append(height * (0.6 + 0.4 * Float(cos(Double(r * k)))))
        }
        guard !indices.isEmpty else { return }
        wake()
        script = .path(frame: 0, frames: max(2, params.knockFrames), holdFrames: 0, indices: indices, from: at, to: at,
                       arc: arc)
    }

    // MARK: - Keyboard weight

    /// Weighs the particles currently under `footprint` (desk plane) to the floor every substep; they grip the desk
    /// harder (`keyboardPressure`) and cannot be peeled. nil lifts the keyboard.
    public mutating func setKeyboard(_ footprint: DeskPlaneRect?) {
        for i in parts.indices { parts[i].weighted = false }
        keyboardOffset = nil
        guard let footprint else { return }
        var sum = SIMD2<Float>.zero, n = 0
        for i in parts.indices where footprint.contains(SIMD2(parts[i].x.x, parts[i].x.y)) {
            parts[i].weighted = true
            sum += SIMD2(parts[i].x.x, parts[i].x.y)
            n += 1
        }
        guard n > 0 else { return }
        keyboardOffset = footprint.center - sum / Float(n)
        wake()
    }

    /// Keyboard centre (desk xy): the mean of the weighed particles plus the placement offset.
    public var keyboardCenter: SIMD2<Float>? {
        guard let keyboardOffset else { return nil }
        var sum = SIMD2<Float>.zero, n = 0
        for p in parts where p.weighted {
            sum += SIMD2(p.x.x, p.x.y)
            n += 1
        }
        return n > 0 ? sum / Float(n) + keyboardOffset : nil
    }

    // MARK: - Frame drive

    /// Drops this frame's fold guide (keeping its storage).
    mutating func clearGuide() {
        for index in guideIndices {
            parts[Int(index)].guided = false
            guideSlot[Int(index)] = -1
        }
        guideIndices.removeAll(keepingCapacity: true)
        guideTargets.removeAll(keepingCapacity: true)
    }

    /// The guide target of particle `index`, if this frame's fold guides it.
    func guideTarget(_ index: Int32) -> SIMD3<Float>? {
        let slot = guideSlot[Int(index)]
        return slot >= 0 ? guideTargets[Int(slot)] : nil
    }

    /// Builds this frame's guide targets (relative z) for a paper fold. False, with no guide, when the fold is
    /// degenerate: it moves nothing or the whole mat, or the flap holds keyboard-weighted particles.
    mutating func applyGuide(_ spec: FoldSpec) -> Bool {
        clearGuide()
        let c = Float(cos(Double(spec.frame.angle))), s = Float(sin(Double(spec.frame.angle)))
        let o = spec.frame.origin
        let n = spec.normal, tangent = SIMD2(-n.y, n.x), line = spec.line
        let cosPhi = Float(cos(Double(spec.angle))), sinPhi = Float(sin(Double(spec.angle)))
        let base = params.thickness, rise = params.foldedThickness - params.thickness
        let fade = min(max(spec.angle / .pi, 0), 1)
        let spread2 = 2 * spec.spread * spec.spread
        var ok = true
        let lift = rise * (1 - cosPhi) / 2, focusDepth = dot2(spec.focus, n)
        func add(_ i: Int, _ fp: SIMD2<Float>, _ line: Float, _ offset: SIMD3<Float>) {
            let r = line - dot2(fp, n), foot = fp + n * r, xy = foot - n * (r * cosPhi)
            var t = SIMD3(xy.x, xy.y, base + r * sinPhi + lift) + offset
            t.z = max(t.z, base)
            guideIndices.append(Int32(i))
            guideTargets.append(t)
        }
        if spec.members.isEmpty {
            for i in 0..<count {
                let q = uv[i], fp = SIMD2(o.x + q.x * c - q.y * s, o.y + q.x * s + q.y * c)
                var local = line
                if spread2.isFinite {
                    let a = dot2(fp - spec.focus, tangent)
                    local = focusDepth + (line - focusDepth) * Float(exp(Double(-a * a / spread2)))
                }
                guard dot2(fp, n) < local else { continue }
                if parts[i].weighted {
                    ok = false
                    break
                }
                add(i, fp, local, .zero)
            }
            if guideIndices.count == count { ok = false }
        } else {
            for (k, index) in spec.members.enumerated() {
                let i = Int(index), q = uv[i]
                if parts[i].weighted {
                    ok = false
                    break
                }
                add(i, SIMD2(o.x + q.x * c - q.y * s, o.y + q.x * s + q.y * c), line, spec.residual[k] * fade)
            }
        }
        guard ok, !guideIndices.isEmpty else {
            clearGuide()
            return false
        }
        for (k, index) in guideIndices.enumerated() {
            parts[Int(index)].guided = true
            guideSlot[Int(index)] = Int32(k)
        }
        return true
    }

    mutating func releasePins() {
        for pin in pins { parts[Int(pin.index)].w = 1 }
        pins.removeAll(keepingCapacity: true)
    }

    /// Turns the grab/script state into this frame's pins, carry and fold guide.
    mutating func prepareFrame(dt: Float, bumps: BumpField?) {
        releasePins()
        carry = nil
        clearGuide()
        frictionScale = 1
        advanceTransform(dt: dt)
        if let s = script { runScript(s) }
        guard var g = grab else { return }
        let proj = params.projection
        switch g.mode {
        case .pending, .transform:
            break
        case .slide:
            let delta = g.cursor - g.appliedCursor
            slide(by: SIMD2(delta.x, -delta.y / proj.k))
        case .carry:
            // The drag moves the grab-start pose; it stops at the desk bounds instead of crumpling into them.
            let move = g.cursor - g.startCursor
            var delta = SIMD2(move.x, -move.y / proj.k)
            delta.x = min(max(delta.x, min(params.xRange.lowerBound - g.carryLo.x, 0)),
                          max(params.xRange.upperBound - g.carryHi.x, 0))
            delta.y = min(max(delta.y, min(params.dRange.lowerBound - g.carryLo.y, 0)),
                          max(params.dRange.upperBound - g.carryHi.y, 0))
            let target = SIMD2(g.hitStart.x, g.hitStart.y) + delta
            if let last = g.lastCarryTarget, length2(target - last) < 0.05 {
                g.carryActivity *= Float(exp(Double(-dt / max(params.carryStillFade, 1e-3))))
            } else {
                g.carryActivity = 1
            }
            // The grabbed patch rises only as the drag starts, so a click never tents the mat.
            let lift = params.flatMode ? 0 : params.carryLift * min(1, g.maxTravel / max(params.decideDistance, 1e-3))
            carry = CarryRuntime(
                hit: Int32(g.hit), lift: lift, rest: g.carryRest, restCentroid: g.carryCentroid, patch: g.carryPatch,
                gain: g.carryGain, activity: g.carryActivity, targetFrom: g.lastCarryTarget ?? target, targetTo: target
            )
            g.lastCarryTarget = target
        case .unpeel:
            // Progress along the tip's folded → flat screen axis opens the fold: θ = acos(2s − 1), π → 0.
            guard let plan = g.unpeel else { break }
            let axis = plan.to - plan.from, l2 = dot2(axis, axis)
            let s = l2 > 1e-6 ? min(max(dot2(g.cursor - g.startCursor, axis) / l2, 0), 1) : 0
            var spec = plan.spec
            spec.angle = Float(acos(Double(2 * s - 1)))
            if applyGuide(spec) {
                g.lastFold = spec
                let hit = Int32(g.hit)
                if let to = guideTarget(hit) { addPin(hit, from: parts[g.hit].x, to: to) }
            }
        case .peel, .tug:
            // Peel: rising cursor motion is spent lifting the held point straight up (it stays under the cursor,
            // never lurching toward the viewer) until `peelHeight`; sideways motion also lifts it, half as fast,
            // showing just above the cursor. Tug keeps it on the desk.
            let peel = g.mode == .peel
            let m = g.cursor - g.startCursor, z0 = g.hitStart.z
            let room = max(0, params.peelHeight - z0)
            let rise = peel ? min(max(0, -m.y), room) : 0
            let side = peel ? min(0.5 * abs(m.x), room - rise) : 0
            var target = SIMD3(g.hitStart.x + m.x, g.hitStart.y - (m.y + rise) / proj.k, z0 + rise + side)
            target.x = min(max(target.x, params.xRange.lowerBound), params.xRange.upperBound)
            target.y = min(max(target.y, params.dRange.lowerBound), params.dRange.upperBound)
            target.z = peel ? target.z - (bumps?.height(x: target.x, d: target.y) ?? 0) : params.tugHeight
            let previous = g.lastTarget ?? target
            // Far enough over, a peel becomes a guided paper fold: the flap turns about the fold line as a sheet.
            var guided = false
            g.lastFold = nil
            var band: Float?
            if case .edge = g.region { band = params.peelEdgeHalfWidth }
            if peel, let frame = g.foldFrame,
               let spec = FoldSpec(frame: frame, grabUV: uv[g.hit], target: SIMD2(target.x, target.y),
                                   height: target.z - params.thickness, axis: g.foldAxis,
                                   halfAngle: params.foldConeDegrees * .pi / 180,
                                   minDistance: params.foldMinDistance, band: band),
               applyGuide(spec) {
                g.lastFold = spec
                guided = true
            }
            for (index, offset) in g.pinOffsets {
                let o = SIMD3(offset.x, offset.y, 0)
                if guided, let to = guideTarget(index) {
                    addPin(index, from: parts[Int(index)].x, to: to)
                } else {
                    addPin(index, from: previous + o, to: target + o)
                }
            }
            g.lastTarget = target
        }
        g.appliedCursor = g.cursor
        grab = g
    }

    private mutating func addPin(_ index: Int32, from: SIMD3<Float>, to: SIMD3<Float>) {
        let i = Int(index)
        func clamp(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(min(max(p.x, params.xRange.lowerBound), params.xRange.upperBound),
                  min(max(p.y, params.dRange.lowerBound), params.dRange.upperBound),
                  min(max(p.z, 0), params.zMax))
        }
        parts[i].w = 0
        pins.append(ClothPin(index: index, from: clamp(from), to: clamp(to)))
    }

    private mutating func runScript(_ s: ScriptState) {
        switch s {
        case .layFold(let frame, let frames, let spec, let toAngle, let held):
            guard frame < frames else {
                script = nil
                return
            }
            let t = Float(frame + 1) / Float(frames)
            var now = spec
            now.angle += (toAngle - spec.angle) * t * t * (3 - 2 * t)
            guard applyGuide(now) else {
                script = nil
                return
            }
            for index in held {
                if let to = guideTarget(index) { addPin(index, from: parts[Int(index)].x, to: to) }
            }
            script = .layFold(frame: frame + 1, frames: frames, spec: spec, toAngle: toAngle, pins: held)
        case .smooth(let frame, let corners, let starts, let outward):
            let total = params.smoothFrames
            guard frame < total else {
                script = nil
                return
            }
            func at(_ f: Int, _ k: Int) -> SIMD3<Float> {
                let ramp = min(1, Float(f) / 5) * params.smoothPull
                let p = starts[k], o = outward[k] * ramp
                return SIMD3(p.x + o.x, p.y + o.y, params.tugHeight)
            }
            for k in corners.indices { addPin(corners[k], from: at(frame, k), to: at(frame + 1, k)) }
            frictionScale = params.smoothFriction
            script = .smooth(frame: frame + 1, corners: corners, starts: starts, outward: outward)
        case .path(let frame, let frames, let hold, let indices, let from, let to, let arc):
            guard frame < frames + hold else {
                script = nil
                return
            }
            func at(_ f: Int, _ k: Int) -> SIMD3<Float> {
                let t = Float(min(f, frames)) / Float(frames)
                let e = (1 - Float(cos(Double(t) * .pi))) / 2
                var p = from[k] + (to[k] - from[k]) * e
                p.z += arc[k] * Float(sin(Double(t) * .pi))
                return p
            }
            for k in indices.indices { addPin(indices[k], from: at(frame, k), to: at(frame + 1, k)) }
            script = .path(frame: frame + 1, frames: frames, holdFrames: hold, indices: indices, from: from, to: to,
                           arc: arc)
        }
    }

    /// Rigid translation of x and prev together (no injected velocity), limited to the desk bounds.
    private mutating func slide(by delta: SIMD2<Float>) {
        guard delta != .zero else { return }
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for p in parts {
            lo = pointwiseMin(lo, SIMD2(p.x.x, p.x.y))
            hi = pointwiseMax(hi, SIMD2(p.x.x, p.x.y))
        }
        let dx = min(max(delta.x, params.xRange.lowerBound - lo.x), params.xRange.upperBound - hi.x)
        let dy = min(max(delta.y, params.dRange.lowerBound - lo.y), params.dRange.upperBound - hi.y)
        let d = SIMD3(dx, dy, 0)
        for i in parts.indices {
            parts[i].x += d
            parts[i].p += d
        }
    }

    /// Best-fit rigid frame (uv → desk xy) over a subset of particles.
    func fitFrame<S: Collection<Int>>(_ subset: S) -> ClothFrame {
        let n = Float(subset.count)
        var c = SIMD2<Float>.zero, cu = SIMD2<Float>.zero
        for i in subset {
            c += SIMD2(parts[i].x.x, parts[i].x.y)
            cu += uv[i]
        }
        c /= n
        cu /= n
        var sCross: Float = 0, sDot: Float = 0
        for i in subset {
            let q = uv[i] - cu, r = SIMD2(parts[i].x.x, parts[i].x.y) - c
            sCross += q.x * r.y - q.y * r.x
            sDot += q.x * r.x + q.y * r.y
        }
        let angle = Float(atan2(Double(sCross), Double(sDot)))
        let cs = Float(cos(Double(angle))), sn = Float(sin(Double(angle)))
        return ClothFrame(origin: c - SIMD2(cu.x * cs - cu.y * sn, cu.x * sn + cu.y * cs), angle: angle)
    }
}

@inline(__always)
func length2(_ a: SIMD2<Float>) -> Float { (a.x * a.x + a.y * a.y).squareRoot() }

@inline(__always)
func dot2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.x + a.y * b.y }

/// Wraps to (−π, π].
func wrapAngle(_ a: Float) -> Float {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x <= -.pi { x += 2 * .pi }
    return x
}

/// `a` shifted by whole turns to lie within π of `ref`.
func unwrap(_ a: Float, near ref: Float) -> Float {
    ref + wrapAngle(a - ref)
}

import Foundation

/// How a mat grab drives the cloth (DESIGN §2.2 E9, grab modes).
public enum ClothGrabMode: String, Sendable, Hashable, CaseIterable {
    /// Waiting for the first `decideDistance` px of motion to pick peel, tug or carry.
    case pending
    case carry, slide, peel, tug, transform
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

/// A frame-by-frame eased resize/rotation about a fixed desk point.
struct TransformRun {
    var anchor: SIMD2<Float>
    var size: SIMD2<Float>
    var angle: Float
    var fromSize: SIMD2<Float>
    var fromAngle: Float
    var toSize: SIMD2<Float>
    var toAngle: Float
    var progress: Float
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
    var pinOffsets: [(index: Int32, offset: SIMD2<Float>)] = []
    var lastTarget: SIMD3<Float>?
    /// Flat frame of the mat when a peel started, the fold direction's axis, and the last fold it guided.
    var foldFrame: ClothFrame?
    var foldAxis = SIMD2<Float>(0, 1)
    var lastFold: FoldSpec?
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

    /// The fold that carries the grab point, flat at `frame.point(grabUV)`, toward `target` (xy) at `height` above
    /// the base layer: its line is equidistant from both, so the flap keeps its shape. Cloth folds locally, so the
    /// fold direction stays within `halfAngle` of `axis` (a corner's inward bisector or an edge's inward normal) and
    /// the reach along it is the drag projected onto that direction. Nil below `minDistance`.
    init?(frame: ClothFrame, grabUV: SIMD2<Float>, target: SIMD2<Float>, height: Float, axis: SIMD2<Float>,
          halfAngle: Float, minDistance: Float) {
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
        self.frame = frame
        normal = n
        line = dot2(p0, n) + reach
        angle = Float(atan2(Double(h), Double(-(dist * dist - h * h) / (2 * dist))))
    }
}

/// Per-frame guide targets (relative z) for the flap particles of a fold.
struct FoldGuide {
    var indices: [Int32]
    var targets: [SIMD3<Float>]

    func target(of index: Int32) -> SIMD3<Float>? {
        indices.firstIndex(of: index).map { targets[$0] }
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
    public func matFrame() -> ClothFrame {
        let n = Float(count)
        var c = SIMD2<Float>.zero, cu = SIMD2<Float>.zero
        for i in 0..<count {
            c += SIMD2(parts[i].x.x, parts[i].x.y)
            cu += uv[i]
        }
        c /= n
        cu /= n
        var sCross: Float = 0, sDot: Float = 0
        for i in 0..<count {
            let q = uv[i] - cu, r = SIMD2(parts[i].x.x, parts[i].x.y) - c
            sCross += q.x * r.y - q.y * r.x
            sDot += q.x * r.x + q.y * r.y
        }
        let angle = Float(atan2(Double(sCross), Double(sDot)))
        let cs = Float(cos(Double(angle))), sn = Float(sin(Double(angle)))
        let origin = c - SIMD2(cu.x * cs - cu.y * sn, cu.x * sn + cu.y * cs)
        return ClothFrame(origin: origin, angle: angle)
    }

    /// Mean xy of all particles.
    public var centroid: SIMD2<Float> {
        var c = SIMD2<Float>.zero
        for p in parts { c += SIMD2(p.x.x, p.x.y) }
        return c / Float(count)
    }

    // MARK: - Grabs

    /// Starts a grab on particle `particle` (from the raster's `owner[]`) with the cursor at core art point `cursor`.
    /// ⌥ picks slide (interior) or transform (corner) at once; interior grabs carry at once; edges and corners wait
    /// for `decideDistance` px of motion. Cancels a running script.
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
        g.modifiers = modifiers.union(g.modifiers.intersection(.option))
        grab = g
        if g.mode == .pending { decideMode() }
        if grab?.mode == .transform { updateTransformTarget() }
    }

    /// Ends the grab. Carry keeps `releaseKeep` of the velocity; a tug's corner falls where it is. A guided peel is
    /// finished over `layDownFrames`: a deliberate fold (turned past `foldKeepDegrees`, dragged at least
    /// `foldKeepDistance` and held over the mat) is laid down folded and stays folded; a peek lays back flat.
    public mutating func endGrab() {
        guard let g = grab else { return }
        wake()
        var lay: (FoldSpec, Float)?
        switch g.mode {
        case .carry:
            for i in parts.indices { parts[i].v *= params.releaseKeep }
        case .peel:
            for pin in pins { parts[Int(pin.index)].v = .zero }
            if let fold = g.lastFold, let target = g.lastTarget {
                let q = fold.frame.material(SIMD2(target.x, target.y))
                let overMat = q.x > 0 && q.y > 0 && q.x < restSize.x && q.y < restSize.y
                let moved = length2(SIMD2(target.x, target.y) - fold.frame.point(uv[g.hit]))
                let keep = overMat && moved >= params.foldKeepDistance
                    && fold.angle > params.foldKeepDegrees * .pi / 180
                lay = (fold, keep ? .pi : 0)
            }
        case .tug:
            for pin in pins { parts[Int(pin.index)].v = .zero }
        default:
            break
        }
        let held = g.pinOffsets.map(\.index)
        releasePins()
        carry = nil
        setGuide(nil)
        grab = nil
        if let (spec, to) = lay {
            script = .layFold(frame: 0, frames: params.layDownFrames, spec: spec, toAngle: to, pins: held)
        }
    }

    private mutating func decideMode() {
        guard var g = grab else { return }
        let m = g.cursor - g.startCursor
        guard (m.x * m.x + m.y * m.y).squareRoot() >= params.decideDistance else { return }
        let motion = SIMD2(m.x, -m.y / params.projection.k)
        let hitXY = SIMD2(parts[g.hit].x.x, parts[g.hit].x.y)
        let canPeel = !parts[g.hit].weighted
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
        if g.modifiers.contains(.shift) {
            let step = params.angleSnapDegrees * .pi / 180
            angle = (angle / step).rounded() * step
        }
        let size = SIMD2(
            snapSize(t.startSize.x * scale, params.widthRange), snapSize(t.startSize.y * scale, params.depthRange)
        )
        startTransform(size: size, angle: wrapAngle(angle), anchorCorner: t.anchorCorner)
    }

    private func snapSize(_ v: Float, _ range: ClosedRange<Float>) -> Float {
        let q = params.sizeSnap
        var s = (min(max(v, range.lowerBound), range.upperBound) / q).rounded() * q
        if s > range.upperBound { s -= q }
        if s < range.lowerBound { s += q }
        return s
    }

    /// Eases the mat to `size` and `angle` over `transformSeconds`, keeping the material point at
    /// `anchorCorner` (an index into `cornerIndices`) fixed on the desk; nil anchors the mat's centre.
    /// Rest lengths and uv rescale with it, so the pattern never stretches.
    public mutating func transform(size: SIMD2<Float>, angle: Float, anchorCorner: Int? = nil) {
        wake()
        let s = SIMD2(min(max(size.x, params.widthRange.lowerBound), params.widthRange.upperBound),
                      min(max(size.y, params.depthRange.lowerBound), params.depthRange.upperBound))
        startTransform(size: s, angle: wrapAngle(angle), anchorCorner: anchorCorner)
    }

    private mutating func startTransform(size: SIMD2<Float>, angle: Float, anchorCorner: Int?) {
        if var run = transformRun {
            if run.toSize == size && run.toAngle == angle { return }
            run.fromSize = run.size
            run.fromAngle = run.angle
            run.toSize = size
            run.toAngle = angle
            run.progress = 0
            transformRun = run
            return
        }
        let frame = matFrame()
        let anchorUV01: SIMD2<Float>
        switch anchorCorner {
        case 0: anchorUV01 = SIMD2(0, 0)
        case 1: anchorUV01 = SIMD2(1, 0)
        case 2: anchorUV01 = SIMD2(1, 1)
        case 3: anchorUV01 = SIMD2(0, 1)
        default: anchorUV01 = SIMD2(0.5, 0.5)
        }
        let anchor = frame.point(anchorUV01 * restSize)
        transformRun = TransformRun(
            anchor: anchor, size: restSize, angle: frame.angle, fromSize: restSize,
            fromAngle: frame.angle, toSize: size, toAngle: unwrap(angle, near: frame.angle), progress: 0
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
        let c0 = Float(cos(Double(run.angle))), s0 = Float(sin(Double(run.angle)))
        let c1 = Float(cos(Double(angle))), s1 = Float(sin(Double(angle)))
        let scale = size / run.size
        let a = run.anchor
        func map(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let dx = p.x - a.x, dy = p.y - a.y
            let lu = (dx * c0 + dy * s0) * scale.x, lv = (-dx * s0 + dy * c0) * scale.y
            return SIMD3(a.x + lu * c1 - lv * s1, a.y + lu * s1 + lv * c1, p.z)
        }
        for i in parts.indices {
            parts[i].x = map(parts[i].x)
            parts[i].p = map(parts[i].p)
        }
        setRestSize(size)
        run.size = size
        run.angle = angle
        // A finished run ends unless the ⌥-corner grab that drives it is still held.
        transformRun = run.progress >= 1 && grab?.mode != .transform ? nil : run
    }

    // MARK: - Scripts

    /// Smooth Mat: all four corners tugged `smoothPull` px outward for `smoothFrames` frames with friction
    /// × `smoothFriction`. Bumps remain.
    public mutating func smooth() {
        if grab != nil { endGrab() }
        wake()
        let c = centroid
        let corners = cornerIndices.map { Int32($0) }
        let starts = cornerIndices.map { parts[$0].x }
        let outward = starts.map { p -> SIMD2<Float> in
            let o = SIMD2(p.x, p.y) - c
            let l = length2(o)
            return l > 0 ? o / l : .zero
        }
        script = .smooth(frame: 0, corners: corners, starts: starts, outward: outward)
    }

    /// Unfold: every displaced (flap) particle swings back to its flat place across the fold line over
    /// `unfoldSeconds`, along a half-turn arc. Does nothing when nothing is folded.
    public mutating func unfold() {
        if grab != nil { endGrab() }
        updateLayering()
        // Fit the base layer: particles still face-up.
        let up = (0..<count).filter { parts[$0].floorOffset == params.thickness }
        guard up.count >= 3 else { return }
        let frame = fitFrame(up)
        var indices: [Int32] = [], from: [SIMD3<Float>] = [], to: [SIMD3<Float>] = [], arc: [Float] = []
        for i in 0..<count {
            let target = frame.point(uv[i])
            let cur = parts[i].x
            let dxy = length2(SIMD2(cur.x, cur.y) - target)
            guard dxy > 3 || parts[i].floorOffset != params.thickness else { continue }
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
    public mutating func peekUnder(_ point: SIMD2<Float>) {
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
        frictionScale = 1
    }

    // MARK: - Keyboard weight

    /// Weighs the particles currently under `footprint` (desk plane) to the floor every substep, free in xy;
    /// they cannot be peeled. nil lifts the keyboard.
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

    mutating func setGuide(_ fold: FoldGuide?) {
        if let old = guide { for i in old.indices { parts[Int(i)].guided = false } }
        guide = fold
        if let fold { for i in fold.indices { parts[Int(i)].guided = true } }
    }

    mutating func releasePins() {
        for pin in pins { parts[Int(pin.index)].w = 1 }
        pins = []
    }

    /// Turns the grab/script state into this frame's pins, carry and fold guide.
    mutating func prepareFrame(dt: Float, bumps: BumpField?) {
        releasePins()
        carry = nil
        setGuide(nil)
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
            carry = CarryRuntime(
                hit: Int32(g.hit), rest: g.carryRest, restCentroid: g.carryCentroid, patch: g.carryPatch,
                gain: g.carryGain, activity: g.carryActivity, targetFrom: g.lastCarryTarget ?? target, targetTo: target
            )
            g.lastCarryTarget = target
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
            var fold: FoldGuide?
            g.lastFold = nil
            if peel, let frame = g.foldFrame,
               let spec = FoldSpec(frame: frame, grabUV: uv[g.hit], target: SIMD2(target.x, target.y),
                                   height: target.z - params.thickness, axis: g.foldAxis,
                                   halfAngle: params.foldConeDegrees * .pi / 180,
                                   minDistance: params.foldMinDistance) {
                fold = foldGuide(spec)
                if fold != nil { g.lastFold = spec }
            }
            for (index, offset) in g.pinOffsets {
                let o = SIMD3(offset.x, offset.y, 0)
                if let to = fold?.target(of: index) {
                    addPin(index, from: parts[Int(index)].x, to: to)
                } else {
                    addPin(index, from: previous + o, to: target + o)
                }
            }
            g.lastTarget = target
            setGuide(fold)
        }
        g.appliedCursor = g.cursor
        grab = g
    }

    private mutating func addPin(_ index: Int32, from: SIMD3<Float>, to: SIMD3<Float>) {
        let i = Int(index)
        func clamp(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(min(max(p.x, params.xRange.lowerBound), params.xRange.upperBound),
                  min(max(p.y, params.dRange.lowerBound), params.dRange.upperBound),
                  min(p.z, params.zMax))
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
            guard let fold = foldGuide(now) else {
                script = nil
                return
            }
            for index in held {
                if let to = fold.target(of: index) { addPin(index, from: parts[Int(index)].x, to: to) }
            }
            setGuide(fold)
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

    /// Guide targets for a paper fold, or nil when the fold is degenerate: its line misses the mat (the whole mat
    /// would turn), or the flap holds keyboard-weighted particles.
    func foldGuide(_ spec: FoldSpec) -> FoldGuide? {
        let c = Float(cos(Double(spec.frame.angle))), s = Float(sin(Double(spec.frame.angle)))
        let o = spec.frame.origin
        func flat(_ q: SIMD2<Float>) -> SIMD2<Float> { SIMD2(o.x + q.x * c - q.y * s, o.y + q.x * s + q.y * c) }
        let n = spec.normal, line = spec.line
        let cosPhi = Float(cos(Double(spec.angle))), sinPhi = Float(sin(Double(spec.angle)))
        let lift = (params.foldedThickness - params.thickness) * (1 - cosPhi) / 2
        var indices: [Int32] = [], targets: [SIMD3<Float>] = []
        for i in 0..<count {
            let fp = flat(uv[i])
            let side = dot2(fp, n) - line
            guard side < 0 else { continue }
            if parts[i].weighted { return nil }
            let r = -side, foot = fp + n * r
            let xy = foot - n * (r * cosPhi)
            indices.append(Int32(i))
            targets.append(SIMD3(xy.x, xy.y, params.thickness + r * sinPhi + lift))
        }
        guard !indices.isEmpty, indices.count < count else { return nil }
        return FoldGuide(indices: indices, targets: targets)
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

    /// Best-fit frame over a subset of particles.
    private func fitFrame(_ subset: [Int]) -> ClothFrame {
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

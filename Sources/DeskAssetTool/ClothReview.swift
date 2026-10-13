import DeskCore
import DeskPixels
import Foundation

// `deskterior-assets cloth-review --out DIR`: renders the cloth scenarios ×4 (nearest) on a desk background, plus
// frame-sequence contact sheets for carry and peel, and prints metrics.

/// One cloth scene under construction: the mat, its floor, the piles and their coverage.
struct ClothStage {
    var cloth = ClothSim(params: ClothReview.params)
    var bumps = BumpField()
    var raster = DeskSurfaceRaster()
    var coverage = CoverageTracker()
    /// Pile id → (desk position, token count).
    var piles: [(id: Int, position: SIMD2<Float>, count: Int)] = []

    /// Screen (core) point of particle `i`.
    func screen(_ i: Int) -> SIMD2<Float> { cloth.params.projection.project(cloth.position(i)) }

    func coveragePiles() -> [CoveragePile] {
        piles.map {
            CoveragePile(id: $0.id, position: $0.position, radius: 5, top: BumpField.bumpHeight(count: $0.count))
        }
    }

    /// One frame: coverage → bumps → cloth.
    mutating func frame() {
        coverage.update(piles: coveragePiles(), cloth: cloth)
        let covered = piles.filter { coverage.isCovered($0.id) }.map {
            PileInput(id: $0.id, position: $0.position, count: $0.count)
        }
        bumps.setCoveredPiles(covered)
        bumps.advance()
        cloth.step(bumps: bumps)
    }

    mutating func frames(_ n: Int) { for _ in 0..<n { frame() } }

    /// Starts piles covered (as after a relaunch).
    mutating func coverAll() {
        for p in piles { coverage.setCovered(p.id, true) }
        bumps.setCoveredPiles(piles.map { PileInput(id: $0.id, position: $0.position, count: $0.count) },
                              animated: false)
    }

    /// Renders the desk background with the surface raster on top, cropped to `crop` (core px).
    mutating func render(crop: ArtRect = ClothReview.crop) -> PixelBuffer {
        let billboards = piles.filter { !coverage.isCovered($0.id) }.map {
            PileBillboard(id: $0.id, sprite: ClothReview.pileSprite(count: $0.count),
                          position: SIMD3($0.position.x, $0.position.y, 0))
        }
        raster.render(cloth: cloth, piles: billboards)
        var frame = ClothReview.background()
        frame.blit(raster.image, at: .zero)
        return frame.cropped(to: crop.offsetBy(-DeskSurfaceRaster.origin.x, -DeskSurfaceRaster.origin.y))
    }

    func metrics(_ label: String) -> String {
        String(format: "%@: W=%.3f area=%.0f maxZ=%.1f folded=%d asleep=%@ v=%.2f", label,
               ClothMetrics.wrinkle(cloth), ClothMetrics.area(cloth), ClothMetrics.maxZ(cloth),
               ClothMetrics.foldedCount(cloth), cloth.isAsleep ? "y" : "n", cloth.lastMaxSpeed)
    }
}

enum ClothReview {
    /// `ClothParams.standard` with overrides from `DESKTERIOR_CLOTH_TUNE` (e.g. `shear=1e-6,bend=1e-4`), for tuning.
    static let params: ClothParams = {
        var p = ClothParams.standard
        let spec = ProcessInfo.processInfo.environment["DESKTERIOR_CLOTH_TUNE"] ?? ""
        for item in spec.split(separator: ",") {
            let kv = item.split(separator: "=")
            guard kv.count == 2, let v = Float(kv[1]) else { continue }
            switch kv[0] {
            case "stretch": p.stretchCompliance = v
            case "shear": p.shearCompliance = v
            case "bend": p.bendCompliance = v
            case "muS": p.staticFriction = v
            case "muK": p.kineticFriction = v
            case "substeps": p.substeps = Int(v)
            case "carryK": p.carryStiffness = v
            case "carryLift": p.carryLift = v
            case "carryRadius": p.carryRadius = v
            case "carryFalloff": p.carryFalloff = v
            case "carryFar": p.carryFarFraction = v
            default: print("unknown tunable \(kv[0])")
            }
        }
        if !spec.isEmpty { print("tunables: \(spec)") }
        return p
    }()

    /// Region of interest in core px (the whole desk depth around the default mat).
    static let crop = ArtRect(112, 150, 304, 98)

    /// Desk background for the raster's 496×104 region: wall, desk top, apron, under-desk.
    static func background() -> PixelBuffer {
        var c = PixelCanvas(width: DeskSurfaceRaster.width, height: DeskSurfaceRaster.height,
                            artOrigin: DeskSurfaceRaster.origin)
        let o = DeskSurfaceRaster.origin
        c.fill(ArtRect(0, 0, c.width, 168 - o.y), Role.wallDayShade)
        c.fill(ArtRect(12 - o.x, 168 - o.y, 488, 64), Role.desk)
        c.hline(x: 12 - o.x, y: 168 - o.y, length: 488, Role.deskHighlight)
        c.fill(ArtRect(12 - o.x, 232 - o.y, 488, 12), Role.deskEdge)
        c.hline(x: 12 - o.x, y: 232 - o.y, length: 488, Role.deskHighlight)
        c.hline(x: 12 - o.x, y: 243 - o.y, length: 488, Role.deskShadow)
        c.fill(ArtRect(0, 244 - o.y, c.width, 4), .neutral3)
        return c.buffer
    }

    /// A stack of `count` paper icons (up to 3 drawn), 12 px wide.
    static func pileSprite(count: Int) -> PixelBuffer {
        let paper = IndexedSprite("""
            kkkkkkk...
            kwwwwwkk..
            kwwwwwkwk.
            kwlllwkkkk
            kwwwwwwwwk
            kwllllllwk
            kwwwwwwwwk
            kwllllllwk
            kwwwwwwwwk
            kwlllllwwk
            kwwwwwwwwk
            kkkkkkkkkk
            """, ["k": Role.outline, "w": .neutral9, "l": .neutral6, ".": .clear])
        let shown = min(max(count, 1), 3)
        var c = PixelCanvas(width: 10 + 2 * (shown - 1), height: 12 + 2 * (shown - 1))
        for k in 0..<shown {
            let off = 2 * (shown - 1 - k)
            c.blit(paper, at: ArtPoint(off, 2 * k))
        }
        return c.buffer
    }

    static func stage(piles: [(Int, SIMD2<Float>, Int)] = []) -> ClothStage {
        var s = ClothStage()
        s.piles = piles.map { (id: $0.0, position: $0.1, count: $0.2) }
        return s
    }

    /// A rendered scenario frame with its metrics line.
    typealias Shot = (name: String, image: PixelBuffer)

    static func run(outDir: URL) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var shots: [Shot] = []
        shots += flatAndBumps()
        let (carryShots, carrySeq) = carry()
        shots += carryShots
        let (peelShots, peelSeq) = peel()
        shots += peelShots
        let (foldShots, foldSeq) = edgeFold()
        shots += foldShots
        shots += dogEar()
        let (tugShots, tugSeq) = tug()
        shots += tugShots
        shots += transforms()

        for (name, b) in shots { try write(b, "\(name).png", in: outDir, scale: 4) }
        // DESKTERIOR_CLOTH_ZOOM="x,y,w,h" (crop px) also writes ×8 close-ups for pixel inspection.
        let zoom = (ProcessInfo.processInfo.environment["DESKTERIOR_CLOTH_ZOOM"] ?? "").split(separator: ",")
            .compactMap { Int($0) }
        if zoom.count == 4 {
            for (name, b) in shots {
                try write(b.cropped(to: ArtRect(zoom[0], zoom[1], zoom[2], zoom[3])), "zoom-\(name).png", in: outDir,
                          scale: 8)
            }
        }
        try write(sheet(carrySeq, columns: 3), "seq-carry.png", in: outDir, scale: 2)
        try write(sheet(peelSeq, columns: 3), "seq-peel.png", in: outDir, scale: 2)
        try write(sheet(foldSeq, columns: 3), "seq-fold.png", in: outDir, scale: 2)
        try write(sheet(tugSeq, columns: 3), "seq-tug.png", in: outDir, scale: 2)
    }

    static func shot(_ name: String, _ s: inout ClothStage) -> Shot {
        print(s.metrics(name))
        return (name, s.render())
    }

    /// Flat; bumps from 1, 3 and 7 tokens.
    static func flatAndBumps() -> [Shot] {
        var flat = stage()
        flat.frames(90)
        var bumps = stage(piles: [
            (0, SIMD2(190, 40), 1),
            (1, SIMD2(250, 48), 1), (2, SIMD2(257, 52), 1), (3, SIMD2(252, 57), 1),
            (4, SIMD2(318, 44), 7),
        ])
        bumps.coverAll()
        bumps.frames(120)
        return [shot("01-flat", &flat), shot("02-bumps-1-3-7", &bumps)]
    }

    /// Carry: grab left of centre, drag right and toward the viewer, hold, release; mid-drag and settled shots.
    static func carry() -> ([Shot], [PixelBuffer]) {
        var s = stage()
        s.frames(10)
        var shots: [Shot] = [], seq: [PixelBuffer] = []
        let grab = s.cloth.index(col: 10, row: 7)
        let c0 = s.screen(grab)
        s.cloth.beginGrab(particle: grab, cursor: c0)
        for f in 1...36 {
            let t = Float(min(f, 18))
            s.cloth.moveGrab(to: c0 + SIMD2(t * 4, t * 0.4))
            s.frame()
            if f % 3 == 0 { seq.append(s.render()) }
            if f == 18 { shots.append(shot("03-carry-mid-drag", &s)) }
        }
        s.cloth.endGrab()
        for f in 1...60 {
            s.frame()
            if f % 6 == 0 { seq.append(s.render()) }
        }
        shots.append(shot("04-carry-settled", &s))
        return (shots, seq)
    }

    /// Peel the front-left corner up and in over a pile, then release (it lays back).
    static func peel() -> ([Shot], [PixelBuffer]) {
        var s = stage(piles: [(0, SIMD2(166, 18), 2)])
        s.coverAll()
        s.frames(60)
        var shots = [shot("05-peel-before", &s)], seq: [PixelBuffer] = []
        let corner = s.cloth.cornerIndices[0]
        let p0 = s.screen(corner)
        s.cloth.beginGrab(particle: corner, cursor: p0)
        for f in 1...30 {
            s.cloth.moveGrab(to: p0 + SIMD2(Float(f) * 0.7, -Float(f) * 0.75))
            s.frame()
            if f % 3 == 0 { seq.append(s.render()) }
        }
        print("peel mode: \(s.cloth.grabMode.map(\.rawValue) ?? "-")")
        shots.append(shot("06-peel-corner-revealing-pile", &s))
        s.cloth.endGrab()
        for f in 1...30 {
            s.frame()
            if f % 6 == 0 { seq.append(s.render()) }
        }
        shots.append(shot("07-peel-released", &s))
        return (shots, seq)
    }

    /// Fold: lift the front edge and carry it back over the mat, release, rest 300 steps.
    static func edgeFold() -> ([Shot], [PixelBuffer]) {
        var s = stage()
        s.frames(30)
        var seq: [PixelBuffer] = []
        let edge = s.cloth.index(col: 17, row: 0)
        let e0 = s.screen(edge)
        s.cloth.beginGrab(particle: edge, cursor: e0)
        for f in 1...40 {
            s.cloth.moveGrab(to: e0 + SIMD2(0, -Float(f) * 0.75))
            s.frame()
            if f % 4 == 0 { seq.append(s.render()) }
        }
        let held = shot("08-fold-held", &s)
        s.cloth.endGrab()
        s.frames(300)
        seq.append(s.render())
        return ([held, shot("09-fold-persisted", &s)], seq)
    }

    /// Dog-ear: peel the back-right corner in over the mat, release, rest; then Unfold.
    static func dogEar() -> [Shot] {
        var s = stage()
        s.frames(10)
        let corner = s.cloth.cornerIndices[2]
        let p0 = s.screen(corner)
        s.cloth.beginGrab(particle: corner, cursor: p0)
        for f in 1...30 {
            s.cloth.moveGrab(to: p0 + SIMD2(-Float(f) * 2, Float(f) * 0.6))
            s.frame()
        }
        var shots = [shot("09b-dogear-held", &s)]
        s.cloth.endGrab()
        s.frames(120)
        shots.append(shot("09c-dogear-persisted", &s))
        s.cloth.unfold()
        s.frames(60)
        shots.append(shot("09d-unfolded", &s))
        return shots
    }

    /// Tug: a quick carry left leaves a ridge; tugging the front-right corner outward pulls it flat; then Smooth.
    static func tug() -> ([Shot], [PixelBuffer]) {
        var s = stage()
        s.frames(10)
        let grab = s.cloth.index(col: 24, row: 7)
        let g0 = s.screen(grab)
        s.cloth.beginGrab(particle: grab, cursor: g0)
        for f in 1...12 {
            s.cloth.moveGrab(to: g0 + SIMD2(-Float(f) * 6, 0))
            s.frame()
        }
        s.cloth.endGrab()
        s.frames(60)
        var shots = [shot("10-tug-before", &s)], seq: [PixelBuffer] = []
        let corner = s.cloth.cornerIndices[1]
        let p0 = s.screen(corner)
        s.cloth.beginGrab(particle: corner, cursor: p0)
        for f in 1...20 {
            s.cloth.moveGrab(to: p0 + SIMD2(Float(f) * 1.2, Float(f) * 0.2))
            s.frame()
            if f % 2 == 0 { seq.append(s.render()) }
        }
        print("tug mode: \(s.cloth.grabMode.map(\.rawValue) ?? "-")")
        s.cloth.endGrab()
        s.frames(60)
        shots.append(shot("11-tug-after", &s))
        s.cloth.smooth()
        s.frames(60)
        shots.append(shot("12-smooth-after", &s))
        return (shots, seq)
    }

    /// Rotated 30° (a smaller mat fits the desk depth) and resized with the transform.
    static func transforms() -> [Shot] {
        var rotated = stage()
        let ang: Float = .pi / 6, size = SIMD2<Float>(120, 48), centre = SIMD2<Float>(256, 52)
        let half = size / 2
        let origin = centre - SIMD2(half.x * cos(ang) - half.y * sin(ang), half.x * sin(ang) + half.y * cos(ang))
        rotated.cloth = ClothSim(origin: origin, size: size, angle: ang, params: params)
        rotated.frames(60)
        var resized = stage()
        resized.frames(10)
        resized.cloth.transform(size: SIMD2(150, 66), angle: 0)
        resized.frames(60)
        return [shot("13-rotated-30", &rotated), shot("14-resized-150x66", &resized)]
    }

    /// Frames in a grid with 2-px gutters.
    static func sheet(_ frames: [PixelBuffer], columns: Int) -> PixelBuffer {
        guard let first = frames.first else { return PixelBuffer(width: 1, height: 1) }
        let rows = (frames.count + columns - 1) / columns
        let fw = first.width + 2, fh = first.height + 2
        var out = PixelBuffer(width: columns * fw, height: rows * fh, fill: Ink.neutral1.color)
        for (k, f) in frames.enumerated() {
            out.blit(f, at: ArtPoint((k % columns) * fw + 1, (k / columns) * fh + 1), alphaTest: false)
        }
        return out
    }
}

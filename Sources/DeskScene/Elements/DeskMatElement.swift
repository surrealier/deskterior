import DeskCore
import SpriteKit

/// The desk mat (데스크매트; DESIGN §2.2 E9), the homage to Terkel Gjervig's *Desktop Cleaning* rug: a felt cloth
/// (`ClothSim`) lying on the desk top, drawn by `DeskSurfaceRaster` into one texture on the desk-surface layer, with
/// the keyboard weighing it down and riding along when it moves.
///
/// - **Covered = hidden.** Piles keep their desk positions and the mat slides over them, as a rug does. Coverage is
///   the cloth's (`CoverageTracker`: ≥ 3 of 5 footprint samples under it for 6 frames hides a pile, ≤ 1 reveals it
///   at once); a pile that appears or jumps (a drop, an undo, Clear the Desk, a relaunch) is judged at once. A
///   covered pile has no body (`PhysicsHub.isUnderMat`) and shows only as a bump in the floor the cloth drapes over
///   (`BumpField`, taller for taller stacks); hiding it squashes it flat as it goes under. A revealed pile the cloth
///   still lies over (a peel, a peek, a fold) stands in the raster as a billboard with per-pixel depth, so a lifted
///   flap hides what is behind it, and it can be picked up there (`owner[]`).
/// - **Gestures** (`DeskMatElement+Gestures`): the five grab modes (carry, ⌥ slide, peel, tug, ⌥ transform) and
///   unpeel, chosen by `ClothSim` from the grabbed particle; double-click an edge to smooth or a flap to unfold; the
///   context menu's Smooth, Unfold, Rotate, Size, Peek Under and Reset; a horizontal scroll on the desk drives the
///   scroll-broom (`BrushElement`).
/// - **Frames**: the cloth steps only while awake and sleeps when settled; the raster renders and uploads only when
///   something it shows changed. When the cloth falls asleep its pose (every particle, the keyboard) commits with
///   `matSettled`, so wrinkles and folds survive a relaunch.
/// - **`matMode=flat`** (the hidden setting, or Reduce Motion): bumps and covering stay; peel, fold, carry lift and
///   Peek Under are off.
///
/// The bare room (no model yet) has no mat: it shows only the keyboard's contact shadow placed in this slot.
final class DeskMatElement: DeskElement, Knockable {
    let id = "mat"
    let root = SKNode()
    unowned let context: SceneContext
    /// The room's placed objects this element moves or hides: "keyboard" rides on the mat; "mat" (the bare room's
    /// keyboard shadow) gives way to the raster.
    let placed: (String) -> PlacedElement?
    weak var brush: BrushElement?

    var cloth = ClothSim()
    private(set) var bumps = BumpField()
    private(set) var coverage = CoverageTracker()
    private(set) var index = ClothTriangleIndex()
    private var indexFresh = false
    private(set) var raster = DeskSurfaceRaster()
    private let surface = SKSpriteNode()
    /// A model has been applied: the mat draws and takes input.
    private(set) var isLive = false
    /// Tests of the bare desk top put the mat away before a model arrives: it never lays, draws or covers.
    var isPutAway = false
    /// The model's mat as last adopted or committed.
    private var knownMat: MatState?
    /// The hidden `matMode=flat` setting (Reduce Motion also flattens it).
    var flatSetting = false {
        didSet { if flatSetting != oldValue { updateFlat() } }
    }
    var rasterDirty = true
    /// Coverage must be measured again (the cloth or a pile moved, the model changed).
    private var coverageDirty = true
    private var awakeSteps = 0

    // MARK: Piles

    /// Small integer ids for the cloth core (coverage, bumps, raster owners), stable for the scene's life.
    private var pileNumbers: [PileID: Int] = [:]
    private var pilesByNumber: [Int: PileID] = [:]
    /// Each pile's model position when it was last judged covered or not.
    private var judged: [PileID: SIMD2<Float>] = [:]
    /// Revealed piles the cloth lies over, drawn here as billboards (not by the desk plane's `piles`).
    private(set) var billboards: [PileID: Billboard] = [:]
    /// Cards of the piles near the cloth (`card(for:keys:selected:)`).
    private var cards: [PileID: (keys: [TokenKey], selected: Bool, stack: PileArt.Stack, full: PixelBuffer)] = [:]
    /// Piles going under right now (the squash), and the frames each has shown.
    private var squashes: [Squash] = []
    /// Piles just revealed, popping up over two frames: the frame each shows next (2: full height again).
    private(set) var pops: [PileID: Int] = [:]
    /// Piles that just went under at the edge, their bump sliding in to where they rest (from, to, frames shown).
    private var slides: [PileID: (from: SIMD2<Float>, to: SIMD2<Float>, frame: Int)] = [:]
    /// Clear the Desk's stand-ins at the edge, drawn here so the cloth hides what has gone under (a card per pile),
    /// and the bumps of those sliding in under it (where, and how much has grown).
    var ghostCards: [PileID: (stack: PileArt.Stack, position: SIMD2<Float>)] = [:]
    var ghostBumps: [PileID: (position: SIMD2<Float>, scale: Float)] = [:]

    /// The pop-up frame a revealed pile shows now (0, 1), nil at full height.
    func popFrame(_ id: PileID) -> Int? { pops[id].flatMap { $0 < 2 ? $0 : nil } }

    struct Billboard {
        var keys: [TokenKey]
        var selected: Bool
        /// The cloth's edge is sliding over it (the card clipped at the edge, squashed near it).
        var entering = false
        var stack: PileArt.Stack
        /// The raster sprite (bottom centre = the pile's base) and its canvas top-left; `full` is the card before the
        /// edge clips it.
        var sprite: PixelBuffer
        var full: PixelBuffer
        var origin: ArtPoint
        var position: SIMD2<Float>
        /// The stack image's top-left on the canvas (the sprite pads it).
        var stackOrigin: ArtPoint
        /// The pop-up frame drawn (squashed), nil at full height.
        var pop: Int? = nil
    }

    struct Squash {
        let node: SKSpriteNode
        let frames: [PixelBuffer]
        let foot: ArtPoint
        var step = 0
    }

    // MARK: Keyboard

    /// The keyboard's drawn top-left (canvas), with hysteresis: the upright sprite's, before its turn's offset.
    private var keyboardDrawn: ArtPoint?
    // MARK: w6-polish
    /// The turn the keyboard follows (whole degrees, with hysteresis), the turn it is drawn at (square within
    /// `squareWithin`), and the turned art made so far.
    private var keyboardTurn: Int?
    private var keyboardShown = 0
    private var turnedKeyboards: [Int: (art: TurnedKeyboard, shadow: [ArtPoint])] = [:]
    /// Tells the keyboard element how it is drawn now (its keys answer where they are drawn).
    var onKeyboardTurn: ((TurnedKeyboard) -> Void)?
    /// The cloth and cards that stand in front of the keyboard, drawn over it (Errata 26), in a layer of its own.
    let keyboardCover = SKSpriteNode()
    private let coverLayer = SKNode()
    /// A turn the keyboard follows only once the cloth's turn has moved this far from it (degrees), so a carry's
    /// wobble never flickers it; at rest it takes its pose's own turn.
    static let turnHysteresis: Float = 0.75
    /// Turns under this (degrees) draw the keyboard square: a slope that shallow shows only as a step or two along
    /// its long edges, which reads as a break, not a turn (a carry's sway stays within it).
    static let squareWithin = 5

    /// The keyboard turned by `degrees`, with its contact shadow (offsets from the image's top-left).
    func turnedKeyboard(_ degrees: Int) -> (art: TurnedKeyboard, shadow: [ArtPoint]) {
        if let t = turnedKeyboards[degrees] { return t }
        let art = TurnedKeyboard(PropArt.keyboard().image, degrees: degrees)
        let t = (art, Self.contactShadow(art.image))
        turnedKeyboards[degrees] = t
        return t
    }

    /// Offsets (from an image's top-left) of its contact shadow on the felt: a row under it and a column on its right.
    static func contactShadow(_ image: PixelBuffer) -> [ArtPoint] {
        var out: [ArtPoint] = []
        for y in 0...image.height {
            for x in 0...image.width {
                let lit = x - 1 >= 0 && y - 1 >= 0 && x - 1 < image.width && y - 1 < image.height
                    && image.pixel(x - 1, y - 1).a != 0
                let own = x < image.width && y < image.height && image.pixel(x, y).a != 0
                if lit && !own { out.append(ArtPoint(x, y)) }
            }
        }
        return out
    }

    // MARK: Runs

    /// Clear the Desk's brush pass, while it plays.
    var clearRun: ClearDeskRun?
    /// Show on Desk's token in a desk pile: it waits (up to `pulseMaxWait` s) for the token to come on show, selects
    /// it, then its pile blinks for `pulseSeconds`.
    private(set) var pulse: (key: TokenKey, age: Double, waited: Double, selected: Bool)?
    /// Piles Show on Desk shows over flat cloth (`matMode=flat` or Reduce Motion: no peek), and the seconds left.
    private(set) var forcedReveals: [PileID: Double] = [:]
    /// The grab in hand (`MatGrab`), if any.
    weak var grabbing: MatGrab?
    /// The last canvas point hit-tested on the mat (a right-click's menu: Peek Under lifts the edge nearest it).
    var lastHitPoint: SIMD2<Float>?
    /// ⌥ is down on the mat: the transform handles show.
    var showsHandles = false {
        didSet { if showsHandles != oldValue { drawHandles() } }
    }
    let handles = SKSpriteNode()

    /// The footprint radius coverage samples a pile with (DESIGN §2.2 E9).
    static let pileRadius: Float = 6
    /// Within this far (plane px) of the cloth's edge a pile's card squashes down as the edge slides over it.
    static let enterReach: Float = 8
    /// How far a card's columns reach either side of its pile (px), for the cheap test before clipping one.
    static let cardReach: Float = 14
    /// Frames a bump takes to slide in from the edge to where its pile rests.
    static let slideFrames = 10
    /// How far the hem rides up over a pile going under (px).
    static let hemLift: Float = 3
    /// How far in front of the mat's front edge (plane px) a landing still tucks under: a stack's base sits 8 screen
    /// px (16 plane px) below the pointer that set it down.
    static let landingReach: Float = 18
    /// The surface draws just above the desk top and below what stands on it (flight shadows, piles, props).
    static let surfaceZ = CGFloat(RoomLayer.deskSurface.rawValue * 1000 + 300)
    /// An awake cloth with nothing driving it accepts its pose after this many steps (4 s): a settled mat whose last
    /// creases still creep never keeps the loop awake.
    static let maxIdleAwakeSteps = 240

    init(context: SceneContext, placed: @escaping (String) -> PlacedElement?) {
        self.context = context
        self.placed = placed
        surface.zPosition = Self.surfaceZ
        surface.isHidden = true
        root.addChild(surface)
        handles.zPosition = CGFloat(RoomLayer.ui.rawValue * 1000 + 5)
        handles.isHidden = true
        root.addChild(handles)
        keyboardCover.isHidden = true
        coverLayer.addChild(keyboardCover)
        root.addChild(coverLayer)
        cloth = ClothSim(params: params)
        cloth.setKeyboard(MatState().keyboardFootprint)
        cloth.forceSleep()
    }

    var hub: PhysicsHub? { context.physics }

    /// Cloth constants for this mat: the standard ones, flat when the setting or Reduce Motion asks.
    var params: ClothParams {
        var p = ClothParams.standard
        p.flatMode = isFlat
        p.peekBeyond = Self.peekBeyond
        return p
    }

    /// Peek Under draws the edge back this far past what it peeks at, so a tucked pile's whole footprint shows.
    static let peekBeyond: Float = 16
    /// Show on Desk's pulse, how long it waits for its token to come on show, and how long its peek stays up (s).
    static let pulseSeconds = 2.0
    static let pulseMaxWait = 3.0
    static let showPeekSeconds: Float = 2.8

    var isFlat: Bool { flatSetting || context.reduceMotion }

    private func updateFlat() {
        guard cloth.params.flatMode != isFlat else { return }
        cloth.params.flatMode = isFlat
        // Flat mode keeps no folds and no lifts: a flap folded before lies back at once, a peek ends.
        guard isFlat, ClothMetrics.foldedCount(cloth) > 0 || cloth.isScriptRunning || cloth.grabMode != nil else {
            return
        }
        if ClothMetrics.foldedCount(cloth) > 0 { cloth.unfold() }
        cloth.settleNow(bumps: bumps)
        indexFresh = false
        rasterDirty = true
        coverageDirty = true
        if isLive, context.state != nil { commit() }
    }

    // MARK: Layout and state

    func layout(_ layout: SceneLayout) {
        keyboardDrawn = nil
        rasterDirty = true
        guard isLive else { return }
        placed("mat")?.root.isHidden = true
        placeSurface()
        followKeyboard(force: true)
    }

    func apply(_ s: DeskState) {
        guard !isPutAway else { return }
        if !isLive {
            isLive = true
            surface.isHidden = false
            placed("mat")?.root.isHidden = true
            placeSurface()
        }
        updateFlat()
        if let run = clearRun, !run.stillApplies(to: s) {
            run.cancel()
            endClearRun()
        }
        if s.mat != knownMat { adopt(s.mat, s) }
        // Piles the model dropped are forgotten; moved ones are judged again when asked (`coversPile`).
        for id in judged.keys where s.piles[id] == nil { judged[id] = nil }
        coverageDirty = true
        rasterDirty = true
        restampBumps()
        followKeyboard(force: false)
    }

    /// Lays the model's mat: its saved particles over the bumps of the piles they cover (`ClothSim.restore`), or a
    /// fresh flat mat from its frame, with the keyboard weighing it where it was.
    private func adopt(_ m: MatState, _ s: DeskState) {
        knownMat = m
        clearRun?.finish()
        clearRun = nil
        let piles = s.tokens.piles.compactMap { id -> PileInput? in
            s.piles[id].map { PileInput(id: number(id), position: $0, count: s.tokens.members(of: id).count) }
        }
        if m.particles != nil, let r = ClothSim.restore(state: m, piles: piles, pileRadius: Self.pileRadius,
                                                         keyboardSize: MatState.keyboardSize, params: params) {
            cloth = r.cloth
            bumps = r.bumps
            coverage = r.coverage
            if m.keyboard == nil {
                cloth.setKeyboard(MatState().keyboardFootprint)
                cloth.forceSleep()
            }
            for id in s.tokens.piles { judged[id] = s.piles[id] }
        } else {
            cloth = ClothSim.flat(m, params: params)
            cloth.setKeyboard(m.keyboardFootprint)
            cloth.forceSleep()
            bumps = BumpField()
            coverage = CoverageTracker()
            judged.removeAll()
        }
        indexFresh = false
        rasterDirty = true
        coverageDirty = true
        hub?.syncBodies()
    }

    func number(_ id: PileID) -> Int {
        if let n = pileNumbers[id] { return n }
        let n = pileNumbers.count
        pileNumbers[id] = n
        pilesByNumber[n] = id
        return n
    }

    func pile(number n: Int) -> PileID? { pilesByNumber[n] }

    // MARK: Coverage

    private func refreshIndex() {
        guard !indexFresh else { return }
        index.update(cloth)
        indexFresh = true
    }

    /// Footprint samples of a pile at `p` the cloth covers now.
    func coveredSamples(at p: SIMD2<Float>) -> Int {
        refreshIndex()
        return index.coveredSamples(CoveragePile(id: 0, position: p, radius: Self.pileRadius))
    }

    /// Whether the cloth lies over desk point `p` at all (covering or lifted).
    func clothOver(_ p: SIMD2<Float>) -> Bool {
        refreshIndex()
        return index.clearance(at: p) != nil
    }

    /// Whether the mat covers pile `id` (the desk plane asks: a covered pile has no body). A pile it has not judged at
    /// its model position yet (new, or moved by the model) is judged now.
    func coversPile(_ id: PileID) -> Bool {
        guard isLive else { return false }
        if clearRun?.holds(id) == true { return true }
        guard let p = context.state?.piles[id] else { return false }
        if judged[id] != p { judge(id, at: p) }
        return coverage.isCovered(number(id))
    }

    /// Every pile is judged afresh (the mat was laid anew).
    func resetJudgements() {
        judged.removeAll()
        indexFresh = false
        coverageDirty = true
        rasterDirty = true
    }

    private func judge(_ id: PileID, at p: SIMD2<Float>) {
        coverage.setCovered(number(id), forcedReveals[id] == nil && coveredSamples(at: p) >= 3)
        judged[id] = p
        coverageDirty = true
        rasterDirty = true
    }

    /// A landing of `count` tokens at desk point `p` on the mat tucks under it (DESIGN §2.1 DropResolver, mat
    /// footprint). It joins a covered pile whose bump reaches it (at least 10 px), which slides in as far as its taller
    /// bump needs; otherwise it rests at `tuckSpot` (deep enough inside the edges for its bump, never under the
    /// keyboard: a drop on the keyboard lands beside it). Either way the returned spot is the pile's final place, so
    /// the drop commits it in one journaled move. A set-down lands where the stack's base was, a little in front of
    /// the pointer, so a landing just off the front edge (`landingReach`) counts as on the mat. Nil off the mat, or
    /// where the cloth is lifted off the desk (it lands under the lifted cloth, which covers it as it lays back).
    func landing(at p: SIMD2<Float>, count: Int = 1) -> (pile: PileID?, at: SIMD2<Float>)? {
        guard isLive, p.isFinite, let s = context.state else { return nil }
        let frame = cloth.baseFrame(), size = cloth.restSize
        let q = frame.material(p)
        guard q.x >= -4, q.x <= size.x + 4, q.y >= -Self.landingReach, q.y <= size.y + 4 else { return nil }
        refreshIndex()
        if let c = index.clearance(at: p), c >= CoverageTracker.zMargin { return nil }
        let footprint = MatFootprint(cloth: cloth)
        let near = footprint.clampedInside(p, inset: ClearDeskPlan.tuckInset)
        var join: (id: PileID, d: Float, n: Int)?
        for id in s.tokens.piles.sorted() where coverage.isCovered(number(id)) && clearRun?.holds(id) != true {
            guard let at = s.piles[id] else { continue }
            let n = s.tokens.members(of: id).count
            let d = min(simd_length(at - p), simd_length(at - near))
            if d <= Self.joinReach(count: n), join == nil || d < join!.d { join = (id, d, n) }
        }
        if let join, let at = s.piles[join.id] {
            let spot = ClearDeskPlan.tuckSpot(near: at, count: join.n + count, mat: footprint,
                                              keyboard: keyboardFootprint) ?? at
            return (join.id, spot)
        }
        guard let spot = ClearDeskPlan.tuckSpot(near: p, count: count, mat: footprint, keyboard: keyboardFootprint)
        else { return nil }
        return (nil, spot)
    }

    /// How far from a covered pile of `n` tokens a landing joins it: its bump's reach, at least 10 px.
    static func joinReach(count n: Int) -> Float { max(10, BumpField.extent(count: n)) }

    /// The keyboard's footprint where the cloth carries it now.
    var keyboardFootprint: DeskPlaneRect {
        var m = MatState()
        m.keyboard = cloth.keyboardCenter
        return m.keyboardFootprint
    }

    /// Where a stack of `count` tokens at desk point `p` rests under the cloth as it lies now
    /// (`ClearDeskPlan.tuckSpot`), nil where it offers no such spot.
    func tuckSpot(near p: SIMD2<Float>, count: Int) -> SIMD2<Float>? {
        ClearDeskPlan.tuckSpot(near: p, count: count, mat: MatFootprint(cloth: cloth), keyboard: keyboardFootprint)
    }

    /// Every pile holding tokens on show, where it is now (its body, else the model's place) and its tokens top first.
    func pileViews() -> [(id: PileID, position: SIMD2<Float>, keys: [TokenKey])] {
        guard let s = context.state else { return [] }
        let hidden = hub?.hiddenKeys ?? []
        return s.tokens.piles.compactMap { id in
            guard let model = s.piles[id] else { return nil }
            let keys = Array(s.tokens.members(of: id).reversed()).filter { !hidden.contains($0) }
            guard !keys.isEmpty else { return nil }
            return (id, hub?.world.position(of: id) ?? model, keys)
        }
    }

    /// One frame of coverage: revealed piles the cloth now lies on go under (squash, body gone, position committed);
    /// covered piles it has left come back (a body at their place).
    private func trackCoverage() {
        guard let s = context.state else { return }
        coverageDirty = false
        var samples: [(id: Int, covered: Int)] = []
        var positions: [Int: SIMD2<Float>] = [:]
        for id in s.tokens.piles {
            guard let model = s.piles[id] else { continue }
            if clearRun?.holds(id) == true {
                samples.append((number(id), 5))
                continue
            }
            if judged[id] != model { judge(id, at: model) }
            let p = hub?.world.position(of: id) ?? model
            positions[number(id)] = p
            samples.append((number(id), forcedReveals[id] != nil ? 0 : coveredSamples(at: p)))
        }
        let changes = coverage.update(samples: samples)
        guard !changes.isEmpty else { return }
        var settled: [PileID: SIMD2<Float>] = [:]
        for change in changes {
            guard let id = pile(number: change.id), let p = positions[change.id] else { continue }
            if !change.covered, !context.reduceMotion { pops[id] = 0 }
            if change.covered {
                // It slides in as far as the bump it now makes (with covered piles beside it) needs.
                var n = s.tokens.members(of: id).count
                for other in s.tokens.piles where other != id && coverage.isCovered(number(other)) {
                    if let q = s.piles[other], simd_length(q - p) <= 10 { n += s.tokens.members(of: other).count }
                }
                let spot = tuckSpot(near: p, count: n) ?? p
                if let model = s.piles[id], model != spot, spot.isFinite { settled[id] = spot }
                judged[id] = spot
                if !context.reduceMotion {
                    // The hem rides over it and its bump slides in from the edge.
                    slides[id] = (p, spot, 0)
                    cloth.liftHem(near: p, height: Self.hemLift)
                }
                if billboards[id]?.entering == true {
                    // The edge already slid over its card: only a puff where it went.
                    if let hub { context.fx.puff(at: Self.pixel(hub.canvas(plane: p))) }
                } else {
                    goesUnder(id, at: p)
                }
            }
        }
        hub?.syncBodies()
        if !settled.isEmpty {
            hub?.bodies.didCommit(settled)
            context.dispatch(.pilesSettled(settled))
        }
        restampBumps()
        rasterDirty = true
    }

    /// The covered piles' bumps (held ones wait until they are under): a pile that just went under has its bump slide
    /// in from the edge (`slides`), a stand-in of Clear the Desk's grows its own as it goes (`ghostBumps`); while either
    /// moves, the field follows at once instead of easing.
    func restampBumps(animated: Bool? = nil) {
        guard let s = context.state else { return }
        var inputs: [PileInput] = []
        for id in s.tokens.piles {
            guard var p = s.piles[id], clearRun?.holds(id) != true, coverage.isCovered(number(id)) else { continue }
            var scale: Float = 1
            if let slide = slides[id] {
                let u = min(1, Float(slide.frame) / Float(Self.slideFrames))
                let e = u * u * (3 - 2 * u)
                p = slide.from + (slide.to - slide.from) * e
                scale = 0.35 + 0.65 * e
            }
            inputs.append(PileInput(id: number(id), position: p, count: s.tokens.members(of: id).count, scale: scale))
        }
        for (id, g) in ghostBumps where clearRun?.holds(id) == true {
            let n = max(1, s.tokens.members(of: id).count)
            inputs.append(PileInput(id: number(id), position: g.position, count: n, scale: g.scale))
        }
        bumps.setCoveredPiles(inputs.sorted { $0.id < $1.id },
                              animated: animated ?? (slides.isEmpty && ghostBumps.isEmpty))
    }

    /// One frame of the bumps sliding in.
    private func stepSlides() {
        guard !slides.isEmpty else { return }
        for (id, slide) in slides {
            slides[id] = slide.frame + 1 > Self.slideFrames ? nil : (slide.from, slide.to, slide.frame + 1)
        }
        restampBumps()
        rasterDirty = true
    }

    /// Tokens the mat covers now (top of each pile first).
    var coveredTokens: [TokenKey] {
        guard let s = context.state else { return [] }
        return s.tokens.piles.filter { coverage.isCovered(number($0)) || clearRun?.holds($0) == true }
            .flatMap { s.tokens.members(of: $0).reversed() }
    }

    /// The piles the mat covers.
    var coveredPiles: Set<PileID> {
        guard let s = context.state else { return [] }
        return Set(s.tokens.piles.filter { coverage.isCovered(number($0)) || clearRun?.holds($0) == true })
    }

    // MARK: Going under

    /// A pile tucks under: its stack squashes flat over three frames and a puff of dust rises at the edge.
    func goesUnder(_ id: PileID, at p: SIMD2<Float>, keys: [TokenKey]? = nil) {
        guard let hub, let s = context.state else { return }
        let shown = keys ?? Array(s.tokens.members(of: id).reversed())
        guard !shown.isEmpty, !context.reduceMotion else {
            if let hub = context.physics { context.fx.puff(at: Self.pixel(hub.canvas(plane: p))) }
            return
        }
        let stack = DeskPilesElement.stack(shown, lift: 0, drawsTag: false, context: context)
        let image = stack.image
        let w = image.width, h = image.height
        let frames = [ArtSize(w + 2, max(1, h - 4)), ArtSize(w + 4, max(1, h / 2)), ArtSize(w + 4, max(1, 4))].map {
            PileArt.reshaped(image, to: $0)
        }
        let node = SKSpriteNode()
        node.zPosition = DeskPilesElement.z(d: p.y)
        root.addChild(node)
        let foot = Self.pixel(hub.canvas(plane: p))
        squashes.append(Squash(node: node, frames: frames, foot: foot))
        placeSquash(squashes.count - 1)
    }

    private func placeSquash(_ i: Int) {
        let sq = squashes[i]
        let frame = sq.frames[min(sq.frames.count - 1, sq.step / 2)]
        sq.node.texture = TextureFactory.texture(frame)
        context.space.place(sq.node, at: ArtRect(sq.foot.x - frame.width / 2, sq.foot.y - frame.height,
                                                 frame.width, frame.height))
    }

    private func stepSquashes() {
        guard !squashes.isEmpty else { return }
        for i in squashes.indices.reversed() {
            squashes[i].step += 1
            if squashes[i].step >= squashes[i].frames.count * 2 {
                squashes[i].node.removeFromParent()
                context.fx.puff(at: squashes[i].foot)
                squashes.remove(at: i)
            } else {
                placeSquash(i)
            }
        }
    }

    // MARK: Frames

    var needsFrames: Bool {
        isLive && (!cloth.isAsleep || bumps.isEasing || clearRun != nil || !squashes.isEmpty || !pops.isEmpty
            || pulse != nil || !forcedReveals.isEmpty || !slides.isEmpty)
    }

    func step(_ dt: Double) {
        guard isLive, context.state != nil else { return }
        updateFlat()
        if let run = clearRun {
            run.step(dt)
            if run.isDone { endClearRun() }
        }
        stepSquashes()
        stepShowOnDesk(dt)
        stepSlides()
        if coverageDirty || !cloth.isAsleep || hub?.bodies.isMoving == true { trackCoverage() }
        bumps.advance()
        let wasAwake = !cloth.isAsleep
        cloth.step(dt: Float(dt), bumps: bumps)
        if wasAwake || !cloth.isAsleep {
            indexFresh = false
            rasterDirty = true
            coverageDirty = true
            followKeyboard(force: false)
        }
        if !cloth.isAsleep, cloth.grabMode == nil, !cloth.isScriptRunning, !cloth.isTransforming {
            awakeSteps += 1
            if awakeSteps > Self.maxIdleAwakeSteps { cloth.forceSleep() }
        } else {
            awakeSteps = 0
        }
        if wasAwake && cloth.isAsleep {
            // At rest the keyboard stands at its pose's own pixel (as a relaunch draws it), whatever the hysteresis.
            followKeyboard(force: true)
            commit()
        }
        if showsHandles { drawHandles() }
        render()
        stepPops()
    }

    /// A revealed pile pops up over two frames: squashed to a third, then two thirds, then full height (the mat's
    /// billboards and the desk's piles both draw the frame `popFrame` gives).
    private func stepPops() {
        guard !pops.isEmpty else { return }
        hub?.piles.refresh()
        for (id, k) in pops { pops[id] = k < 2 ? k + 1 : nil }
        rasterDirty = true
    }

    /// Hard sleep or teardown: the brush pass ends, and the cloth comes to rest the way it was going (a peek lays its
    /// flap back, a lay-down or a resize finishes, a grab lets go and the cloth falls; `ClothSim.settleNow`), never in
    /// the air, then commits its pose. Every pile is judged where it lies.
    func settle() {
        guard isLive else { return }
        clearRun?.finish()
        endClearRun()
        for sq in squashes { sq.node.removeFromParent() }
        squashes.removeAll()
        while bumps.isEasing { bumps.advance() }
        let moving = !cloth.isAsleep || cloth.grabMode != nil || cloth.isScriptRunning || cloth.isTransforming
        cloth.settleNow(bumps: bumps)
        let settledRevision = bumps.revision
        indexFresh = false
        forcedReveals.removeAll()
        slides.removeAll()
        ghostCards.removeAll()
        ghostBumps.removeAll()
        if pulse != nil {
            pulse = nil
            rasterDirty = true
        }
        if let s = context.state {
            for id in s.tokens.piles where clearRun?.holds(id) != true {
                if let p = s.piles[id] { judge(id, at: p) }
            }
        }
        // The bumps of what it covers now stand at once, and the cloth lies down over them.
        restampBumps(animated: false)
        let redraped = bumps.revision != settledRevision
        if redraped {
            cloth.settleNow(bumps: bumps)
            indexFresh = false
        }
        trackCoverage()
        if !pops.isEmpty {
            pops.removeAll()
            hub?.piles.refresh()
        }
        followKeyboard(force: true)
        if moving || redraped { commit() }
        render()
    }

    func knock(_ plan: DeskKnock.Plan) {
        guard isLive, plan.clothRipple, !context.reduceMotion else { return }
        cloth.knock(from: plan.origin, strength: plan.strength)
    }

    /// The cloth's pose goes into the model (`matSettled`), so it survives a relaunch.
    func commit() {
        let m = cloth.matState(pattern: "felt", mode: isFlat ? "flat" : "cloth")
        guard m != knownMat else { return }
        knownMat = m
        context.dispatch(.matSettled(m))
        clearKeyboard()
    }

    /// Covered piles the keyboard came to rest over (the mat was carried or turned under them) slide out to the
    /// nearest spot clear of it, so nothing ever lies where no peek can reach it. A 2-px allowance keeps a pile Clear
    /// the Desk or a drop set down at the clearance's edge where it is.
    private func clearKeyboard() {
        guard let s = context.state, cloth.keyboardCenter != nil else { return }
        let c = ClearDeskPlan.keyboardClearance(keyboardFootprint)
        let keep = DeskPlaneRect(x: c.x + 2, d: c.d + 2, width: c.width - 4, depth: c.depth - 4)
        var moved: [PileID: SIMD2<Float>] = [:]
        for id in s.tokens.piles.sorted() where coverage.isCovered(number(id)) && clearRun?.holds(id) != true {
            guard let p = s.piles[id], keep.contains(p),
                  let spot = tuckSpot(near: p, count: s.tokens.members(of: id).count), spot != p else { continue }
            moved[id] = spot
            judged[id] = spot
        }
        guard !moved.isEmpty else { return }
        context.dispatch(.pilesSettled(moved))
    }

    // MARK: Clear the Desk

    /// Plays Clear the Desk's brush pass and tucks (the model already holds the result).
    func playClearDesk(_ plan: ClearDeskPlan) {
        clearRun?.finish()
        endClearRun()
        let run = ClearDeskRun(plan: plan, mat: self)
        clearRun = run
        restampBumps()
        rasterDirty = true
        hub?.syncBodies()
        if context.reduceMotion { run.finish() }
    }

    private func endClearRun() {
        guard let run = clearRun, run.isDone else { return }
        clearRun = nil
        run.tearDown()
        brush?.scripted = nil
        // Held piles are judged afresh where the model put them.
        for id in run.plan.sweeps.map(\.pile) + run.plan.tucks.map(\.pile) { judged[id] = nil }
        coverageDirty = true
        restampBumps()
        hub?.syncBodies()
    }

    /// A held pile reached its place under the mat: it is judged there at once, so its bump carries on from the one
    /// its stand-in grew.
    func arrived(_ id: PileID) {
        judged[id] = nil
        if clearRun?.holds(id) != true, let p = context.state?.piles[id] { judge(id, at: p) }
        restampBumps()
        rasterDirty = true
    }

    // MARK: Show on Desk

    /// Show on Desk for a covered pile: the nearest edge peeks up for the pulse's length; flat cloth (`matMode=flat`,
    /// Reduce Motion) cannot lift, so the pile is shown over it instead for as long.
    func show(_ id: PileID) {
        guard isLive, let p = context.state?.piles[id], coversPile(id) else { return }
        if isFlat {
            forcedReveals[id] = Self.pulseSeconds + Self.pulseMaxWait
            coverage.setCovered(number(id), false)
            judged[id] = p
            coverageDirty = true
            rasterDirty = true
            restampBumps()
            hub?.syncBodies()
        } else {
            peek(at: p, seconds: Self.showPeekSeconds)
        }
    }

    /// Show on Desk's pulse for a token in a desk pile (under the mat or loose).
    func playPulse(_ key: TokenKey) {
        guard isLive, context.state?.tokens.location(of: key)?.pile != nil else { return }
        pulse = (key, 0, 0, false)
    }

    /// Whether `key` is drawn now: on a pile the cloth was lifted off (a billboard), or among the desk's loose piles.
    private func isOnShow(_ key: TokenKey) -> Bool {
        if billboards.values.contains(where: { $0.keys.contains(key) }) { return true }
        guard let s = context.state, let pile = s.tokens.location(of: key)?.pile else { return false }
        return !coversPile(pile) && !(hub?.hiddenKeys.contains(key) ?? false)
    }

    private func stepShowOnDesk(_ dt: Double) {
        if !forcedReveals.isEmpty {
            for (id, left) in forcedReveals {
                guard left - dt <= 0 || context.state?.piles[id] == nil else {
                    forcedReveals[id] = left - dt
                    continue
                }
                // Back under the flat cloth at once (no lift to lay back), with a puff.
                forcedReveals[id] = nil
                if let p = context.state?.piles[id] {
                    judge(id, at: p)
                    if coverage.isCovered(number(id)), let hub { context.fx.puff(at: Self.pixel(hub.canvas(plane: p))) }
                }
                restampBumps()
                hub?.syncBodies()
            }
            coverageDirty = true
        }
        guard var p = pulse else { return }
        if !p.selected {
            guard isOnShow(p.key) else {
                p.waited += dt
                pulse = p.waited >= Self.pulseMaxWait ? nil : p
                return
            }
            context.selection.select(p.key)
            context.screen?.refreshIfSelectionChanged()
            p.selected = true
            // The reveal lasts as long as the pulse from here.
            for id in forcedReveals.keys { forcedReveals[id] = Self.pulseSeconds }
        }
        p.age += dt
        pulse = p.age >= Self.pulseSeconds ? nil : p
        rasterDirty = true
    }

    /// Whether the pile holding `keys` shows its blink's selected frame now.
    private func blinksOn(_ keys: [TokenKey]) -> Bool {
        guard let p = pulse, p.selected, keys.contains(p.key) else { return false }
        return Int(p.age * 4) % 2 == 0
    }

    // MARK: Keyboard

    /// Moves the room's keyboard to where the cloth carries it (0.75-px hysteresis), turned as its weighed particles
    /// are (`ClothSim.keyboardAngle`, whole degrees, `turnHysteresis`), and its shadow with it.
    private func followKeyboard(force: Bool) {
        guard let centre = cloth.keyboardCenter, centre.isFinite, let kb = placed("keyboard"),
              let current = kb.placements.first(where: { $0.id == "keyboard" }) else { return }
        // Core top-left: the default sprite's, moved by the centre's travel (depth counts half on screen).
        let home = MatState.defaultKeyboard
        let exact = SIMD2(Float(CoreLayout.keyboard.x) + centre.x - home.x,
                          Float(CoreLayout.keyboard.y) + (home.y - centre.y) / 2)
        let core = context.layout.coreOrigin
        let target = ArtPoint(Int(exact.x.rounded()) + core.x, Int(exact.y.rounded()) + core.y)
        var drawn = keyboardDrawn ?? target
        if force || keyboardDrawn == nil {
            drawn = target
        } else {
            if abs(exact.x + Float(core.x) - Float(drawn.x)) > 0.75 { drawn.x = target.x }
            if abs(exact.y + Float(core.y) - Float(drawn.y)) > 0.75 { drawn.y = target.y }
        }
        keyboardDrawn = drawn
        let degrees = (cloth.keyboardAngle ?? 0) * 180 / .pi
        var turn = keyboardTurn ?? Int(degrees.rounded())
        if force || abs(degrees - Float(turn)) > Self.turnHysteresis { turn = Int(degrees.rounded()) }
        keyboardTurn = turn
        let shown = abs(turn) < Self.squareWithin ? 0 : turn
        let turned = turnedKeyboard(shown)
        if shown != keyboardShown {
            keyboardShown = shown
            onKeyboardTurn?(turned.art)
        }
        let origin = drawn + turned.art.offset
        let sprite = shown == 0 ? PropArt.keyboard() : SpriteAsset("keyboard.turned\(shown)", turned.art.image)
        guard origin != current.origin || sprite.name != current.sprite.name else { return }
        let z = kb.root.children.first { $0.name == "keyboard" }?.zPosition ?? context.placementZ("keyboard")
        kb.apply([RoomPlacement("keyboard", .deskFront, sprite, at: origin)], replacingAll: false, z: { _ in z })
        rasterDirty = true
    }

    /// The keyboard's drawn rect (canvas).
    var keyboardRect: ArtRect? {
        placed("keyboard")?.placements.first { $0.id == "keyboard" }?.rect
    }

    // MARK: Raster

    /// The texture on show (tests: it changes only when something drawn changed).
    var surfaceTexture: SKTexture? { surface.texture }

    private func placeSurface() {
        context.space.place(surface, at: ArtRect(origin: context.layout.point(DeskSurfaceRaster.origin),
                                                 size: ArtSize(DeskSurfaceRaster.width, DeskSurfaceRaster.height)))
    }

    /// Renders the cloth and the billboards of revealed piles under it, darkens the felt under the keyboard's edge,
    /// and uploads the texture, only when something drawn changed.
    func render() {
        guard isLive else { return }
        let changedBillboards = updateBillboards() || !ghostCards.isEmpty
        guard rasterDirty || changedBillboards else { return }
        rasterDirty = false
        let boards = (billboards.compactMap { id, b in
            PileBillboard(id: number(id), sprite: b.sprite, position: SIMD3(b.position.x, b.position.y, 0))
        } + ghostBoards()).sorted { $0.id < $1.id }
        raster.render(cloth: cloth, piles: boards, bumps: bumps)
        var image = raster.image
        shadeUnderKeyboard(&image)
        surface.texture = TextureFactory.dynamicTexture(image)
        coverKeyboard()
    }

    // MARK: w6-polish
    /// Draws over the keyboard what of the cloth and the revealed cards stands higher than its keys there (nearer
    /// along the view ray): the keyboard is drawn over the desk surface, so without this a tongue Peek Under turns up
    /// in front of it, or a card standing before it, would show behind it.
    private func coverKeyboard() {
        let core = context.layout.coreOrigin, image = turnedKeyboard(keyboardShown).art.image
        guard !surface.isHidden, let r = keyboardRect,
              let cover = raster.cover(image, at: ArtPoint(r.x - core.x, r.y - core.y),
                                       height: DeskSurfaceRaster.keyboardTop)
        else {
            keyboardCover.isHidden = true
            return
        }
        keyboardCover.texture = TextureFactory.dynamicTexture(cover)
        context.space.place(keyboardCover, at: r)
        keyboardCover.zPosition = context.placementZ("keyboard") + 0.75
        keyboardCover.isHidden = false
    }

    /// The keyboard's contact shadow on the felt: one ramp step darker, a row under its front and a column on its right.
    private func shadeUnderKeyboard(_ image: inout PixelBuffer) {
        guard let r = keyboardRect else { return }
        let o = context.layout.point(DeskSurfaceRaster.origin)
        let ramp = raster.pattern.topRamp.map(\.color)
        for d in turnedKeyboard(keyboardShown).shadow {
            let x = r.x + d.x - o.x, y = r.y + d.y - o.y
            guard x >= 0, y >= 0, x < image.width, y < image.height,
                  raster.owner[y * DeskSurfaceRaster.width + x] >= 0,
                  let i = ramp.firstIndex(of: image[x, y]), i > 0 else { continue }
            image[x, y] = ramp[i - 1]
        }
    }

    /// Billboards for the piles the cloth has to do with; true when they changed. A revealed pile under lifted cloth
    /// stands as its whole card; a pile the cloth's edge is sliding over (a brush push, a carried mat, Clear the Desk's
    /// stand-ins) is clipped where the cloth lies over it and squashed toward the desk near the edge, so it goes under
    /// the edge rather than over the felt (`clippedCard`).
    private func updateBillboards() -> Bool {
        guard let hub else { return false }
        var next: [PileID: Billboard] = [:]
        let selection = context.selection
        let frame = cloth.baseFrame(), size = cloth.restSize
        refreshIndex()
        var used = Set<PileID>()
        for v in pileViews() where !coverage.isCovered(number(v.id)) && clearRun?.holds(v.id) != true {
            // Revealed on the mat: under lifted cloth, in the hole a peek or a fold leaves, or shown over flat cloth.
            let inside = Self.inside(frame.material(v.position), size)
            let clearance = index.clearance(at: v.position)
            let lifted = clearance.map { $0 >= CoverageTracker.zMargin } ?? (inside > 0) || forcedReveals[v.id] != nil
            let near = inside > -(Self.enterReach + Self.cardReach)
            guard lifted || near else { continue }
            // Show on Desk's pile blinks; others show the selection.
            let pulsing = pulse.map { $0.selected && v.keys.contains($0.key) } ?? false
            let selected = pulsing ? blinksOn(v.keys) : v.keys.allSatisfy(selection.contains)
            used.insert(v.id)
            let made = card(for: v.id, keys: v.keys, selected: selected)
            // A card the edge clips or squashes is the mat's to draw; one clear of the cloth is the desk's.
            var sprite = made.full, entering = false
            if !lifted {
                sprite = clippedCard(made.full, at: v.position, frame: frame, size: size)
                entering = sprite != made.full
                guard entering else { continue }
            }
            let pop = entering ? nil : popFrame(v.id)
            if let k = pop {
                sprite = PileArt.reshaped(sprite, to: ArtSize(sprite.width, max(1, sprite.height * (k + 1) / 3)))
            }
            var board = Billboard(keys: v.keys, selected: selected, stack: made.stack, sprite: sprite, full: made.full,
                                  origin: .zero, position: v.position, stackOrigin: .zero, pop: pop)
            board.entering = entering
            next[v.id] = placedBillboard(board, at: v.position, hub: hub)
        }
        for id in cards.keys where !used.contains(id) { cards[id] = nil }
        let changed = Set(next.keys) != Set(billboards.keys)
            || next.contains { id, b in
                guard let old = billboards[id] else { return true }
                return old.origin != b.origin || old.keys != b.keys || old.selected != b.selected || old.pop != b.pop
                    || old.sprite != b.sprite
            }
        billboards = next
        if changed { hub.piles.refresh() }
        return changed
    }

    /// The card of a pile drawn here, kept while its tokens and selection stay the same.
    private func card(for id: PileID, keys: [TokenKey], selected: Bool) -> (stack: PileArt.Stack, full: PixelBuffer) {
        if let c = cards[id], c.keys == keys, c.selected == selected { return (c.stack, c.full) }
        let stack = DeskPilesElement.stack(keys, lift: 0, selected: selected, drawsTag: true, context: context)
        let full = Self.card(stack)
        cards[id] = (keys, selected, stack, full)
        return (stack, full)
    }

    /// Clear the Desk's stand-ins at the edge, as raster cards (clipped like an entering pile's).
    private func ghostBoards() -> [PileBillboard] {
        guard !ghostCards.isEmpty else { return [] }
        let frame = cloth.baseFrame(), size = cloth.restSize
        return ghostCards.sorted { $0.key < $1.key }.compactMap { id, g in
            let sprite = clippedCard(Self.card(g.stack), at: g.position, frame: frame, size: size)
            return PileBillboard(id: number(id), sprite: sprite, position: SIMD3(g.position.x, g.position.y, 0))
        }
    }

    /// A stack's card for the raster: its image padded so the base is the bottom centre.
    static func card(_ stack: PileArt.Stack) -> PixelBuffer {
        let b = stack.base
        let half = max(b.x, stack.image.width - b.x)
        var sprite = PixelBuffer(width: 2 * half, height: b.y)
        sprite.blit(stack.image, at: ArtPoint(half - b.x, 0))
        return sprite
    }

    /// How far material point `q` lies inside a mat of `size` (negative outside).
    static func inside(_ q: SIMD2<Float>, _ size: SIMD2<Float>) -> Float { min(q.x, size.x - q.x, q.y, size.y - q.y) }

    /// Whether a pile at desk point `p` is where the cloth's edge may slide over its card (within `enterReach` and a
    /// card's half-width outside the mat, or on it).
    func isAtEdge(_ p: SIMD2<Float>) -> Bool {
        Self.inside(cloth.baseFrame().material(p), cloth.restSize) > -(Self.enterReach + Self.cardReach)
    }

    /// The card `full` of a pile at desk point `p` as the cloth's edge slides over it: each column whose foot (its
    /// desk x at the pile's depth) lies under resting cloth is gone; within `enterReach` outside the mat's edge it
    /// squashes toward the desk (to 15 % at the edge), so the pile slips in under the hem. Lifted cloth hides nothing.
    func clippedCard(_ full: PixelBuffer, at p: SIMD2<Float>, frame: ClothFrame, size: SIMD2<Float>) -> PixelBuffer {
        let w = full.width, h = full.height
        let base = DeskProjection.standard.project(SIMD3(p.x, p.y, 0))
        let left = DeskProjection.snap(base.x) - w / 2
        refreshIndex()
        var out = PixelBuffer(width: w, height: h)
        for c in 0..<w {
            let foot = SIMD2(Float(left + c) + 0.5, p.y)
            if let clear = index.clearance(at: foot), clear < CoverageTracker.zMargin { continue }
            let e = Self.inside(frame.material(foot), size)
            let f = e < 0 ? min(1, max(0.15, -e / Self.enterReach)) : 1
            let rows = max(1, Int((Float(h) * f).rounded()))
            for r in 0..<rows {
                let src = h - 1 - min(h - 1, Int(Float(r) / f))
                out[c, h - 1 - r] = full[c, src]
            }
        }
        return out
    }

    /// Where the raster draws a billboard (`DeskSurfaceRaster`: its bottom centre on the projected base).
    private func placedBillboard(_ b: Billboard, at p: SIMD2<Float>, hub: PhysicsHub) -> Billboard {
        var b = b
        b.position = p
        let base = DeskProjection.standard.project(SIMD3(p.x, p.y, 0))
        let core = ArtPoint(DeskProjection.snap(base.x) - b.sprite.width / 2, DeskProjection.snap(base.y) - b.sprite.height)
        b.origin = context.layout.point(core)
        let half = b.sprite.width / 2
        b.stackOrigin = ArtPoint(b.origin.x + half - b.stack.base.x, b.origin.y)
        return b
    }

    // MARK: Geometry

    static func pixel(_ p: SIMD2<Float>) -> ArtPoint { ArtPoint(Int(p.x.rounded()), Int(p.y.rounded())) }

    /// Canvas point (continuous) → core point.
    func core(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let o = context.layout.coreOrigin
        return p - SIMD2(Float(o.x), Float(o.y))
    }

    /// The canvas point of particle `i`.
    func canvas(particle i: Int) -> SIMD2<Float> {
        let o = context.layout.coreOrigin
        return cloth.params.projection.project(cloth.position(i)) + SIMD2(Float(o.x), Float(o.y))
    }

    /// The mat's drawn bounds (canvas): the raster's written box, else the particles' projected box.
    var bounds: ArtRect {
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for i in 0..<cloth.count {
            let p = canvas(particle: i)
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        guard lo.isFinite, hi.isFinite else { return .zero }
        return ArtRect(Int(lo.x.rounded(.down)), Int(lo.y.rounded(.down)), Int((hi.x - lo.x).rounded(.up)) + 1,
                       Int((hi.y - lo.y).rounded(.up)) + 1)
    }

    /// The owner of canvas pixel `p` in the raster: −1 empty, ≥ 0 a particle, ≤ −2 a pile.
    func owner(at p: ArtPoint) -> Int32 {
        let o = context.layout.coreOrigin
        return raster.owner(atCore: ArtPoint(p.x - o.x, p.y - o.y))
    }
}

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
    /// The token count each covered pile was last tucked in for.
    private var tuckedCounts: [PileID: Int] = [:]
    /// Revealed piles the cloth lies over, drawn here as billboards (not by the desk plane's `piles`).
    private(set) var billboards: [PileID: Billboard] = [:]
    /// Piles going under right now (the squash), and the frames each has shown.
    private var squashes: [Squash] = []
    /// Piles just revealed, popping up over two frames: the frame each shows next (2: full height again).
    private(set) var pops: [PileID: Int] = [:]

    /// The pop-up frame a revealed pile shows now (0, 1), nil at full height.
    func popFrame(_ id: PileID) -> Int? { pops[id].flatMap { $0 < 2 ? $0 : nil } }

    struct Billboard {
        var keys: [TokenKey]
        var selected: Bool
        var stack: PileArt.Stack
        /// The raster sprite (bottom centre = the pile's base) and its canvas top-left.
        var sprite: PixelBuffer
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

    /// The keyboard's drawn top-left (canvas), with hysteresis.
    private var keyboardDrawn: ArtPoint?
    /// Offsets (from the keyboard's top-left) of its contact shadow on the felt.
    private static let keyboardShadow: [ArtPoint] = {
        let image = PropArt.keyboard().image
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
    }()

    // MARK: Runs

    /// Clear the Desk's brush pass, while it plays.
    var clearRun: ClearDeskRun?
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

    var isFlat: Bool { flatSetting || context.reduceMotion }

    private func updateFlat() {
        guard cloth.params.flatMode != isFlat else { return }
        cloth.params.flatMode = isFlat
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
        retuck(s)
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
        coverage.setCovered(number(id), coveredSamples(at: p) >= 3)
        judged[id] = p
        coverageDirty = true
        rasterDirty = true
    }

    /// A landing of `count` tokens at desk point `p` on the mat tucks under it (DESIGN §2.1 DropResolver, mat
    /// footprint): it rests `ClearDeskPlan.inset(count:)` inside the cloth's edge (far enough that its bump does not
    /// hold the edge up) and joins a covered pile within 10 px. A set-down lands where the stack's base was, a little in
    /// front of the pointer, so a landing just off the front edge (`landingReach`) counts as on the mat. Nil off the
    /// mat, or where the cloth is lifted off the desk (it lands under the lifted cloth, which covers it as it lays back).
    func landing(at p: SIMD2<Float>, count: Int = 1) -> (pile: PileID?, at: SIMD2<Float>)? {
        guard isLive, p.isFinite, let s = context.state else { return nil }
        let frame = cloth.baseFrame(), size = cloth.restSize, inset = ClearDeskPlan.inset(count: count)
        let q = frame.material(p)
        guard q.x >= -4, q.x <= size.x + 4, q.y >= -Self.landingReach, q.y <= size.y + 4 else { return nil }
        refreshIndex()
        if let c = index.clearance(at: p), c >= CoverageTracker.zMargin { return nil }
        let i = SIMD2(min(inset, size.x / 2), min(inset, size.y / 2))
        let spot = frame.point(SIMD2(min(max(q.x, i.x), size.x - i.x), min(max(q.y, i.y), size.y - i.y)))
        guard coveredSamples(at: spot) >= 3 else { return nil }
        var join: (id: PileID, d: Float)?
        for id in s.tokens.piles.sorted() where coverage.isCovered(number(id)) && clearRun?.holds(id) != true {
            guard let at = s.piles[id] else { continue }
            let d = simd_length(at - spot)
            if d <= 10, join == nil || d < join!.d { join = (id, d) }
        }
        return (join?.id, spot)
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
            samples.append((number(id), coveredSamples(at: p)))
        }
        let changes = coverage.update(samples: samples)
        guard !changes.isEmpty else { return }
        var settled: [PileID: SIMD2<Float>] = [:]
        for change in changes {
            guard let id = pile(number: change.id), let p = positions[change.id] else { continue }
            if !change.covered, !context.reduceMotion { pops[id] = 0 }
            if change.covered {
                let spot = tucked(p, count: s.tokens.members(of: id).count)
                tuckedCounts[id] = nil
                if let model = s.piles[id], model != spot, spot.isFinite { settled[id] = spot }
                judged[id] = spot
                goesUnder(id, at: p)
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

    /// Where a pile of `count` tokens that went under the mat comes to rest: it slides in under the edge far enough
    /// that its bump does not hold the edge up off the desk (`ClearDeskPlan.inset(count:)`), if the cloth covers it
    /// there.
    func tucked(_ p: SIMD2<Float>, count: Int = 1) -> SIMD2<Float> {
        let frame = cloth.baseFrame(), size = cloth.restSize, inset = ClearDeskPlan.inset(count: count)
        let q = frame.material(p), i = SIMD2(min(inset, size.x / 2), min(inset, size.y / 2))
        let spot = frame.point(SIMD2(min(max(q.x, i.x), size.x - i.x), min(max(q.y, i.y), size.y - i.y)))
        return spot != p && coveredSamples(at: spot) >= 3 ? spot : p
    }

    /// A covered pile whose bump grew (a drop joined it, or a neighbour now shares its bump) slides further in, so the
    /// taller bump still clears the edge.
    private func retuck(_ s: DeskState) {
        var moved: [PileID: SIMD2<Float>] = [:]
        let covered = s.tokens.piles.filter { clearRun?.holds($0) != true && coverage.isCovered(number($0)) }
        let groups = PileClusterer.groups(covered.compactMap { id in
            s.piles[id].map { PileInput(id: number(id), position: $0, count: s.tokens.members(of: id).count) }
        })
        for id in covered {
            let n = groups.first { $0.ids.contains(number(id)) }?.count ?? s.tokens.members(of: id).count
            // A pile seen for the first time (a relaunch, an undo) stays where the model has it.
            guard let old = tuckedCounts[id] else {
                tuckedCounts[id] = n
                continue
            }
            guard let p = s.piles[id], n > old, judged[id] == p else { continue }
            tuckedCounts[id] = n
            let spot = tucked(p, count: n)
            if spot != p { moved[id] = spot }
        }
        guard !moved.isEmpty else { return }
        for (id, p) in moved { judged[id] = p }
        context.dispatch(.pilesSettled(moved))
    }

    /// The covered piles' bumps (held ones wait until they are under).
    func restampBumps() {
        guard let s = context.state else { return }
        var inputs: [PileInput] = []
        for id in s.tokens.piles {
            guard let p = s.piles[id], clearRun?.holds(id) != true, coverage.isCovered(number(id)) else { continue }
            inputs.append(PileInput(id: number(id), position: p, count: s.tokens.members(of: id).count))
        }
        bumps.setCoveredPiles(inputs.sorted { $0.id < $1.id })
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
        isLive && (!cloth.isAsleep || bumps.isEasing || clearRun != nil || !squashes.isEmpty || !pops.isEmpty)
    }

    func step(_ dt: Double) {
        guard isLive, context.state != nil else { return }
        updateFlat()
        if let run = clearRun {
            run.step(dt)
            if run.isDone { endClearRun() }
        }
        stepSquashes()
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
        if wasAwake && cloth.isAsleep { commit() }
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

    /// Hard sleep or teardown: the brush pass ends, the cloth accepts its pose and commits it.
    func settle() {
        guard isLive else { return }
        clearRun?.finish()
        endClearRun()
        for sq in squashes { sq.node.removeFromParent() }
        squashes.removeAll()
        if cloth.grabMode != nil { cloth.endGrab() }
        cloth.cancelScript()
        let wasAwake = !cloth.isAsleep
        cloth.forceSleep()
        indexFresh = false
        trackCoverage()
        if !pops.isEmpty {
            pops.removeAll()
            hub?.piles.refresh()
        }
        followKeyboard(force: false)
        if wasAwake { commit() }
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

    /// A held pile reached its place under the mat: it is judged there and its bump eases in.
    func arrived(_ id: PileID) {
        judged[id] = nil
        restampBumps()
        rasterDirty = true
    }

    // MARK: Keyboard

    /// Moves the room's keyboard to where the cloth carries it (0.75-px hysteresis), and its shadow with it.
    private func followKeyboard(force: Bool) {
        guard let centre = cloth.keyboardCenter, centre.isFinite, let kb = placed("keyboard"),
              let current = kb.placements.first(where: { $0.id == "keyboard" }) else { return }
        // Core top-left: the default sprite's, moved by the centre's travel (depth counts half on screen).
        let home = MatState.defaultKeyboard
        let exact = SIMD2(Float(CoreLayout.keyboard.x) + centre.x - home.x,
                          Float(CoreLayout.keyboard.y) + (home.y - centre.y) / 2)
        let core = context.layout.coreOrigin
        let target = ArtPoint(Int(exact.x.rounded()) + core.x, Int(exact.y.rounded()) + core.y)
        var drawn = keyboardDrawn ?? current.origin
        if force || keyboardDrawn == nil {
            drawn = target
        } else {
            if abs(exact.x + Float(core.x) - Float(drawn.x)) > 0.75 { drawn.x = target.x }
            if abs(exact.y + Float(core.y) - Float(drawn.y)) > 0.75 { drawn.y = target.y }
        }
        keyboardDrawn = drawn
        guard drawn != current.origin else { return }
        let z = kb.root.children.first { $0.name == "keyboard" }?.zPosition ?? context.placementZ("keyboard")
        kb.apply([RoomPlacement("keyboard", .deskFront, current.sprite, at: drawn)], replacingAll: false, z: { _ in z })
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
        let changedBillboards = updateBillboards()
        guard rasterDirty || changedBillboards else { return }
        rasterDirty = false
        let boards = billboards.compactMap { id, b in
            PileBillboard(id: number(id), sprite: b.sprite, position: SIMD3(b.position.x, b.position.y, 0))
        }.sorted { $0.id < $1.id }
        raster.render(cloth: cloth, piles: boards, bumps: bumps)
        var image = raster.image
        shadeUnderKeyboard(&image)
        surface.texture = TextureFactory.dynamicTexture(image)
    }

    /// The keyboard's contact shadow on the felt: one ramp step darker, a row under its front and a column on its right.
    private func shadeUnderKeyboard(_ image: inout PixelBuffer) {
        guard let r = keyboardRect else { return }
        let o = context.layout.point(DeskSurfaceRaster.origin)
        let ramp = raster.pattern.topRamp.map(\.color)
        for d in Self.keyboardShadow {
            let x = r.x + d.x - o.x, y = r.y + d.y - o.y
            guard x >= 0, y >= 0, x < image.width, y < image.height,
                  raster.owner[y * DeskSurfaceRaster.width + x] >= 0,
                  let i = ramp.firstIndex(of: image[x, y]), i > 0 else { continue }
            image[x, y] = ramp[i - 1]
        }
    }

    /// Billboards for the revealed piles the cloth lies over; true when they changed.
    private func updateBillboards() -> Bool {
        guard let hub else { return false }
        var next: [PileID: Billboard] = [:]
        let selection = context.selection
        for v in pileViews() where !coverage.isCovered(number(v.id)) && clearRun?.holds(v.id) != true {
            guard clothOver(v.position) else { continue }
            let selected = v.keys.allSatisfy(selection.contains)
            let pop = popFrame(v.id)
            if var old = billboards[v.id], old.keys == v.keys, old.selected == selected, old.pop == pop {
                if old.position != v.position { old = placedBillboard(old, at: v.position, hub: hub) }
                next[v.id] = old
                continue
            }
            let stack = DeskPilesElement.stack(v.keys, lift: 0, selected: selected, drawsTag: true, context: context)
            let b = stack.base
            let half = max(b.x, stack.image.width - b.x)
            var sprite = PixelBuffer(width: 2 * half, height: b.y)
            sprite.blit(stack.image, at: ArtPoint(half - b.x, 0))
            if let k = pop {
                sprite = PileArt.reshaped(sprite, to: ArtSize(sprite.width, max(1, sprite.height * (k + 1) / 3)))
            }
            let board = Billboard(keys: v.keys, selected: selected, stack: stack, sprite: sprite, origin: .zero,
                                  position: v.position, stackOrigin: .zero, pop: pop)
            next[v.id] = placedBillboard(board, at: v.position, hub: hub)
        }
        let changed = Set(next.keys) != Set(billboards.keys)
            || next.contains { billboards[$0.key]?.origin != $0.value.origin || billboards[$0.key]?.keys != $0.value.keys
                || billboards[$0.key]?.selected != $0.value.selected || billboards[$0.key]?.pop != $0.value.pop }
        billboards = next
        if changed { hub.piles.refresh() }
        return changed
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

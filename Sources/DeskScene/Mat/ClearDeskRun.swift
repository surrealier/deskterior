import DeskCore
import SpriteKit

/// Clear the Desk as the scene plays it (DESIGN §2.2 E16). The model already holds the result (`ClearDeskPlan`
/// applied by the reducer as one undo); this only shows how it got there, on the plan's clock:
///
/// - the brush leaves its spot and pushes each loose pile to the mat's edge, where the edge slides over it (its card is
///   drawn in the mat's raster there, clipped where the cloth lies over it), the hem rides up and its bump grows in
///   from the edge, with a puff of dust;
/// - floor stacks hop up onto the mat's edge one after another and tuck under the same way;
/// - then "TIDY!" pops over the monitor's dark glass and the brush is back where it lay.
///
/// Until a pile is under, the mat holds it (`holds`): no body, no bump, no billboard; its stand-in here draws it. With
/// Reduce Motion everything arrives at once with a puff. Hard sleep finishes it (`finish`).
final class ClearDeskRun {
    let plan: ClearDeskPlan
    unowned let mat: DeskMatElement
    private(set) var t: Float = 0
    private(set) var isDone = false
    private var tidied = false
    /// Piles not under the mat yet.
    private(set) var pending: Set<PileID>
    private var ghosts: [PileID: Ghost] = [:]

    /// A pile's stand-in while it travels.
    final class Ghost {
        let node = SKSpriteNode()
        let stack: PileArt.Stack
        /// Where it was last drawn (canvas top-left).
        var shown: ArtPoint?
        /// The hem has ridden over it (once, as it reaches the edge).
        var lifted = false

        init(stack: PileArt.Stack) {
            self.stack = stack
        }
    }

    /// A floor stack's hop rises this far over the higher end (core px).
    static let hopHeight: Float = 34
    /// Flights from the floor draw above the apron and below the chair, as other tosses do.
    static let flightZ = CGFloat(RoomLayer.underDesk.rawValue * 1000 + 950)

    init(plan: ClearDeskPlan, mat: DeskMatElement) {
        self.plan = plan
        self.mat = mat
        pending = Set(plan.sweeps.map(\.pile) + plan.tucks.map(\.pile))
        let context = mat.context
        for sweep in plan.sweeps {
            guard let keys = context.state.map({ Array($0.tokens.members(of: sweep.pile).reversed()) }), !keys.isEmpty
            else { pending.remove(sweep.pile); continue }
            ghosts[sweep.pile] = Ghost(stack: DeskPilesElement.stack(keys, lift: 0, drawsTag: true, context: context))
        }
        for tuck in plan.tucks {
            let icons = tuck.keys.prefix(PileArt.maxIcons).compactMap { k in
                context.state?.tokens.meta(of: k).map { TokenArt.icon(k, $0, context) }
            }
            guard !icons.isEmpty else {
                pending.remove(tuck.pile)
                continue
            }
            ghosts[tuck.pile] = Ghost(stack: PileArt.stack(icons, count: tuck.keys.count, shadow: nil))
        }
        for g in ghosts.values { mat.root.addChild(g.node) }
        place()
    }

    func holds(_ id: PileID) -> Bool { pending.contains(id) }

    // MARK: Frames

    func step(_ dt: Double) {
        guard !isDone else { return }
        t += Float(dt)
        place()
        if t >= plan.duration && pending.isEmpty { tidy() }
    }

    /// Hard sleep (or Reduce Motion): everything is under at once.
    func finish() {
        guard !isDone else { return }
        for id in pending.sorted() { arrive(id) }
        tidy()
    }

    /// The model moved on (an undo while the pass plays): the stand-ins go without a word.
    func cancel() {
        guard !isDone else { return }
        mat.ghostCards.removeAll()
        mat.ghostBumps.removeAll()
        for id in pending { mat.arrived(id) }
        pending.removeAll()
        tidied = true
        isDone = true
        mat.brush?.scripted = nil
    }

    /// Whether the model still holds the plan's result: every pending swept pile where it was sent and every pending
    /// floor stack in its new pile.
    func stillApplies(to s: DeskState) -> Bool {
        for sweep in plan.sweeps where pending.contains(sweep.pile) {
            if !s.tokens.members(of: sweep.pile).isEmpty && s.piles[sweep.pile] != sweep.to { return false }
        }
        for tuck in plan.tucks where pending.contains(tuck.pile) {
            if tuck.keys.contains(where: { s.tokens.location(of: $0)?.pile != tuck.pile }) { return false }
        }
        return true
    }

    /// Removes what is left on screen.
    func tearDown() {
        for g in ghosts.values { g.node.removeFromParent() }
        ghosts.removeAll()
        mat.ghostCards.removeAll()
        mat.ghostBumps.removeAll()
    }

    private func tidy() {
        guard !tidied else { return }
        tidied = true
        isDone = true
        mat.brush?.scripted = nil
        // Over the monitor's dark glass (Clear the Desk turned it off), where its green reads.
        let glass = mat.context.layout.rect(CoreLayout.screen)
        let top = ArtPoint(glass.midX, glass.midY + 10)
        mat.context.fx.pop(.tidy, at: top)
        if !mat.context.reduceMotion {
            mat.context.fx.sparkle(at: ArtPoint(top.x - 24, top.y - 6))
            mat.context.fx.sparkle(at: ArtPoint(top.x + 22, top.y - 9))
        }
    }

    private func arrive(_ id: PileID) {
        guard pending.remove(id) != nil else { return }
        if let g = ghosts.removeValue(forKey: id) { g.node.removeFromParent() }
        mat.ghostCards[id] = nil
        mat.ghostBumps[id] = nil
        if let hub = mat.hub, let at = plan.sweeps.first(where: { $0.pile == id })?.to
            ?? plan.tucks.first(where: { $0.pile == id })?.edge {
            mat.context.fx.puff(at: DeskMatElement.pixel(hub.canvas(plane: at)))
        }
        mat.arrived(id)
    }

    // MARK: Placing

    private func place() {
        guard let hub = mat.hub else { return }
        if let p = plan.brushPosition(at: t) { mat.brush?.scripted = p }
        var bumpsMoved = false
        for sweep in plan.sweeps where pending.contains(sweep.pile) {
            guard let g = ghosts[sweep.pile] else { continue }
            if t >= sweep.under {
                arrive(sweep.pile)
                continue
            }
            let p = ClearDeskPlan.position(of: sweep, at: t)
            if t < sweep.atEdge {
                pushed(sweep.pile, g, at: p, hub: hub)
            } else {
                bumpsMoved = slidUnder(sweep.pile, g, at: p, edge: sweep.edge,
                                       u: (t - sweep.atEdge) / max(sweep.under - sweep.atEdge, 1e-3)) || bumpsMoved
            }
        }
        for tuck in plan.tucks where pending.contains(tuck.pile) {
            guard let g = ghosts[tuck.pile] else { continue }
            if t >= tuck.under {
                arrive(tuck.pile)
                continue
            }
            let floor = mat.context.layout.point(ArtPoint(tuck.floorX, CoreLayout.floorY))
            let floorPt = SIMD2(Float(floor.x), Float(floor.y))
            let edge = hub.canvas(plane: tuck.edge)
            if t < tuck.land {
                // Waiting on the floor, then a hop up onto the mat's edge.
                let u = max(0, (t - tuck.start) / max(tuck.land - tuck.start, 1e-3))
                let peak = min(floorPt.y, edge.y) - Self.hopHeight
                let a = floorPt.y, c = edge.y
                // A parabola through the floor, the peak and the edge (vertex at the peak's time).
                let y = (1 - u) * (1 - u) * a + 2 * u * (1 - u) * (2 * peak - (a + c) / 2) + u * u * c
                let x = floorPt.x + (edge.x - floorPt.x) * u
                show(g, foot: SIMD2(x, y), z: Self.flightZ)
            } else {
                let u = (t - tuck.land) / max(tuck.under - tuck.land, 1e-3)
                let p = tuck.edge + (tuck.to - tuck.edge) * u
                bumpsMoved = slidUnder(tuck.pile, g, at: p, edge: tuck.edge, u: u) || bumpsMoved
            }
        }
        if bumpsMoved { mat.restampBumps() }
    }

    /// A stand-in pushed along the desk: a sprite on top, or, once the mat's edge reaches it, a card in the mat's
    /// raster that the edge slides over.
    private func pushed(_ id: PileID, _ g: Ghost, at p: SIMD2<Float>, hub: PhysicsHub) {
        if mat.isAtEdge(p) {
            g.node.isHidden = true
            mat.ghostCards[id] = (g.stack, p)
            mat.rasterDirty = true
        } else {
            mat.ghostCards[id] = nil
            g.node.isHidden = false
            show(g, foot: hub.canvas(plane: p), z: DeskPilesElement.z(d: p.y))
        }
    }

    /// A stand-in gone under the edge (`u` of the way to its rest): hidden by the cloth, the hem riding up over it once,
    /// its bump growing as it slides in. True: the bumps moved.
    private func slidUnder(_ id: PileID, _ g: Ghost, at p: SIMD2<Float>, edge: SIMD2<Float>, u: Float) -> Bool {
        g.node.isHidden = true
        mat.ghostCards[id] = nil
        if !g.lifted {
            g.lifted = true
            mat.cloth.liftHem(near: edge, height: DeskMatElement.hemLift)
        }
        let e = min(1, max(0, u))
        mat.ghostBumps[id] = (p, 0.35 + 0.65 * e * e * (3 - 2 * e))
        mat.rasterDirty = true
        return true
    }

    /// Draws a ghost with its base at canvas `foot` (on the desk, or in flight from the floor).
    private func show(_ g: Ghost, foot: SIMD2<Float>, z: CGFloat) {
        let image = g.stack.image
        let origin = ArtPoint(Int(foot.x.rounded()) - g.stack.base.x, Int(foot.y.rounded()) - g.stack.base.y)
        g.node.zPosition = z
        guard g.shown != origin else { return }
        if g.shown == nil { g.node.texture = TextureFactory.texture(image) }
        g.shown = origin
        mat.context.space.place(g.node, at: ArtRect(origin: origin, size: image.size))
    }
}

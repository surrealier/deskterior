import DeskCore
import SpriteKit

/// One drawer of the riser or the cabinet as its element runs it (DESIGN §2.2 E3, E5, §2.1, Errata 13): the pure
/// `DrawerSim` on its rail and the `ContentJostle` of what lies inside, the members it holds, and the scene-side
/// bookkeeping around them:
///
/// - the model's opening as last seen: a change made elsewhere (Open…, Show on Desk, undo) animates there, while
///   the drawer's own settles commit back (`settled` → `.drawerSettled`);
/// - a scroll peek (0…4 px, held until 0.35 s after the last scroll);
/// - spring-loading: a carry resting on the shut front for 0.6 s opens it, and it shuts 0.8 s after the drop (or
///   once the carry leaves);
/// - the chomp: tokens arriving in a shut drawer open it 6 px, slide in as icons, and it shuts again;
/// - the handle's wiggle when a member's file goes away.
///
/// Geometry is in canvas px: `closedFront` and `closedHandle` are where the front and its pull rest shut; the
/// front slides down `pixel` rows and the interior shows in the rows it uncovers (`StorageArt`). Nothing here draws.
final class DrawerUnit {
    let id: ContainerID
    /// Columns between the front's left edge and the content buffer (`InteriorRaster`'s walls): 2 on the riser,
    /// 4 in the cabinet.
    let contentInset: Int
    var closedFront = ArtRect.zero
    var closedHandle = ArtRect.zero
    private(set) var sim: DrawerSim
    private(set) var jostle: ContentJostle
    private(set) var members: [TokenKey] = []
    private(set) var items: [InteriorRaster.Item] = []
    /// The model's opening last seen (nil until a model arrives).
    private(set) var modelP: Float?
    /// Tokens that came in through a chomp: drawn as icons while they slide in.
    private(set) var entering: Set<TokenKey> = []
    private(set) var springTime: Double = 0
    /// Opened by spring-loading: it shuts again after the carry.
    private(set) var springOpened = false
    /// Seconds until a spring-loaded drawer shuts.
    private(set) var closeIn: Double?
    /// A model open waits this long at most for the chair to roll clear.
    private(set) var pendingOpen: Double?
    private var peekAmount: Float = 0
    private var peekIdle: Double = 0
    private(set) var wiggleFrames = 0
    /// Called whenever the drawer starts opening (the cabinet closes its interlocked siblings).
    var onOpening: (() -> Void)?

    static let springDelay = 0.6
    static let springCloseDelay = 0.8
    static let chairWait = 1.5
    static let wiggleLength = 8

    init(_ id: ContainerID, contentInset: Int) {
        self.id = id
        self.contentInset = contentInset
        sim = DrawerSim(id)
        jostle = ContentJostle(homes: [], bounds: InteriorRaster.baseBounds(id), seed: Self.seed(id))
    }

    /// A stable per-drawer seed (never `hashValue`, which changes between runs).
    static func seed(_ id: ContainerID) -> UInt64 {
        UInt64((ContainerID.allCases.firstIndex(of: id) ?? 0) + 1) &* 0x9E37_79B9_7F4A_7C15
    }

    // MARK: Model

    /// Adopts the model: the members (tokens arriving in a shut drawer chomp; a spring-loaded one shuts soon
    /// after) and an opening changed elsewhere, which the drawer slides to unless the pointer holds it.
    func sync(_ s: DeskState) {
        let now = s.tokens.members(of: id)
        let fresh = InteriorRaster.items(id, in: s)
        guard let seen = modelP else {
            members = now
            items = fresh
            modelP = s.drawerOpening(id)
            sim = DrawerSim(id, p: s.drawerOpening(id), count: now.count)
            jostle = ContentJostle(homes: InteriorRaster.jostleHomes(id, items: fresh),
                                   bounds: InteriorRaster.baseBounds(id), seed: Self.seed(id))
            return
        }
        if now != members {
            let added = now.filter { !members.contains($0) }
            members = now
            items = fresh
            sim.setCount(now.count)
            jostle.setHomes(InteriorRaster.jostleHomes(id, items: fresh))
            entering.formIntersection(now)
            if !added.isEmpty { took(added) }
        } else if fresh != items {
            items = fresh
        }
        let p = s.drawerOpening(id)
        if p != seen {
            modelP = p
            if abs(p - sim.p) >= 0.5, !sim.isDragging { slide(to: p) }
        }
    }

    /// Tokens arrived: inside an open drawer they just land (a spring-loaded one shuts 0.8 s later); a shut or
    /// peeking drawer chomps them.
    private func took(_ added: [TokenKey]) {
        if springOpened { closeIn = Self.springCloseDelay }
        guard !sim.isRevealed else { return }
        if sim.chomp() {
            entering.formUnion(added)
            slideEntering()
            onOpening?()
        }
    }

    /// Slides to a model opening: all the way out (once the chair is clear), shut, or a scripted target.
    private func slide(to p: Float) {
        if p >= sim.travel - 0.5 {
            if sim.openLimit < sim.travel {
                pendingOpen = Self.chairWait
            } else {
                openFully()
            }
        } else if p <= sim.closedLimit + 0.5 {
            sim.shut()
        } else {
            sim.setTarget(p)
        }
    }

    // MARK: Gestures

    /// Click: more than half open closes, otherwise it opens (Errata 13).
    func toggle() {
        let opening = sim.p <= sim.closedLimit + max(1, (sim.travel - sim.closedLimit) / 2)
        springOpened = false
        closeIn = nil
        pendingOpen = nil
        sim.toggle()
        if opening { onOpening?() }
    }

    func openFully() {
        pendingOpen = nil
        sim.open()
        onOpening?()
    }

    func close() {
        springOpened = false
        closeIn = nil
        pendingOpen = nil
        sim.close()
    }

    /// The pointer grabbed the front.
    func beginPull() {
        springOpened = false
        closeIn = nil
        pendingOpen = nil
        sim.beginDrag()
        onOpening?()
    }

    func pull(to opening: Float) { sim.drag(to: opening) }

    func endPull(velocity: Float?) { sim.endDrag(releaseVelocity: velocity) }

    /// Two-finger scroll over a shut drawer: content moving down (toward the viewer) peeks it open, up pushes it
    /// back; a pause of `peekHold` starts over.
    func scroll(_ dy: Float) {
        guard dy.isFinite, !sim.isDragging else { return }
        if peekIdle >= Double(sim.params.peekHold) { peekAmount = 0 }
        peekIdle = 0
        peekAmount = min(max(peekAmount + dy, 0), sim.params.peekMax)
        let wasClosed = sim.p <= sim.closedLimit + 0.5
        sim.peek(peekAmount)
        if wasClosed, peekAmount > 0 { onOpening?() }
    }

    /// Spring-loading under a carry at `p` (nil: no carry in hand) that this drawer could take. True when it
    /// sprang open now.
    func carry(at p: ArtPoint?, accepts: Bool, dt: Double) -> Bool {
        var opened = false
        if let p, accepts, !sim.isRevealed, !sim.isChomping, front.contains(p) {
            springTime += dt
            if springTime >= Self.springDelay {
                springTime = 0
                springOpened = true
                closeIn = nil
                openFully()
                opened = true
            }
        } else {
            springTime = 0
        }
        if springOpened {
            if let p, area.contains(p) {
                closeIn = nil
                // Stopped by the chair, it carries on once the chair has rolled clear.
                if sim.p < sim.openLimit - 0.5, abs(sim.v) < 1, !sim.isDragging, !sim.isChomping { sim.open() }
            } else if closeIn == nil {
                closeIn = Self.springCloseDelay
            }
        }
        return opened
    }

    /// The model's upper stop (the chair in front of a cabinet drawer).
    func setOpenLimit(_ limit: Float) { sim.setOpenLimit(limit) }

    /// A member's file went away: the handle wiggles.
    func wiggle() { wiggleFrames = Self.wiggleLength }

    /// A desk knock (DESIGN §2.2 E11): an ajar drawer within reach snaps shut; with `jostle` its contents hop.
    func knock(closes: Bool, jostleStrength: Float?, seed: UInt64) {
        if closes { _ = sim.knock() }
        if let jostleStrength { jostle.knock(strength: jostleStrength, seed: seed) }
    }

    // MARK: Frames

    var needsFrames: Bool {
        sim.needsFrames || jostle.needsFrames || closeIn != nil || pendingOpen != nil || wiggleFrames > 0
            || springTime > 0 || peekAmount > 0
    }

    func step(_ dt: Double) -> [DrawerSim.Event] {
        if let wait = pendingOpen {
            if sim.openLimit >= sim.travel || wait - dt <= 0 { openFully() } else { pendingOpen = wait - dt }
        }
        if let t = closeIn {
            if t - dt <= 0 { close() } else { closeIn = t - dt }
        }
        if peekAmount > 0 {
            peekIdle += dt
            if peekIdle >= Double(sim.params.peekHold) { peekAmount = 0 }
        }
        if wiggleFrames > 0 { wiggleFrames -= 1 }
        let events = sim.step(Float(dt))
        jostle.step(drawerAcceleration: sim.acceleration, Float(dt))
        if sim.isAsleep, !sim.isChomping { entering.removeAll() }
        return events
    }

    /// Hard sleep: everything at its end.
    func settle() -> [DrawerSim.Event] {
        pendingOpen = nil
        closeIn = nil
        springOpened = false
        springTime = 0
        peekAmount = 0
        wiggleFrames = 0
        let events = sim.forceRest()
        jostle.forceRest()
        entering.removeAll()
        return events
    }

    /// Tokens just chomped start at the back wall and slide to the front as the drawer gapes.
    private func slideEntering() {
        let back = jostle.bounds.lowerBound
        for (i, key) in members.enumerated() where entering.contains(key) {
            jostle.place(i, at: back, velocity: 40)
        }
    }

    // MARK: Geometry (canvas px)

    var pixel: Int { sim.pixel }
    /// The handle's 1-px sideways wiggle.
    var wiggleDX: Int { wiggleFrames > 0 ? (wiggleFrames / 2 % 2 == 0 ? 1 : -1) : 0 }
    var front: ArtRect { closedFront.offsetBy(0, pixel) }
    var handle: ArtRect { closedHandle.offsetBy(0, pixel) }
    /// The rows the front has uncovered.
    var interior: ArtRect { ArtRect(closedFront.x, closedFront.y, closedFront.w, pixel) }
    /// Front and interior together.
    var area: ArtRect { ArtRect(closedFront.x, closedFront.y, closedFront.w, closedFront.h + pixel) }
    var contentSize: ArtSize { InteriorRaster.contentSize(id) }
    /// Canvas top-left of the content buffer: its bottom `pixel − 1` rows show just under the drawer's back edge.
    var contentOrigin: ArtPoint {
        ArtPoint(closedFront.x + contentInset, closedFront.y + pixel - contentSize.h)
    }
    /// Where content shows (under the back edge's shadow row, above the front).
    var contentClip: ArtRect {
        ArtRect(closedFront.x + contentInset, closedFront.y + 2, contentSize.w, max(0, pixel - 2))
    }
    /// Minis can be seen and picked: revealed, with rows to see.
    var showsMinis: Bool { sim.isRevealed && contentClip.h > 0 && !members.isEmpty }

    /// Each member's drawn rect (canvas px, before clipping).
    func miniRects() -> [ArtRect] {
        let o = contentOrigin
        return InteriorRaster.itemRects(id, items: items, offsets: jostle.pixelOffsets).map { $0.offsetBy(o.x, o.y) }
    }

    /// The member drawn under `p` (not one in `hidden`), front-most first (`front`: selected or raised, drawn on
    /// top), with its visible rect.
    func mini(at p: ArtPoint, except hidden: Set<TokenKey>, front: Set<TokenKey>) -> (key: TokenKey, rect: ArtRect)? {
        guard showsMinis, contentClip.contains(p) else { return nil }
        let rects = miniRects()
        // The order `InteriorRaster` draws them in (selected or raised ones on top), reversed.
        let marks = marks(hidden: [], selected: [], raised: front)
        let order = InteriorRaster.drawOrder(items.count, open: true, marks: marks) { rects[$0].maxY }.reversed()
        for i in order where !hidden.contains(members[i]) {
            let r = rects[i].intersection(contentClip)
            if r.contains(p) { return (members[i], r) }
        }
        return nil
    }

    /// How the interior draws `members`: in hand, selected (or raised: in front without the backdrop), sliding in.
    func marks(hidden: Set<TokenKey>, selected: Set<TokenKey>, raised: Set<TokenKey>) -> InteriorRaster.Marks {
        var m = InteriorRaster.Marks()
        for (i, k) in members.enumerated() {
            if hidden.contains(k) { m.hidden.insert(i) }
            if selected.contains(k) { m.selected.insert(i) }
            if raised.contains(k) { m.raised.insert(i) }
            if entering.contains(k) { m.shown.insert(i) }
        }
        return m
    }

    /// Everything the drawer's picture depends on now.
    func look(hidden: Set<TokenKey>, selected: Set<TokenKey>, raised: Set<TokenKey>) -> DrawerLook {
        DrawerLook(p: pixel, revealed: sim.isRevealed, items: items, offsets: jostle.pixelOffsets,
                   marks: marks(hidden: hidden, selected: selected, raised: raised), dx: wiggleDX)
    }

    /// Whether `tokens` dropped here fit (tokens already inside only reorder).
    func fits(_ tokens: [TokenKey]) -> Bool {
        let movers = Set(tokens)
        return members.filter { !movers.contains($0) }.count + movers.count <= id.spec.hardCap
    }
}

/// What a drawer's picture depends on (it is redrawn only when this changes).
struct DrawerLook: Equatable {
    var p: Int
    var revealed: Bool
    var items: [InteriorRaster.Item]
    var offsets: [Int]
    var marks: InteriorRaster.Marks
    var dx: Int
}

/// The pointer pulling a drawer by its front (DESIGN §2.2 E3: a 1D follow along the rail; a release coasts with
/// the pointer's speed, so a flick shut slams). The drawer keeps moving in its element after the release.
final class DrawerPull: DragController {
    private let unit: DrawerUnit
    private let grabY: Float
    private let grabP: Float
    private(set) var isFinished = false

    init(unit: DrawerUnit, from: SIMD2<Float>) {
        self.unit = unit
        grabY = from.y
        grabP = unit.sim.p
        unit.beginPull()
    }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        unit.pull(to: grabP + (p.y - grabY))
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        moved(to: p, mods: mods)
        unit.endPull(velocity: velocity.y)
        isFinished = true
    }

    func cancelled() {
        guard !isFinished else { return }
        unit.endPull(velocity: 0)
        isFinished = true
    }

    func step(_ dt: Double) {}
    var needsFrames: Bool { false }
}

import DeskCore
import DeskPixels
import SpriteKit

/// Services the room shares with its elements (DESIGN §4.4): the solved layout, the committed model, the
/// selection, real icons, the Galmuri9 font, the L7 fx layer and L8 carry layer, and the ways back out: model
/// actions (`dispatch`), app requests (menus, Inventory), toasts and the screen shake.
public final class SceneContext {
    public let selection = Selection()
    public internal(set) var layout: SceneLayout
    var space: ArtSpace
    /// The committed model; nil until the app applies one (the bare M3 room).
    public internal(set) var state: DeskState?
    /// Pixelated real icons (16 px) by token; others show their kind icon.
    public internal(set) var icons: [TokenKey: PixelBuffer] = [:]
    /// The wallpaper's sky (follows the room's phase).
    public internal(set) var sky: SkyVariant = .day
    let font: PixelFont?
    let fx: FXLayer
    let carryLayer = SKNode()
    weak var screen: ScreenElement?
    /// Drops refused so far (demo expectations).
    public internal(set) var bonks = 0
    /// Frames of 1-px screen shake left.
    var shakeFrames = 0
    var onAction: ((DeskAction) -> Void)?
    var onRequest: ((SceneRequest) -> Void)?
    var onToast: ((ToastKey) -> Void)?
    var placementZs: [String: CGFloat] = [:]
    var dropOrder: () -> [any DeskElement] = { [] }

    // MARK: lighting
    /// Reduce Motion (system setting or the app's): flickers, jiggles, spring-backs and the CRT jump to their end.
    public internal(set) var reduceMotion = false
    /// What the lamp, room switch and clock show before the model or the clock catch up (flicker, time preview).
    let lightOverrides = SceneLightOverrides()

    init(layout: SceneLayout, font: PixelFont?) {
        self.layout = layout
        space = ArtSpace(canvas: layout.canvas)
        self.font = font
        fx = FXLayer(z: CGFloat(RoomLayer.fx.rawValue * 1000), space: space)
    }

    func dispatch(_ action: DeskAction) { onAction?(action) }
    func request(_ r: SceneRequest) { onRequest?(r) }
    func toast(_ key: ToastKey) { onToast?(key) }
    func shake(frames: Int) { shakeFrames = max(shakeFrames, frames) }
    /// The z of a room placement ("monitor.screen"), for drawing just above it.
    func placementZ(_ id: String) -> CGFloat { placementZs[id] ?? CGFloat(RoomLayer.deskBack.rawValue * 1000 + 999) }
    /// Elements that may take dropped tokens, front to back.
    func dropTargets() -> [any DeskElement] { dropOrder() }
}

/// The room (DESIGN §1.3, §4.4): the `RoomPlan` placements shown through one `PlacedElement` per object, z-ordered
/// by layer, the monitor and its screen as interactive elements, the L7 fx, L8 carry and L9 ui layers, and the
/// light mask and ambient level for the lit pass. It is the `InputRouter`'s target: it hit-tests front to back
/// (ui → carry → chair → under-desk → desk-front props → desk surface → desk-back: riser, phone, hub, the screen's
/// tokens, the monitor → wall → bare wall), draws the 1-px hover ring and the tooltip, and handles what no
/// element takes (clicks on the bare wall clear the selection; its right-click is the desk menu).
final class RoomContent: GestureTarget {
    let root = SKNode()
    private(set) var layout: SceneLayout
    private(set) var state: RoomState
    private(set) var elements: [PlacedElement] = []
    private(set) var hovered: Hit?
    private(set) var lightMask: LightMask
    private(set) var ambient: AmbientLight
    let context: SceneContext
    let screen: ScreenElement
    let monitor: MonitorElement
    private(set) var router: InputRouter!
    let tooltip = TooltipView(z: CGFloat(RoomLayer.ui.rawValue * 1000 + 10))
    let toast = ToastView(z: CGFloat(RoomLayer.ui.rawValue * 1000 + 20))
    /// The desk menu's extras (pause state, undo labels), from the app.
    var menuContext = MenuSpec.Context()

    private var space: ArtSpace
    private var byID: [String: PlacedElement] = [:]
    /// Interactive elements front to back (hit-test and drop order).
    private(set) var routing: [any DeskElement] = []
    /// Stable draw order of every placement id (from the last full build).
    private var order: [String: Int] = [:]
    let hoverNode = SKSpriteNode()
    /// Drags that ended but still animate home.
    private var settling: [any DragController] = []
    /// Interactive elements and the placed object whose hit-test slot they fill (front first).
    private var installed: [(slot: String, elements: [any DeskElement])] = []
    /// Every installed element.
    var extras: [any DeskElement] { installed.flatMap(\.elements) }

    static let hoverInk = Role.selection

    /// Hover tooltips for the room's decorative objects.
    static let titles: [String: String] = [
        "window": "Window", "clock": "Clock", "calendar": "Calendar", "room.switch": "Room Light", "plant": "Plant",
        "lamp": "Desk Lamp", "riser": "Monitor Riser", "phone": "Phone", "hub": "Drive Hub", "pencup": "Pen Cup",
        "keyboard": "Keyboard", "brush": "Desk Brush", "cabinet": "Cabinet", "wastebasket": "Wastebasket",
        "chair": "Chair",
    ]

    init(grid: PixelGrid, state: RoomState, avoid: [ArtRect] = []) {
        layout = LayoutSolver.solve(grid: grid, avoid: avoid)
        self.state = state
        space = ArtSpace(canvas: grid.artSize)
        lightMask = LightMask(size: grid.artSize)
        ambient = .identity
        context = SceneContext(layout: layout, font: PixelFont.galmuri9)
        context.sky = state.sky
        screen = ScreenElement(context: context)
        monitor = MonitorElement(context: context, screen: screen)
        context.screen = screen
        hoverNode.zPosition = CGFloat(RoomLayer.ui.rawValue * 1000)
        hoverNode.isHidden = true
        root.addChild(hoverNode)
        root.addChild(context.fx.root)
        root.addChild(context.carryLayer)
        root.addChild(tooltip.node)
        root.addChild(toast.node)
        router = InputRouter(target: self)
        context.dropOrder = { [unowned self] in routing }
        context.onToast = { [unowned self] key in showToast(key) }
        install([screen, monitor], inSlotOf: "monitor")
        installContainers()
        installRoomControls()
        rebuild()
    }

    /// Puts `elements` (front first) in the hit-test slot of the placed object `slot`: they answer its hits, drops,
    /// gestures and menus, and get layout, state and frames; the placed sprites keep drawing until an element draws
    /// its own. The screen and monitor take the monitor's slot; drawers, phone, cup, basket and mat elements plug
    /// in the same way (waves 4b/5).
    func install(_ elements: [any DeskElement], inSlotOf slot: String) {
        installed.removeAll { $0.slot == slot }
        installed.append((slot, elements))
        for e in elements where e.root.parent == nil { root.addChild(e.root) }
        if !self.elements.isEmpty {
            for e in elements { e.layout(layout) }
            if let s = context.state { for e in elements { e.apply(s) } }
            rebuildRouting()
        }
    }

    // MARK: Building

    /// Rebuilds everything for the current layout and state.
    private func rebuild() {
        let all = RoomPlan.placements(layout, state)
        order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.id, $0.offset) })
        context.placementZs = Dictionary(uniqueKeysWithValues: all.map { ($0.id, zPosition($0)) })
        for e in elements { e.root.removeFromParent() }
        elements = []
        byID = [:]
        var groups: [String: [RoomPlacement]] = [:]
        var groupOrder: [String] = []
        for p in all {
            let eid = Self.elementID(for: p.id)
            if groups[eid] == nil { groupOrder.append(eid) }
            groups[eid, default: []].append(p)
        }
        for eid in groupOrder {
            let e = PlacedElement(id: eid, anchorPrefixes: Self.anchorPrefixes(for: eid))
            e.title = Self.titles[eid]
            if eid == "hub" { e.dropPolicy = .bonk(.drivesReadOnly) }
            e.layout(layout)
            e.apply(groups[eid]!, replacingAll: true, z: zPosition)
            root.addChild(e.root)
            elements.append(e)
            byID[eid] = e
        }
        monitor.placed = byID["monitor"]
        context.layout = layout
        context.space = space
        context.fx.space = space
        for e in extras { e.layout(layout) }
        rebuildRouting()
        updateLighting()
        setHover(nil, element: nil)
        router.resetHover()
    }

    /// Placed elements front to back, each slot with installed elements taken by them (the monitor's: the
    /// screen's tokens, then the monitor), the bare wall last.
    private func rebuildRouting() {
        var out: [any DeskElement] = []
        for e in elements.sorted(by: { maxZ($0) > maxZ($1) }) where e.id != "room" {
            if let slot = installed.first(where: { $0.slot == e.id }) {
                out += slot.elements
            } else {
                out.append(e)
            }
        }
        if let room = byID["room"] { out.append(room) }
        routing = out
    }

    /// Refreshes only the placements in `ids` (state changes); `relight` also rebuilds the light mask.
    private func refresh(_ ids: Set<String>, relight: Bool) {
        let fresh = RoomPlan.placements(layout, state, only: ids)
        var groups: [String: [RoomPlacement]] = [:]
        for p in fresh { groups[Self.elementID(for: p.id), default: []].append(p) }
        for (eid, ps) in groups {
            guard let e = byID[eid] else { return rebuild() }
            e.apply(ps, replacingAll: false, z: zPosition)
        }
        if relight { updateLighting() }
    }

    private func zPosition(_ p: RoomPlacement) -> CGFloat {
        CGFloat(p.layer.rawValue * 1000 + (order[p.id] ?? 999))
    }

    private func updateLighting() {
        let tod = state.timeOfDay
        lightMask = LightMask.room(layout, lights: state.effectiveLights, time: tod)
        ambient = AmbientLight(level: tod.ambientLevel, tint: tod.ambientTint)
    }

    /// The element that owns a placement id.
    static func elementID(for placementID: String) -> String {
        switch placementID {
        case "backdrop": "room"
        case _ where RoomPlan.glowIDs.contains(placementID): "room"
        case "desk.front": "desk"
        case "room.switch": "room.switch"
        default:
            if placementID.hasPrefix("decor.") { placementID }
            else if let dot = placementID.firstIndex(of: ".") { String(placementID[..<dot]) }
            else { placementID }
        }
    }

    static func anchorPrefixes(for elementID: String) -> [String] {
        switch elementID {
        case "room": ["desk.top", "mat", "floor"]
        case "desk": ["apron"]
        default: [elementID]
        }
    }

    /// The hover ring round a part: one pixel outside what is drawn (the power button, not its generous hit
    /// rect), kept inside the chin for the chin's controls.
    static func ringRect(part: String, hit: ArtRect, layout: SceneLayout) -> ArtRect {
        let drawn = part == "monitor.power" ? layout.rect(CoreLayout.power) : hit
        let ring = drawn.insetBy(-1, -1)
        let chin = layout.rect(CoreLayout.chin).insetBy(1, 1)
        return chin.contains(drawn) ? ring.intersection(chin) : ring
    }

    // MARK: Updates

    /// Adopts a new grid (and avoid rects): full rebuild.
    func relayout(grid: PixelGrid, avoid: [ArtRect]) {
        router.cancelAll()
        finishSettling()
        layout = LayoutSolver.solve(grid: grid, avoid: avoid)
        space = ArtSpace(canvas: grid.artSize)
        rebuild()
        if let s = context.state { apply(s) }
    }

    /// Adopts a new state, rebuilding only what it changes. True when anything visible changed.
    @discardableResult
    func setState(_ new: RoomState) -> Bool {
        guard new != state else { return false }
        let old = state
        state = new
        let skyChanged = context.sky != new.sky
        context.sky = new.sky
        let a = old.timeOfDay, b = new.timeOfDay
        let sameLight = a.sky == b.sky && a.ambientLevel == b.ambientLevel && a.ambientTint == b.ambientTint
            && old.effectiveLights == new.effectiveLights && old.lightsMode == new.lightsMode
        let sameRest = old.riserOpen == new.riserOpen && old.cabinetOpen == new.cabinetOpen
            && old.chairX == new.chairX && old.chairFacing == new.chairFacing
        let minuteOnly = sameLight && sameRest
        refresh(minuteOnly ? RoomPlan.minuteIDs : RoomPlan.stateDependentIDs, relight: !minuteOnly)
        if skyChanged, let s = context.state { monitor.apply(s) }
        return true
    }

    /// Adopts committed model state into every interactive element.
    func apply(_ s: DeskState) {
        context.state = s
        for e in extras { e.apply(s) }
        for e in elements { e.apply(s) }
        pruneSelection()
        router.refreshHover()
        router.reaimDrag()
    }

    /// Drops selected tokens no element shows any more (power off, AV, another page, moved into hiding).
    func pruneSelection() {
        guard !context.selection.isEmpty else { return }
        let shown = extras.reduce(into: Set<TokenKey>()) { $0.formUnion($1.shownTokens) }
        context.selection.restrict(to: shown)
        screen.refreshIfSelectionChanged()
    }

    func showIcon(_ key: TokenKey, _ icon: PixelBuffer?) {
        context.icons[key] = icon
        if let s = context.state, s.tokens.location(of: key)?.isScreen == true { screen.apply(s) }
    }

    // MARK: Animations

    /// Plays a model-requested animation (`Effect.play`).
    func play(_ id: AnimationID, _ target: AnimTarget) {
        switch (id, target) {
        case let (.printIn, .tokens(keys)), let (.parade, .tokens(keys)):
            screen.playPrintIn(keys)
            if id == .printIn, let s = context.state {
                // New files that land on another page blink that page's dot.
                let pages = Set(keys.compactMap { s.tokens.location(of: $0)?.cell?.page })
                monitor.blinkDots(pages.subtracting(s.monitor.av ? [] : [s.monitor.page]))
            }
        case let (.printIn, .token(key)), let (.parade, .token(key)):
            screen.playPrintIn([key])
        case let (.poof, .location(loc)):
            screen.playPoof(at: loc)
        case let (.pulse, .token(key)):
            screen.playPulse(key)
            pulseContainers(key)
        case let (.bonk, .container(id)):
            if let r = layout.anchors[Self.anchor(for: id)] {
                context.fx.pop(.bonk, at: ArtPoint(r.midX, r.minY))
                context.shake(frames: 2)
            }
        default:
            // CRT, static, OSD and the LED follow the model through MonitorMachine; containers and the mat
            // animate in their own elements (waves 4b/5).
            playContainer(id, target)
        }
    }

    static func anchor(for id: ContainerID) -> String {
        switch id {
        case .riserLeft: "riser.drawerL"
        case .riserRight: "riser.drawerR"
        case .riserCubby: "riser.cubby"
        case .cabinetTop: "cabinet.top"
        case .cabinetMiddle: "cabinet.middle"
        case .cabinetFile: "cabinet.file"
        case .penCup: "pencup"
        case .phone: "phone"
        case .wastebasket: "wastebasket.mouth"
        }
    }

    func showToast(_ key: ToastKey) {
        toast.show(key, font: context.font, layout: layout, space: space)
    }

    // MARK: Frames

    var needsFrames: Bool {
        scriptedAnimating
    }

    /// Everything that moves here is scripted and bounded, or a drag in hand.
    var scriptedAnimating: Bool {
        extras.contains { $0.needsFrames } || router.drag != nil || !settling.isEmpty
            || context.fx.needsFrames || toast.needsFrames || context.shakeFrames > 0
            || elements.contains { $0.needsFrames }
    }

    func step(_ dt: Double) {
        router.drag?.step(dt)
        for d in settling { d.step(dt) }
        settling.removeAll { $0.isFinished }
        for e in extras { e.step(dt) }
        pruneSelection()
        for e in elements where e.needsFrames { e.step(dt) }
        context.fx.step(dt)
        toast.step(dt, space: space)
        if context.shakeFrames > 0 { context.shakeFrames -= 1 }
    }

    /// The 1-px screen shake for this frame.
    var shake: ArtPoint { context.shakeFrames > 0 ? ArtPoint(context.shakeFrames % 2 == 0 ? 1 : -1, 0) : .zero }

    /// Hard sleep: every animation jumps to its end.
    func forceRest() {
        finishSettling()
        for e in extras { e.settle() }
        for e in elements { e.settle() }
        context.fx.clear()
        toast.hide()
        context.shakeFrames = 0
    }

    private func finishSettling() {
        for d in settling { (d as? CarrySession)?.finishNow() }
        settling.removeAll()
    }

    /// Canvas rects the lit pass keeps at full light (tooltip, toast).
    var emissiveRects: [ArtRect] {
        [tooltip.rect, toast.rect].compactMap { $0 }
    }

    // MARK: Input

    /// Front-to-back hit test in canvas px (the room backdrop answers last).
    func hitTest(_ p: ArtPoint) -> Hit? {
        target(at: p)?.hit
    }

    func target(at p: ArtPoint) -> (hit: Hit, element: any DeskElement)? {
        for e in routing {
            if let hit = e.hitTest(p) { return darkFiltered(hit, e) }
        }
        return nil
    }

    private func maxZ(_ e: PlacedElement) -> CGFloat {
        e.placements.map(zPosition).max() ?? 0
    }

    /// True when something visible changed.
    func handle(_ event: InputEvent) -> Bool {
        router.handle(event)
    }

    @discardableResult
    func setHover(_ hit: Hit?, element: (any DeskElement)?) -> Bool {
        let shown = hit?.element == "room" ? nil : hit
        guard shown != hovered else { return false }
        hovered = shown
        guard let hit = shown, let element else {
            hoverNode.isHidden = true
            return true
        }
        let ring: PixelBuffer
        let origin: ArtPoint
        switch element.hoverStyle(hit) {
        case .none:
            hoverNode.isHidden = true
            return true
        case let .image(image, at):
            ring = image
            origin = at
        case .standard:
            if let part = hit.part {
                let r = Self.ringRect(part: part, hit: hit.rect, layout: layout)
                var c = PixelCanvas(width: r.w, height: r.h)
                c.roundedRectStroke(c.bounds, radius: 2, Self.hoverInk)
                ring = c.buffer
                origin = r.origin
            } else if let placed = element as? PlacedElement {
                let b = placed.bounds
                ring = placed.silhouette().outlined(Self.hoverInk)
                origin = ArtPoint(b.x - 1, b.y - 1)
            } else {
                hoverNode.isHidden = true
                return true
            }
        }
        hoverNode.texture = TextureFactory.texture(ring)
        space.place(hoverNode, at: ArtRect(origin: origin, size: ring.size))
        hoverNode.isHidden = false
        return true
    }

    func setTooltip(_ spec: TooltipSpec?) -> Bool {
        tooltip.show(spec, font: context.font, bounds: layout.visible.intersection(ArtRect(origin: .zero, size: layout.canvas)), space: space)
    }

    func unhandled(_ gesture: Gesture) -> Bool {
        guard case let .click(_, mods, _) = gesture, mods.isEmpty, !context.selection.isEmpty else { return false }
        context.selection.clear()
        screen.refreshIfSelectionChanged()
        return true
    }

    func menu(at p: SIMD2<Float>, hit: Hit?, element: (any DeskElement)?) {
        if element is DarkTokenElement { return }
        let spec = hit.flatMap { h in element?.menu(h) } ?? MenuSpec.desk(context.state ?? DeskState(), menuContext)
        context.request(.menu(spec, at: p))
    }

    /// A desk key. File keys act only on selected tokens that are on show (`pruneSelection`).
    func key(_ command: KeyCommand) -> Bool {
        let selection = context.selection
        pruneSelection()
        switch command {
        case .quickLook:
            guard !selection.isEmpty else { return false }
            context.dispatch(.requestQuickLook(selection.sorted))
        case .open:
            guard !selection.isEmpty else { return false }
            context.dispatch(.requestOpen(selection.sorted))
        case .copy:
            guard !selection.isEmpty else { return false }
            context.dispatch(.requestCopy(selection.sorted))
        case .selectAll:
            screen.selectAll()
        case .find:
            context.request(.inventory)
        case .undo:
            context.dispatch(.undo)
        case .redo:
            context.dispatch(.redo)
        case .escape:
            guard !selection.isEmpty else { return false }
            selection.clear()
            screen.refreshIfSelectionChanged()
        case let .move(dx, dy):
            screen.moveSelection(dx: dx, dy: dy)
        }
        return true
    }

    func settle(_ drag: any DragController) {
        if !drag.isFinished { settling.append(drag) }
    }
}

import DeskCore
import SpriteKit

/// What the M6 hiding-place elements share (DESIGN §2.2 E3–E6, Errata 12): the context and committed model, the
/// room's placed sprites they replace once a model arrives (the bare room keeps drawing those), the carry in hand
/// (spring-loading), and selectable minis — tokens drawn small inside an open container — with Finder-style
/// gestures, a cropped hover ring, a name tooltip, the token menu and Show on Desk's pulse.
class ContainerElement {
    unowned let context: SceneContext
    let root = SKNode()
    private(set) var state: DeskState?
    /// The room's placed object this element draws in place of.
    var placed: () -> PlacedElement? = { nil }
    /// The carry in hand, if any.
    var activeCarry: () -> CarrySession? = { nil }
    /// Show on Desk's token: selected as soon as it is on show; its mini then blinks for `pulseDuration`.
    private(set) var pulse: (key: TokenKey, age: Double)?
    private var pendingSelect: TokenKey?
    /// Seconds Show on Desk's token has waited to come on show (the drawer opening, the chair rolling clear).
    private var pulseWait: Double = 0
    private var pressAdded = false

    static let pulseDuration = 2.0
    static let pulseMaxWait = 3.0

    init(context: SceneContext) {
        self.context = context
    }

    /// Placement ids this element draws itself once it has a model.
    var drawnPlacements: [String] { [] }

    /// Tokens in hand (any carry's), not drawn where they were picked up.
    var carried: Set<TokenKey> { context.screen?.carried ?? [] }

    func adopt(_ s: DeskState) {
        state = s
        if let p = pendingSelect, !s.tokens.contains(p) { pendingSelect = nil }
        hidePlaced()
    }

    /// Hides the room's own sprites for what this element draws (after a model arrives and after a rebuild).
    func hidePlaced() {
        guard state != nil, let placed = placed() else { return }
        let ids = Set(drawnPlacements)
        for node in placed.root.children where node.name.map(ids.contains) == true { node.isHidden = true }
    }

    /// The carry's pointer pixel and keys while it is in hand.
    var carryInHand: (point: ArtPoint, keys: [TokenKey])? {
        guard let c = activeCarry(), c.phase == .carrying else { return nil }
        return (ArtPoint(Int(c.pointer.x.rounded(.down)), Int(c.pointer.y.rounded(.down))), c.keys)
    }

    // MARK: Minis

    /// A gesture on mini `key`: press selects (⌘ adds, ⇧ extends), a click narrows to it, a double-click opens
    /// the selection on show, a drag carries the selected minis `shown` here (lead first). `origin` is where a
    /// token's 16-px icon would sit over its mini (the carry's spring-back target).
    func handleMini(
        _ gesture: Gesture, key: TokenKey, shown: Set<TokenKey>, origin: (TokenKey) -> ArtPoint?
    ) -> GestureResponse {
        guard let s = state, s.tokens.contains(key) else { return .pass }
        let selection = context.selection
        defer { selectionMayHaveChanged() }
        switch gesture {
        case let .press(_, mods):
            pressAdded = false
            if mods.contains(.command) {
                if !selection.contains(key) {
                    selection.click(key, mods: [.command])
                    pressAdded = true
                }
            } else if mods.contains(.shift) {
                selection.click(key, mods: mods)
            } else if !selection.contains(key) {
                selection.select(key)
            }
            return .handled
        case let .click(_, mods, count):
            defer { pressAdded = false }
            if count == 2 {
                let keys = selection.contains(key) ? selection.sorted.filter(shown.contains) : [key]
                context.dispatch(.requestOpen(keys.isEmpty ? [key] : keys))
            } else if count == 1 {
                if mods.contains(.command) {
                    if !pressAdded { selection.click(key, mods: [.command]) }
                } else if mods.isEmpty {
                    selection.select(key)
                }
            }
            return .handled
        case let .dragBegan(from, at, _):
            pressAdded = false
            if !selection.contains(key) { selection.select(key) }
            let keys = [key] + selection.sorted.filter { $0 != key && shown.contains($0) && !carried.contains($0) }
            let origins = keys.compactMap(origin)
            guard origins.count == keys.count else { return .pass }
            let session = CarrySession(keys: keys, origins: origins, grab: from, context: context)
            session.moved(to: at, mods: [])
            return .drag(session)
        case .cancelPress:
            pressAdded = false
            return .handled
        case .scroll:
            return .pass
        }
    }

    /// The token menu for a right-click on mini `key` (it joins the selection first).
    func miniMenu(_ key: TokenKey) -> MenuSpec? {
        guard let s = state, s.tokens.contains(key) else { return nil }
        if !context.selection.contains(key) { context.selection.select(key) }
        selectionMayHaveChanged()
        return MenuSpec.token(context.selection.sorted, s)
    }

    /// A mini's tooltip: its name, then kind and date.
    func miniTooltip(_ key: TokenKey, anchor: ArtRect) -> TooltipSpec? {
        guard let meta = state?.tokens.meta(of: key) else { return nil }
        var spec = TooltipSpec(title: meta.displayName, detail: TokenArt.detail(meta), anchor: anchor)
        spec.prefersAbove = true
        return spec
    }

    /// The screen's hover ring round `icon` drawn at `origin`, cropped to what can be seen (`clip` and 2 px round it).
    static func miniRing(_ icon: PixelBuffer, at origin: ArtPoint, clip: ArtRect) -> HoverStyle {
        let ring = TokenArt.hoverRing(icon)
        let r = ArtRect(origin.x - 2, origin.y - 2, ring.width, ring.height)
        let shown = r.intersection(clip.insetBy(-2, -2))
        guard !shown.isEmpty else { return .none }
        return .image(ring.cropped(to: shown.offsetBy(-r.x, -r.y)), at: shown.origin)
    }

    /// The room's standard ring round a canvas rect (a drawer's pull, the cubby's mouth).
    static func ring(around r: ArtRect) -> HoverStyle {
        let rr = r.insetBy(-1, -1)
        var c = PixelCanvas(width: rr.w, height: rr.h)
        c.roundedRectStroke(c.bounds, radius: 2, RoomContent.hoverInk)
        return .image(c.buffer, at: rr.origin)
    }

    /// The outline round an image drawn at `origin` (the body of a piece of furniture).
    static func outline(_ image: PixelBuffer, at origin: ArtPoint) -> HoverStyle {
        .image(image.outlined(RoomContent.hoverInk), at: ArtPoint(origin.x - 1, origin.y - 1))
    }

    /// The part of `r` where `hit` answers `key` — the widest run of columns on any row, as tall as the column
    /// through its middle reaches — so a pointer aimed at its centre picks that mini even where others overlap it.
    static func pickable(_ r: ArtRect, key: TokenKey, hit: (ArtPoint) -> TokenKey?) -> ArtRect? {
        var best: (y: Int, x0: Int, n: Int)?
        for y in r.minY..<r.maxY {
            var x = r.minX
            while x < r.maxX {
                guard hit(ArtPoint(x, y)) == key else {
                    x += 1
                    continue
                }
                let x0 = x
                while x < r.maxX, hit(ArtPoint(x, y)) == key { x += 1 }
                if (best?.n ?? 0) < x - x0 { best = (y, x0, x - x0) }
            }
        }
        guard let b = best else { return nil }
        let cx = b.x0 + b.n / 2
        var y0 = b.y, y1 = b.y + 1
        while y0 > r.minY, hit(ArtPoint(cx, y0 - 1)) == key { y0 -= 1 }
        while y1 < r.maxY, hit(ArtPoint(cx, y1)) == key { y1 += 1 }
        return ArtRect(b.x0, y0, b.n, y1 - y0)
    }

    /// Where a carried token's 16-px icon sits over a mini drawn at `r` (centred on it).
    static func carryOrigin(over r: ArtRect) -> ArtPoint {
        ArtPoint(r.midX - 8, r.midY - 8)
    }

    /// The screen re-renders its own selection (and drops a stale one); subclasses redraw theirs on step/render.
    func selectionMayHaveChanged() {
        context.screen?.refreshIfSelectionChanged()
        selectionChanged()
    }

    /// Hook: the selection may have changed (redraw).
    func selectionChanged() {}

    /// Re-hovers what is under a resting pointer after this element's picture moved (a drawer slid, the chair
    /// rolled), so the hover ring follows it.
    var refreshHover: () -> Void = {}

    // MARK: Show on Desk

    /// Show on Desk pulses `key` when this element holds it.
    func playPulse(_ key: TokenKey) {
        pulse = (key, 0)
        pendingSelect = key
        pulseWait = 0
    }

    /// Advances the pulse: it waits (up to `pulseMaxWait`) for its token to come on show, selects it, then blinks.
    /// True while it runs.
    func stepPulse(_ dt: Double, shown: Set<TokenKey>) -> Bool {
        if let key = pendingSelect {
            guard shown.contains(key) else {
                pulseWait += dt
                if pulseWait >= Self.pulseMaxWait {
                    pulse = nil
                    pendingSelect = nil
                }
                return pulse != nil
            }
            pendingSelect = nil
            context.selection.select(key)
            selectionMayHaveChanged()
        }
        guard let p = pulse else { return false }
        let age = p.age + dt
        if age >= Self.pulseDuration {
            pulse = nil
            pendingSelect = nil
        } else {
            pulse = (p.key, age)
        }
        return true
    }

    func endPulse(shown: Set<TokenKey>) {
        _ = stepPulse(0, shown: shown)
        pulse = nil
        pendingSelect = nil
    }

    /// The tokens drawn selected now: the selection, with Show on Desk's token blinking once on show.
    var drawnSelected: Set<TokenKey> {
        var s = context.selection.keys
        if let p = pulse, pendingSelect == nil {
            if Int(p.age * 4) % 2 == 0 { s.insert(p.key) } else { s.remove(p.key) }
        }
        return s
    }

    /// Tokens drawn in front of their neighbours without being selected (Show on Desk's token between blinks).
    var raisedKeys: Set<TokenKey> {
        pulse.map { [$0.key] } ?? []
    }

    /// Tokens drawn on top of the others (selected or raised), so hit tests find them first.
    var frontKeys: Set<TokenKey> { drawnSelected.union(raisedKeys) }

    /// "Left Riser Drawer, 3 items" for VoiceOver.
    static func containerLabel(_ id: ContainerID, count: Int) -> String {
        "\(MenuSpec.containerTitle(id)), \(countText(count, cap: id.spec))"
    }

    /// "Empty", "3 items", "Full · 14 items".
    static func countText(_ n: Int, cap: ContainerSpec) -> String {
        if n == 0 { return "Empty" }
        if n >= cap.hardCap { return "Full · \(n) items" }
        return n == 1 ? "1 item" : "\(n) items"
    }
}

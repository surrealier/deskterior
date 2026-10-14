import DeskCore
import simd

/// What the `InputRouter` routes into: the room's elements in hit-test order and its shared UI.
protocol GestureTarget: AnyObject {
    /// The front-most hit at `p` and the element that owns it.
    func target(at p: ArtPoint) -> (hit: Hit, element: any DeskElement)?
    /// The pointer is over `hit` now (nil: over nothing interactive); true when the ring changed.
    func setHover(_ hit: Hit?, element: (any DeskElement)?) -> Bool
    /// Shows `spec` as the tooltip (nil hides it); true when something visible changed.
    func setTooltip(_ spec: TooltipSpec?) -> Bool
    /// A gesture no element took (bare wall, empty desk); true when something visible changed.
    func unhandled(_ gesture: Gesture) -> Bool
    /// Right-click: the menu for what is under `p`.
    func menu(at p: SIMD2<Float>, hit: Hit?, element: (any DeskElement)?)
    func key(_ command: KeyCommand) -> Bool
    /// A drag that ended or was cancelled and may still animate home.
    func settle(_ drag: any DragController)
}

/// Turns raw `InputEvent`s into gestures (DESIGN §2.1): hover with a 250 ms tooltip, press and click (⇧/⌘,
/// double-click from the event's click count, but only on the target the first click hit), a drag past 3 art px
/// (at most 4 pt) handed to the pressed element (which may answer with a `DragController`), right-click menus,
/// scroll (also while carrying, to change page), and keys (only Esc while a drag is in hand). Pointer moves only
/// report a change when the hover target changes, so the host renders one frame at a time; the tooltip timer is a
/// deadline the host turns into a one-shot timer (`nextDeadline`, `advance(to:)`), never a running loop.
final class InputRouter {
    static let dragThreshold: Float = 3
    /// The drag threshold never exceeds this many points, so large pixel scales do not feel sticky.
    static let maxDragPoints: Float = 4
    static let tooltipDelay = 0.25
    /// Fling input: velocity averaged over this window, scaled and clamped (DESIGN §2.1 Drag).
    static let velocityWindow = 0.05
    static let velocityScale: Float = 0.8
    static let maxVelocity: Float = 1200

    private struct Press {
        var point: SIMD2<Float>
        var hit: Hit?
        var element: (any DeskElement)?
        var mods: InputEvent.Modifiers
        var clickCount: Int
        /// The press became a drag nobody took: no click on release.
        var declined = false
    }

    private unowned let target: any GestureTarget
    /// Art px a press must travel to become a drag (`dragThreshold`, capped at `maxDragPoints`).
    private(set) var dragDistance = InputRouter.dragThreshold
    private var press: Press?
    /// What the last press hit (element, part, token), so a double-click only counts on the same target.
    private var lastPressTarget: (element: String, part: String?, token: TokenKey?)?
    /// No tooltip until the pointer moves again (after a drop).
    private var tooltipHeld = false
    private(set) var drag: (any DragController)?
    private(set) var hovered: Hit?
    private var hoveredElement: (any DeskElement)?
    private var pendingTooltip: (spec: TooltipSpec, due: Double)?
    private(set) var tooltipShown = false
    private var samples: [(t: Double, p: SIMD2<Float>)] = []
    /// The latest event time seen.
    private(set) var now: Double = 0
    /// Where the pointer last moved (for re-hovering after the content changes under it).
    private var lastPoint: ArtPoint?
    private var lastArt: SIMD2<Float>?
    // MARK: mat
    /// The modifier keys of the last pointer move (a change re-tells the hovered element: `modifiersChanged`).
    private var hoverMods: InputEvent.Modifiers = []

    init(target: any GestureTarget) {
        self.target = target
    }

    /// Adopts the display's points per art px: the drag threshold is 3 art px but at most 4 pt.
    func setPointsPerArtPx(_ points: Double) {
        guard points > 0 else { return }
        dragDistance = min(Self.dragThreshold, Self.maxDragPoints / Float(points))
    }

    /// When the tooltip is due, if one is pending.
    var nextDeadline: Double? { pendingTooltip?.due }

    var isPressed: Bool { press != nil }

    /// Routes one event; true when something visible changed (render a frame).
    @discardableResult
    func handle(_ e: InputEvent) -> Bool {
        now = max(now, e.t)
        if e.kind != .key {
            lastPoint = e.artPixel
            lastArt = e.art
        }
        switch e.kind {
        case .move:
            tooltipHeld = false
            // MARK: mat
            let wasHovered = hovered, modsChanged = e.mods != hoverMods
            hoverMods = e.mods
            var changed = updateHover(e)
            if press == nil, drag == nil, let el = hoveredElement, let h = hovered, modsChanged || h != wasHovered {
                changed = el.modifiersChanged(e.mods, h) || changed
            }
            return changed
        case .down:
            // A drag or press whose mouse-up never came (focus lost mid-gesture) ends here, springing back.
            var changed = cancelAll()
            let t = target.target(at: e.artPixel)
            let hit = t?.hit
            // A second click on something else (the content changed between the clicks) is a first click.
            var count = max(1, e.clickCount)
            if count > 1, let last = lastPressTarget,
               last.element != hit?.element || last.part != hit?.part || last.token != hit?.token {
                count = 1
            }
            lastPressTarget = hit.map { ($0.element, $0.part, $0.token) }
            press = Press(point: e.art, hit: hit, element: t?.element, mods: e.mods, clickCount: count)
            if let t, case .handled = t.element.handle(.press(e.art, e.mods), t.hit) { changed = true }
            return changed
        case .drag:
            return dragged(e)
        case .up:
            return released(e)
        case .rightDown:
            _ = hideTooltip()
            cancelDrag()
            press = nil
            lastPressTarget = nil
            let t = target.target(at: e.artPixel)
            target.menu(at: e.art, hit: t?.hit, element: t?.element)
            return true
        case .scroll:
            guard let t = target.target(at: e.artPixel) else { return false }
            // While carrying, a scroll over the screen pages under the stack (the carry then re-aims).
            if let drag, !(drag is CarrySession) { return false }
            if case .pass = t.element.handle(.scroll(e.art, delta: e.scroll, e.mods), t.hit) { return false }
            drag?.moved(to: e.art, mods: e.mods)
            return true
        case .key:
            guard let command = KeyCommand.from(keyCode: e.keyCode, mods: e.mods) else { return false }
            return key(command)
        }
    }

    /// A keyboard command; Esc first cancels a carry. While a drag is in hand nothing else acts (an undo or a
    /// page change underneath a carry would move the ground it is about to land on).
    @discardableResult
    func key(_ command: KeyCommand) -> Bool {
        if command == .escape, cancelDrag() {
            press = nil
            return true
        }
        guard drag == nil else { return false }
        return target.key(command)
    }

    /// Re-aims a carry in hand at the pointer (the screen under it changed page).
    func reaimDrag() {
        guard let drag, let p = lastArt else { return }
        drag.moved(to: p, mods: [])
    }

    /// Fires the tooltip timer when `time` has reached it; true when something visible changed.
    @discardableResult
    func advance(to time: Double) -> Bool {
        now = max(now, time)
        guard let pending = pendingTooltip, time >= pending.due else { return false }
        pendingTooltip = nil
        tooltipShown = true
        return target.setTooltip(pending.spec)
    }

    /// Drops any press or drag (window lost focus, Pause Desk): carries spring back.
    @discardableResult
    func cancelAll() -> Bool {
        var changed = cancelDrag()
        if let p = press, let e = p.element, let h = p.hit {
            _ = e.handle(.cancelPress, h)
            changed = true
        }
        press = nil
        samples = []
        return hideTooltip() || changed
    }

    /// Re-hovers after the model changed under a resting pointer: a token that moved away loses its ring, and a
    /// tooltip on show follows a rename. True when something visible changed.
    @discardableResult
    func refreshHover() -> Bool {
        guard press == nil, drag == nil, let p = lastPoint else { return false }
        let t = target.target(at: p)
        if t?.hit != hovered {
            return updateHover(InputEvent(.move, art: SIMD2(Float(p.x) + 0.5, Float(p.y) + 0.5), t: now), tooltip: !tooltipHeld)
        }
        guard tooltipShown, let t else { return false }
        let spec = t.element.tooltip(t.hit)
        if spec == nil { tooltipShown = false }
        return target.setTooltip(spec)
    }

    /// Forgets the hover (content rebuilt under it).
    func resetHover() {
        hovered = nil
        hoveredElement = nil
        pendingTooltip = nil
        tooltipShown = false
    }

    // MARK: Private

    /// Hovers what is under `e`; `tooltip` false rings it without arming the tooltip.
    private func updateHover(_ e: InputEvent, tooltip: Bool = true) -> Bool {
        guard press == nil, drag == nil else { return false }
        let t = target.target(at: e.artPixel)
        guard t?.hit != hovered else {
            // The first move after a drop arms the tooltip the drop skipped.
            if tooltip, let t, pendingTooltip == nil, !tooltipShown, let spec = t.element.tooltip(t.hit) {
                pendingTooltip = (spec, e.t + Self.tooltipDelay)
            }
            return false
        }
        var changed = hideTooltip()
        if let old = hoveredElement { changed = old.hover(nil) || changed }
        hovered = t?.hit
        hoveredElement = t?.element
        if let t {
            changed = t.element.hover(t.hit) || changed
            if tooltip, let spec = t.element.tooltip(t.hit) { pendingTooltip = (spec, e.t + Self.tooltipDelay) }
        }
        return target.setHover(t?.hit, element: t?.element) || changed
    }

    private func dragged(_ e: InputEvent) -> Bool {
        if let drag {
            sample(e)
            drag.moved(to: e.art, mods: e.mods)
            return true
        }
        guard var p = press, !p.declined else { return false }
        guard simd_length(e.art - p.point) > dragDistance else { return false }
        let gesture = Gesture.dragBegan(from: p.point, at: e.art, e.mods)
        var response = GestureResponse.pass
        if let el = p.element, let h = p.hit { response = el.handle(gesture, h) }
        if case let .drag(controller) = response {
            drag = controller
            samples = [(e.t, e.art)]
            _ = hideTooltip()
            _ = target.setHover(nil, element: nil)
            if let old = hoveredElement { _ = old.hover(nil) }
            hovered = nil
            hoveredElement = nil
            return true
        }
        p.declined = true
        press = p
        if let el = p.element, let h = p.hit { _ = el.handle(.cancelPress, h) }
        return true
    }

    private func released(_ e: InputEvent) -> Bool {
        if let d = drag {
            sample(e)
            d.ended(at: e.art, velocity: velocity(), mods: e.mods)
            target.settle(d)
            drag = nil
            press = nil
            samples = []
            // Ring what is under the pointer now, but no tooltip until it moves (it would cover the drop).
            tooltipHeld = true
            _ = updateHover(InputEvent(.move, art: e.art, mods: e.mods, t: e.t), tooltip: false)
            return true
        }
        guard let p = press else { return false }
        press = nil
        if p.declined { return false }
        let gesture = Gesture.click(e.art, p.mods, count: p.clickCount)
        if let el = p.element, let h = p.hit, case .handled = el.handle(gesture, h) { return true }
        _ = target.unhandled(gesture)
        return true
    }

    @discardableResult
    private func cancelDrag() -> Bool {
        guard let d = drag else { return false }
        d.cancelled()
        target.settle(d)
        drag = nil
        samples = []
        return true
    }

    private func hideTooltip() -> Bool {
        pendingTooltip = nil
        guard tooltipShown else { return false }
        tooltipShown = false
        return target.setTooltip(nil)
    }

    private func sample(_ e: InputEvent) {
        samples.append((e.t, e.art))
        samples.removeAll { e.t - $0.t > Self.velocityWindow }
    }

    /// Release velocity: the average over the last 50 ms, × 0.8, clamped to 1200 art px/s.
    private func velocity() -> SIMD2<Float> {
        guard let first = samples.first, let last = samples.last, last.t > first.t else { return .zero }
        var v = (last.p - first.p) / Float(last.t - first.t) * Self.velocityScale
        let speed = simd_length(v)
        if speed > Self.maxVelocity { v *= Self.maxVelocity / speed }
        return v
    }
}

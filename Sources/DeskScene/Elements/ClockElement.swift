import DeskCore
import Foundation
import SpriteKit

/// The wall clock (DESIGN §2.2 E13). It shows the real time, re-rendered at minute boundaries by the scene's
/// one-shot minute timer (no running loop). Dragging on the face turns the minute hand (the hand jumps to where the
/// face was grabbed, then follows the pointer round, an hour per turn) to preview another time: the phase, sky,
/// window, wallpaper and light follow live through `SceneLightOverrides.previewTime` (under Auto; a forced Day,
/// Night or Lamp Only keeps its phase; past midnight the calendar turns too). On release the preview first drops
/// whole hours, so the hands spring back the short way round the dial (at most half a turn, the light jumping most
/// of the way at once) over 0.5 s, overshooting a little; with Reduce Motion they jump back.
public final class ClockElement: DeskElement {
    public let id = "clock"
    public let root = SKNode()
    unowned let context: SceneContext
    let placed: () -> PlacedElement?
    /// Minutes the hands are turned ahead (+) or back (−) of `base` while previewing; nil shows the real time.
    public private(set) var offset: Double?
    /// The real time when the preview began.
    private var base = WallTime(hour: 0, minute: 0)
    /// The spring back after a release: where it started and how long it has run.
    private var spring: (from: Double, t: Double)?

    static let springDuration = 0.5
    /// `easeOutBack`'s overshoot constant: the hands swing about 5 % past the real time (at most a minute and a
    /// half from half a turn away) and settle.
    static let overshoot = 1.2

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
    }

    public func layout(_ layout: SceneLayout) {}

    /// The time the face shows.
    var shownTime: WallTime { context.lightOverrides.previewTime ?? context.lightOverrides.clockTime }

    /// The hands' pivot in canvas px (continuous).
    var pivot: SIMD2<Double> {
        let r = context.layout.rect(CoreLayout.clock)
        return SIMD2(Double(r.x) + 14, Double(r.y) + 14)
    }

    /// The minute (0..<60, fractional) the minute hand points at when aimed at `p`; nil within 2 px of the pivot.
    func minute(at p: SIMD2<Float>) -> Double? {
        let d = SIMD2<Double>(Double(p.x), Double(p.y)) - pivot
        guard (d * d).sum() >= 4 else { return nil }
        var a = atan2(d.x, -d.y)
        if a < 0 { a += 2 * .pi }
        return a / (2 * .pi) * 60
    }

    public func hitTest(_ p: ArtPoint) -> Hit? {
        placed()?.hitTest(p).map { Hit(element: id, part: $0.part, rect: $0.rect) }
    }

    public func hoverStyle(_ hit: Hit) -> HoverStyle {
        RoomContent.silhouetteRing(placed())
    }

    public func tooltip(_ hit: Hit) -> TooltipSpec? {
        TooltipSpec(title: "Clock", detail: Self.text(shownTime), anchor: hit.rect)
    }

    static func text(_ t: WallTime) -> String {
        String(format: "%02d:%02d", t.hour, t.minute)
    }

    public func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        switch gesture {
        case .press, .cancelPress, .click:
            return .handled
        case let .dragBegan(from, at, mods):
            let drag = beginPreview()
            drag.moved(to: from, mods: mods)
            drag.moved(to: at, mods: mods)
            return .drag(drag)
        case .scroll:
            return .pass
        }
    }

    /// Starts (or, mid spring-back, resumes) a preview and hands back the drag that turns the hand.
    func beginPreview() -> ClockHandDrag {
        if offset == nil {
            base = context.lightOverrides.clockTime
            offset = 0
        }
        spring = nil
        let shown = (Double(base.minute) + (offset ?? 0)).truncatingRemainder(dividingBy: 60)
        return ClockHandDrag(clock: self, minute: shown < 0 ? shown + 60 : shown)
    }

    /// Turns the minute hand by `minutes` (positive: clockwise).
    func turn(by minutes: Double) {
        guard let o = offset else { return }
        offset = o + minutes
        publish()
    }

    /// The hand was let go: spring back to the real time (at once with Reduce Motion). Whole hours drop at once, so
    /// the minute hand only swings the short way round (a long preview would spin it many turns in 0.5 s, strobing,
    /// and flash the light through every phase on the way).
    func release() {
        guard let o = offset else { return }
        let short = Self.shortWay(o)
        if context.reduceMotion || short.rounded() == 0 {
            offset = nil
            spring = nil
        } else {
            offset = short
            spring = (short, 0)
        }
        publish()
    }

    /// `minutes` less whole hours: the same minute-hand angle, at most 30 minutes either way.
    static func shortWay(_ minutes: Double) -> Double {
        minutes - 60 * (minutes / 60).rounded()
    }

    /// Hands the preview time to the room (nil: the real time).
    private func publish() {
        guard let o = offset else {
            context.lightOverrides.previewTime = nil
            return
        }
        let minutes = base.minuteOfDay + Int(o.rounded())
        let days = Int((Double(minutes) / 1440).rounded(.down))
        let total = minutes - days * 1440
        context.lightOverrides.previewTime = Self.date(of: base, plusDays: days, hour: total / 60, minute: total % 60)
    }

    /// `t`'s date `days` later (or earlier) at `hour:minute`: a preview past midnight turns the calendar.
    static func date(of t: WallTime, plusDays days: Int, hour: Int, minute: Int) -> WallTime {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
        guard days != 0, let day = cal.date(from: DateComponents(year: t.year, month: t.month, day: t.day)),
              let moved = cal.date(byAdding: .day, value: days, to: day)
        else { return WallTime(year: t.year, month: t.month, day: t.day, hour: hour, minute: minute) }
        let c = cal.dateComponents([.year, .month, .day], from: moved)
        return WallTime(year: c.year ?? t.year, month: c.month ?? t.month, day: c.day ?? t.day, hour: hour, minute: minute)
    }

    /// `easeOutBack`: 0 → 1 with a small overshoot before it settles.
    static func easeOutBack(_ u: Double) -> Double {
        let c1 = overshoot, c3 = c1 + 1, v = u - 1
        return 1 + c3 * v * v * v + c1 * v * v
    }

    public func accessibilityItems() -> [AXItem] {
        [AXItem(id: "clock", label: "Clock, \(Self.text(shownTime))", role: .group,
                frame: context.layout.rect(CoreLayout.clock))]
    }

    public var needsFrames: Bool { spring != nil }

    public func step(_ dt: Double) {
        guard let s = spring else { return }
        let t = s.t + dt
        if t + 1e-9 >= Self.springDuration {
            settle()
            return
        }
        spring = (s.from, t)
        offset = s.from * (1 - Self.easeOutBack(t / Self.springDuration))
        publish()
    }

    public func settle() {
        guard spring != nil else { return }
        spring = nil
        offset = nil
        publish()
    }
}

/// A drag on the clock face: each move turns the minute hand by the shortest way to the pointer's angle, so
/// going round keeps counting hours.
final class ClockHandDrag: DragController {
    unowned let clock: ClockElement
    /// The minute the hand points at (0..<60).
    private var last: Double
    private(set) var isFinished = false

    init(clock: ClockElement, minute: Double) {
        self.clock = clock
        last = minute
    }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished, let m = clock.minute(at: p) else { return }
        var d = m - last
        if d > 30 { d -= 60 } else if d <= -30 { d += 60 }
        last = m
        clock.turn(by: d)
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        moved(to: p, mods: mods)
        isFinished = true
        clock.release()
    }

    func cancelled() {
        isFinished = true
        clock.release()
    }

    func step(_ dt: Double) {}
    var needsFrames: Bool { false }
}

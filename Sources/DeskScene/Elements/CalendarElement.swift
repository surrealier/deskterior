import DeskCore
import Foundation
import SpriteKit

/// The wall calendar (Erratum 31): the room draws it for the month it shows, today red, days with a page or a dated
/// note marked blue and the D-Day purple (`RoomState.calendarMarks`, refreshed on the minute path and with the memos).
/// Each day of the month is a hit cell (`RoomArt.calendarDayRect(day:in:)`, the drawing's own geometry): hover rings
/// it and names the day ("Sun 18 · memo · 2 notes"; the memo's first line too, only where the light reaches), and a
/// click opens that day in the Memos window; a click elsewhere on the calendar opens today. Months turn only in the
/// window. Its tooltip's title is the month ("October 2026" / "2026년 10월").
final class CalendarElement: DeskElement {
    let id = "calendar"
    let root = SKNode()
    unowned let context: SceneContext
    /// The room's placed calendar (its sprite and alpha hit tests).
    let placed: () -> PlacedElement?
    private(set) var state: DeskState?

    static let dayPrefix = "calendar.day."

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
    }

    // MARK: Geometry

    var rect: ArtRect { context.layout.rect(CoreLayout.calendar) }
    /// The month the calendar shows (the room's time, which a clock preview turns).
    var shown: WallTime { context.shownTime }

    /// Day `day`'s cell in canvas px (nil for a day not in the month shown).
    func dayRect(_ day: Int) -> ArtRect? {
        RoomArt.calendarDayRect(day: day, in: shown).map { $0.offsetBy(rect.x, rect.y) }
    }

    /// The day whose cell holds canvas point `p`.
    func day(at p: ArtPoint) -> Int? {
        RoomArt.calendarDay(at: ArtPoint(p.x - rect.x, p.y - rect.y), in: shown)
    }

    /// The day a part names ("calendar.day.18").
    static func day(_ part: String?) -> Int? {
        guard let part, part.hasPrefix(dayPrefix) else { return nil }
        return Int(part.dropFirst(dayPrefix.count))
    }

    func dayKey(_ day: Int) -> DayKey? { DayKey(year: shown.year, month: shown.month, day: day) }

    // MARK: DeskElement

    func layout(_ layout: SceneLayout) {}

    func apply(_ s: DeskState) { state = s }

    func hitTest(_ p: ArtPoint) -> Hit? {
        guard placed()?.hitTest(p) != nil else { return nil }
        if let d = day(at: p), let r = dayRect(d) { return Hit(element: id, part: Self.dayPrefix + String(d), rect: r) }
        return Hit(element: id, part: id, rect: rect)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        Self.day(hit.part) == nil ? RoomContent.silhouetteRing(placed()) : ContainerElement.ring(around: hit.rect)
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        var spec = TooltipSpec(title: Self.monthTitle(shown), anchor: hit.rect)
        if let d = Self.day(hit.part), let key = dayKey(d) {
            spec.detail = dayDetail(key, lit: context.isLit(rect))
        }
        return spec
    }

    /// "Sun 18 · memo · 2 notes": the day, then what is on it (the memo's first line instead of "memo" when lit, the
    /// D-Day's name when lit).
    func dayDetail(_ day: DayKey, lit: Bool) -> String {
        var parts = [Self.dayName(day)]
        guard let s = state else { return parts[0] }
        if let page = s.memos.pages[day], !page.isEmpty {
            parts.append(lit ? NoteSprite.textLines(page).first ?? L10n.text(.memoWord) : L10n.text(.memoWord))
        }
        let notes = s.memos.notes(on: day).count
        if notes == 1 { parts.append(L10n.text(.oneNote)) }
        if notes > 1 { parts.append(L10n.format(.notesCount, [notes])) }
        if let d = s.memos.dDay, d.day == day, lit, !d.title.isEmpty { parts.append(L10n.format(.dDayNamed, [d.title])) }
        return parts.joined(separator: " · ")
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard state != nil else { return .pass }
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case let .click(_, _, count):
            guard count == 1 else { return .handled }
            if let d = Self.day(hit.part), let key = dayKey(d) {
                context.request(.command(.openMemos(.day(key))))
            } else {
                context.request(.command(.openMemos(.today)))
            }
            return .handled
        case .dragBegan, .scroll:
            return .pass
        }
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard let s = state else { return nil }
        return MenuSpec.calendar(s, context.menuContextNow, day: Self.day(hit.part).flatMap(dayKey))
    }

    /// "Calendar, October 2026, 3 days with memos" over the calendar's header, so a press opens today.
    func accessibilityItems() -> [AXItem] {
        guard let s = state else { return [] }
        let marked = s.memos.marks(year: shown.year, month: shown.month).count
        return [AXItem(id: id, label: L10n.format(.axCalendar, [Self.monthTitle(shown), marked]), role: .button,
                       frame: headerRect)]
    }

    /// The calendar's paper above its day grid (the month's name).
    var headerRect: ArtRect { ArtRect(rect.x, rect.y + 4, rect.w, 10) }

    // MARK: Words

    /// "October 2026" / "2026년 10월".
    static func monthTitle(_ t: WallTime) -> String {
        format(DayKey(t), template: "MMMMy")
    }

    /// "Sun 18" / "18일 (일)".
    static func dayName(_ d: DayKey) -> String {
        L10n.language == .en ? "\(format(d, template: "EEE")) \(d.day)" : format(d, template: "dEEE")
    }

    private static func format(_ d: DayKey, template: String) -> String {
        PartitionElement.dateText(d, template)
    }
}

import DeskCore
import Foundation
import Testing
@testable import DeskScene

/// The wall calendar (Erratum 31): day cells, marks, a click per day.
@Suite("Calendar element")
struct CalendarElementTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture
    typealias M = MemoFixture

    static func calendar(_ scene: DeskScene) throws -> CalendarElement {
        try #require(try C.room(scene).calendarElement)
    }

    @Test("Every day's cell hits that day, as the art draws it; the scene's cell rects are the art's, moved onto the canvas")
    func cellMath() throws {
        for (month, day) in [(10, 14), (2, 1), (8, 31)] {
            let scene = F.scene(M.state(), time: WallTime(year: 2026, month: month, day: day, hour: 10, minute: 0))
            let calendar = try Self.calendar(scene)
            let layout = try #require(scene.layout)
            let shown = WallTime(year: 2026, month: month, day: day, hour: 10, minute: 0)
            let origin = layout.rect(CoreLayout.calendar).origin
            for d in 1...shown.daysInMonth {
                let cell = try #require(scene.calendarDayRect(d), "day \(d) of \(month)")
                let art = try #require(RoomArt.calendarDayRect(day: d, in: shown))
                #expect(cell == art.offsetBy(origin.x, origin.y))
                let hit = scene.hitTest(cell.center)
                #expect(hit?.element == "calendar" && hit?.part == "calendar.day.\(d)", "day \(d): \(String(describing: hit))")
                #expect(calendar.day(at: cell.center) == d)
            }
            #expect(scene.calendarDayRect(shown.daysInMonth + 1) == nil)
            #expect(scene.hitTest(calendar.headerRect.center)?.part == "calendar")
        }
    }

    @Test("Marks follow the memos and the month the room shows; at midnight they turn with the minute path")
    func marksAtMidnight() throws {
        let nov1 = DayKey(year: 2026, month: 11, day: 1)!
        let s = M.state(pages: [nov1: "first of the month", M.today: "today"])
        let scene = F.scene(s, time: WallTime(year: 2026, month: 10, day: 31, hour: 23, minute: 59))
        let room = try C.room(scene)
        func calendarImage() -> PixelBuffer? {
            room.elements.first { $0.id == "calendar" }?.placements.first { $0.id == "calendar" }?.image
        }
        let before = calendarImage()
        #expect(scene.roomState?.calendarMarks == [14: .memo])
        scene.clock = .fixed(WallTime(year: 2026, month: 11, day: 1, hour: 0, minute: 0))
        #expect(scene.roomState?.calendarMarks == [1: .memo])
        #expect(calendarImage() != before)
        // A memo written today marks it at once.
        var t = s
        t.memos.pages[nov1] = nil
        t.memos.notes[NoteID(1)] = M.note(1, at: M.tower, day: DayKey(year: 2026, month: 11, day: 5)!)
        scene.apply(t)
        #expect(scene.roomState?.calendarMarks == [5: .note])
    }

    @Test("A click on a day opens that day; elsewhere on the calendar, today")
    func requests() throws {
        let store = SceneStore(M.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let calendar = try Self.calendar(scene)
        p.click(F.centre(try #require(scene.calendarDayRect(30))))
        #expect(store.requests.last == .command(.openMemos(.day(DayKey(year: 2026, month: 10, day: 30)!))))
        p.click(F.centre(calendar.headerRect))
        #expect(store.requests.last == .command(.openMemos(.today)))
    }

    @Test("The element straight: a cell's part names its day for the click and the menu")
    func requestsStraight() throws {
        let store = SceneStore(M.state())
        let scene = store.scene
        let calendar = try Self.calendar(scene)
        _ = calendar.handle(.click(.zero, [], count: 1), Hit(element: "calendar", part: "calendar", rect: .zero))
        #expect(store.requests.last == .command(.openMemos(.today)))
        let hit = Hit(element: "calendar", part: "calendar.day.3", rect: .zero)
        _ = calendar.handle(.click(.zero, [], count: 1), hit)
        #expect(store.requests.last == .command(.openMemos(.day(DayKey(year: 2026, month: 10, day: 3)!))))
        let day = DayKey(year: 2026, month: 10, day: 3)
        #expect(calendar.menu(hit) == MenuSpec.calendar(store.state, scene.menuContextWithToday, day: day))
    }

    @Test("The month titles the tooltip; a day's detail names what is on it, and drops the memo's text in the dark")
    func tooltips() throws {
        var s = M.state([M.note(1, at: M.tower, day: M.today), M.note(2, at: M.tower2, day: M.today)],
                        pages: [M.today: "회의 3시\n자료"], dDay: DDay(day: M.today, title: "시험"))
        s.monitor.power = .off
        let scene = F.scene(s)
        let calendar = try Self.calendar(scene)
        let hit = Hit(element: "calendar", part: "calendar.day.14", rect: calendar.rect)
        let spec = try #require(calendar.tooltip(hit))
        #expect(spec.title == "October 2026")
        #expect(spec.detail == "Wed 14 · 회의 3시 · 2 notes · D-Day: 시험")
        #expect(calendar.dayDetail(M.today, lit: false) == "Wed 14 · memo · 2 notes")
        #expect(calendar.tooltip(Hit(element: "calendar", part: "calendar", rect: calendar.rect))?.detail == nil)
        let items = calendar.accessibilityItems()
        #expect(items.map(\.label) == ["Calendar, October 2026, 1 days with memos"] && items.first?.role == .button)
        // In Lamp Only the calendar is dark: the day keeps the user's text to itself.
        scene.clock = .fixed(WallTime(hour: 22, minute: 0))
        scene.lightsMode = .lampOnly
        #expect(calendar.tooltip(hit)?.detail == "Wed 14 · memo · 2 notes")
    }

    @Test("Golden: the calendar with a memo, a dated note and the D-Day marked")
    func golden() throws {
        let s = M.state([M.note(1, at: M.tower, day: DayKey(year: 2026, month: 10, day: 22)!)],
                        pages: [DayKey(year: 2026, month: 10, day: 3)!: "x"],
                        dDay: DDay(day: DayKey(year: 2026, month: 10, day: 30)!, title: "D"))
        let scene = F.scene(s)
        let room = try C.room(scene)
        let image = try #require(room.elements.first { $0.id == "calendar" }?.placements.first { $0.id == "calendar" }?.image)
        #expect(Golden.match(image, "calendar-marks"))
    }
}

extension DeskScene {
    /// The menu context the scene's own menus use (today filled in).
    var menuContextWithToday: MenuSpec.Context {
        var c = menuContext
        if c.today == nil { c.today = DayKey(clock.now()) }
        return c
    }
}

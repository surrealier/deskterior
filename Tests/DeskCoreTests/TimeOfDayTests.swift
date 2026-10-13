import Testing
@testable import DeskCore

@Suite("Time of day")
struct TimeOfDayTests {
    /// (HH:MM, phase, ambient with the room light on, ambient with it off) — DESIGN §1.4.
    static let table: [(String, DayPhase, (Int, Tint), (Int, Tint))] = [
        ("00:00", .night, (6, .warm), (1, .cool)),
        ("05:59", .night, (6, .warm), (1, .cool)),
        ("06:00", .dawn, (7, .cool), (3, .cool)),
        ("06:45", .dawn, (7, .cool), (4, .cool)),
        ("07:59", .dawn, (7, .cool), (5, .cool)),
        ("08:00", .day, (7, .cool), (6, .cool)),
        ("12:30", .day, (7, .cool), (6, .cool)),
        ("16:59", .day, (7, .cool), (6, .cool)),
        ("17:00", .dusk, (7, .cool), (5, .cool)),
        ("17:45", .dusk, (7, .cool), (4, .cool)),
        ("18:59", .dusk, (7, .cool), (3, .cool)),
        ("19:00", .night, (6, .warm), (1, .cool)),
        ("22:00", .night, (6, .warm), (1, .cool)),
        ("23:59", .night, (6, .warm), (1, .cool)),
    ]

    @Test("Phase and ambient table")
    func phaseTable() throws {
        for (clock, phase, on, off) in Self.table {
            let t = try #require(WallTime(parsing: clock))
            let lit = TimeOfDay(t, roomLightOn: true), dark = TimeOfDay(t, roomLightOn: false)
            #expect(lit.phase == phase, "\(clock)")
            #expect(lit.ambientLevel == on.0 && lit.ambientTint == on.1, "\(clock) light on")
            #expect(dark.ambientLevel == off.0 && dark.ambientTint == off.1, "\(clock) light off")
        }
    }

    @Test("Sky follows the phase; Lights modes force it")
    func skyAndModes() throws {
        let night = try #require(WallTime(parsing: "22:00"))
        let noon = try #require(WallTime(parsing: "12:00"))
        #expect(TimeOfDay(noon, roomLightOn: true).sky == .day)
        #expect(TimeOfDay(night, roomLightOn: true).sky == .night)
        #expect(TimeOfDay(try #require(WallTime(parsing: "18:00")), roomLightOn: true).sky == .dusk)
        #expect(TimeOfDay(try #require(WallTime(parsing: "07:00")), roomLightOn: true).sky == .dawn)
        #expect(TimeOfDay(night, mode: .day, roomLightOn: true).phase == .day)
        #expect(TimeOfDay(noon, mode: .night, roomLightOn: true).ambientLevel == 6)
        let lamp = TimeOfDay(noon, mode: .lampOnly, roomLightOn: true)
        #expect(lamp.phase == .night && !lamp.roomLightOn && lamp.ambientLevel == 1)
        #expect(RoomLightState(lampOn: false, roomLightOn: true).applying(.lampOnly) == RoomLightState(lampOn: true, roomLightOn: false))
        #expect(LightsMode(rawValue: "lamp") == .lampOnly)
        #expect(TimeOfDay(noon, roomLightOn: true).isDark == false)
        #expect(TimeOfDay(night, roomLightOn: true).isDark)
    }

    @Test("Phase progress runs 0…1 through each phase, across midnight for night")
    func progress() {
        #expect(TimeOfDay.phase(minuteOfDay: 360).progress == 0)
        #expect(TimeOfDay.phase(minuteOfDay: 420).progress == 0.5)
        #expect(TimeOfDay.phase(minuteOfDay: 1140).phase == .night && TimeOfDay.phase(minuteOfDay: 1140).progress == 0)
        #expect(TimeOfDay.phase(minuteOfDay: 0).progress == 300.0 / 660)
        #expect(TimeOfDay.phase(minuteOfDay: 1440 + 600).phase == .day)
        #expect(TimeOfDay.phase(minuteOfDay: -60).phase == .night)
    }

    @Test("--clock parsing: HH:MM keeps the given date; ISO 8601 carries its own")
    func parsing() throws {
        let today = WallTime(year: 2026, month: 10, day: 14, hour: 9, minute: 5)
        #expect(WallTime(parsing: "22:07", date: today) == WallTime(year: 2026, month: 10, day: 14, hour: 22, minute: 7))
        #expect(WallTime(parsing: "7:30")?.hour == 7)
        #expect(WallTime(parsing: "2025-12-24T18:30") == WallTime(year: 2025, month: 12, day: 24, hour: 18, minute: 30))
        #expect(WallTime(parsing: "2025-12-24T18:30:15Z")?.minute == 30)
        #expect(WallTime(parsing: "2025-12-24T18:30:15+09:00")?.hour == 18)
        for bad in ["", "24:00", "12:60", "12", "12:5", "noon", "2025-13-01T10:00", "10:00x", "2025-12-24"] {
            #expect(WallTime(parsing: bad) == nil, "accepted \(bad)")
        }
    }

    @Test("Calendar arithmetic: weekdays and month lengths")
    func calendar() {
        #expect(WallTime(year: 2026, month: 10, day: 14, hour: 0, minute: 0).weekday == 3)   // Wednesday
        #expect(WallTime(year: 2026, month: 10, day: 1, hour: 0, minute: 0).weekday == 4)    // Thursday
        #expect(WallTime(year: 2024, month: 2, day: 29, hour: 0, minute: 0).weekday == 4)
        #expect(WallTime(year: 2024, month: 2, day: 1, hour: 0, minute: 0).daysInMonth == 29)
        #expect(WallTime(year: 2100, month: 2, day: 1, hour: 0, minute: 0).daysInMonth == 28)
        #expect(WallTime(year: 2026, month: 9, day: 1, hour: 0, minute: 0).daysInMonth == 30)
        #expect(WallTime(hour: 25, minute: -1) == WallTime(hour: 1, minute: 59))
        #expect(WallTime(hour: 22, minute: 5).description == "2026-10-14 22:05")
    }
}

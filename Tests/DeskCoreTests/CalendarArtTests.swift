import Testing
@testable import DeskCore

/// The wall calendar's day cells and marks (Erratum 31): the hit math inverts the drawing, and marked days wear blue or
/// purple while today keeps its red block.
@Suite("Calendar art")
struct CalendarArtTests {
    static let months: [WallTime] = (2025...2027).flatMap { y in
        (1...12).map { WallTime(year: y, month: $0, day: 1, hour: 10, minute: 0) }
    }

    @Test("Every day's cell maps back to that day, cells tile the grid, nothing else hits (2025–2027)")
    func cellsInvert() {
        let size = CoreLayout.calendar.size
        var pitches: Set<Int> = []
        for month in Self.months {
            var owner: [ArtPoint: Int] = [:]
            for day in 1...month.daysInMonth {
                guard let cell = RoomArt.calendarDayRect(day: day, in: month) else {
                    Issue.record("no cell for \(month) day \(day)")
                    continue
                }
                #expect(ArtRect(0, 0, size.w, size.h).contains(cell), "\(month) \(day) \(cell)")
                #expect(cell.w == 4 && (cell.h == 3 || cell.h == 4))
                pitches.insert(cell.h)
                for y in cell.minY..<cell.maxY {
                    for x in cell.minX..<cell.maxX {
                        let p = ArtPoint(x, y)
                        #expect(owner[p] == nil, "cells overlap at \(p)")
                        owner[p] = day
                        #expect(RoomArt.calendarDay(at: p, in: month) == day, "\(month) \(p)")
                    }
                }
            }
            for y in -2..<(size.h + 2) {
                for x in -2..<(size.w + 2) where owner[ArtPoint(x, y)] == nil {
                    #expect(RoomArt.calendarDay(at: ArtPoint(x, y), in: month) == nil, "\(month) (\(x),\(y))")
                }
            }
            #expect(RoomArt.calendarDayRect(day: 0, in: month) == nil)
            #expect(RoomArt.calendarDayRect(day: month.daysInMonth + 1, in: month) == nil)
        }
        #expect(pitches == [3, 4], "both 5- and 6-row months occur")
    }

    @Test("The hit cell holds the day's drawn dash, and today's block is exactly its cell")
    func cellsMatchDrawing() {
        // October 2026 starts on a Thursday (5 rows, pitch 4); August 2026 on a Saturday (6 rows, pitch 3).
        for (month, pitch) in [(10, 4), (8, 3)] {
            let today = WallTime(year: 2026, month: month, day: 14, hour: 10, minute: 0)
            let image = RoomArt.calendar(today).image
            let cell = RoomArt.calendarDayRect(day: 14, in: today)!
            #expect(cell.h == pitch)
            for y in cell.minY..<cell.maxY {
                for x in cell.minX..<cell.maxX {
                    let ink = image.pixel(x, y)
                    #expect(ink == Ink.red4.color || ink == Ink.neutral9.color, "today's block at (\(x),\(y))")
                }
            }
            #expect(image.pixel(cell.x, cell.y) == Ink.red4.color)
            let other = RoomArt.calendarDayRect(day: 20, in: today)!
            #expect(image.pixel(other.x + 1, other.y + 1) != Ink.neutral9.color, "a dash sits one px in")
            #expect(image.pixel(other.x, other.y) == Ink.neutral9.color)
        }
        #expect(RoomArt.calendarDayRect(day: 1, in: WallTime(year: 2026, month: 10, day: 1, hour: 0, minute: 0))
            == ArtRect(1 + 4 * 4, 15, 4, 4))
    }

    @Test("Marks: blue for a page or a dated note, purple for the D-Day (it wins), today unchanged")
    func marks() {
        let today = WallTime(year: 2026, month: 10, day: 18, hour: 10, minute: 0)
        let marks: [Int: CalendarMark] = [3: .memo, 7: .note, 12: [.memo, .dDay], 18: .dDay, 30: .dDay]
        let plain = RoomArt.calendar(today).image
        let marked = RoomArt.calendar(today, marks: marks).image
        func dash(_ image: PixelBuffer, _ day: Int) -> (RGBA8, RGBA8, RGBA8) {
            let c = RoomArt.calendarDayRect(day: day, in: today)!
            return (image.pixel(c.x + 1, c.y + 1), image.pixel(c.x + 2, c.y + 1), image.pixel(c.x + 1, c.y + 2))
        }
        for day in [3, 7] { #expect(dash(marked, day) == (Ink.blue3.color, Ink.blue3.color, Ink.blue2.color)) }
        for day in [12, 30] {
            #expect(dash(marked, day) == (Ink.purple3.color, Ink.purple3.color, Ink.purple2.color))
        }
        #expect(dash(marked, 18) == dash(plain, 18), "today keeps its red block")
        // Only the marked days' cells change.
        for day in 1...today.daysInMonth where [3, 7, 12, 30].contains(day) == false {
            let c = RoomArt.calendarDayRect(day: day, in: today)!
            #expect(marked.cropped(to: c) == plain.cropped(to: c), "day \(day)")
        }
        // A six-row month has no room for the plot under the dash.
        let aug = WallTime(year: 2026, month: 8, day: 31, hour: 10, minute: 0)
        let c = RoomArt.calendarDayRect(day: 5, in: aug)!
        let img = RoomArt.calendar(aug, marks: [5: .note]).image
        #expect(img.pixel(c.x + 1, c.y + 1) == Ink.blue3.color && img.pixel(c.x + 1, c.y + 2) == Ink.neutral9.color)
        #expect(RoomArt.calendar(aug, marks: [5: .note]).size == CoreLayout.calendar.size)
    }
}

import Testing
@testable import DeskCore

/// Multi-display (DESIGN §4.10; M12): where the desk lives, which displays get a wall, what a hot-plug changes, and
/// the walls themselves over the nine §1.2 displays.
@Suite("Displays")
struct DisplayPlanTests {
    static let main = DisplayInfo(id: 1, uuid: "MAIN", frame: PointRect(x: 0, y: 0, width: 1470, height: 956),
                                  visibleFrame: PointRect(x: 0, y: 0, width: 1470, height: 923), hasMenuBar: true)
    static let left = DisplayInfo(id: 2, uuid: "LEFT", frame: PointRect(x: -1920, y: 0, width: 1920, height: 1080),
                                  backingScale: 1)
    static let top = DisplayInfo(id: 3, uuid: "TOP", frame: PointRect(x: 0, y: 956, width: 2560, height: 1440))

    @Test("The desk lives on the chosen display while it is connected, else on the menu-bar display")
    func desk() {
        let screens = [Self.left, Self.main, Self.top]
        #expect(DisplayPlan.make(screens, deskUUID: nil, coverOthers: nil).desk == 1)
        #expect(DisplayPlan.make(screens, deskUUID: "TOP", coverOthers: nil).desk == 3)
        #expect(DisplayPlan.make(screens, deskUUID: "GONE", coverOthers: nil).desk == 1)
        // No display claims the menu bar (mirroring, a transient): the first one.
        var plain = Self.main
        plain.hasMenuBar = false
        #expect(DisplayPlan.make([Self.left, plain], deskUUID: nil, coverOthers: nil).desk == 2)
        #expect(DisplayPlan.make([], deskUUID: nil, coverOthers: true) == DisplayPlan(desk: nil, walls: []))
    }

    @Test("Walls only after the user said Cover; the cover prompt only with several displays, once")
    func walls() {
        let screens = [Self.main, Self.left, Self.top]
        #expect(DisplayPlan.make(screens, deskUUID: nil, coverOthers: nil).walls.isEmpty)
        #expect(DisplayPlan.make(screens, deskUUID: nil, coverOthers: false).walls.isEmpty)
        #expect(DisplayPlan.make(screens, deskUUID: nil, coverOthers: true).walls == [2, 3])
        #expect(DisplayPlan.make(screens, deskUUID: "LEFT", coverOthers: true).walls == [1, 3])
        #expect(DisplayPlan.needsCoverPrompt(screenCount: 2, coverOthers: nil))
        #expect(!DisplayPlan.needsCoverPrompt(screenCount: 1, coverOthers: nil))
        #expect(!DisplayPlan.needsCoverPrompt(screenCount: 3, coverOthers: false))
    }

    @Test("Hot-plug: a new display gets a wall, an unplugged one loses it, the desk follows its display away")
    func hotplug() {
        let one = [Self.main]
        let p1 = DisplayPlan.make(one, deskUUID: nil, coverOthers: true)
        let two = [Self.main, Self.left]
        let p2 = DisplayPlan.make(two, deskUUID: nil, coverOthers: true)
        var c = DisplayChange.between(old: p1, oldScreens: one, new: p2, screens: two)
        #expect(c.addWalls == [2] && c.removeWalls.isEmpty && c.moveDesk == nil && !c.resizeDesk)
        c = DisplayChange.between(old: p2, oldScreens: two, new: p1, screens: one)
        #expect(c.removeWalls == [2] && c.addWalls.isEmpty)
        // The desk was on LEFT; LEFT goes away: back to the menu-bar display, and MAIN's wall goes.
        let onLeft = DisplayPlan.make(two, deskUUID: "LEFT", coverOthers: true)
        #expect(onLeft == DisplayPlan(desk: 2, walls: [1]))
        let after = DisplayPlan.make(one, deskUUID: "LEFT", coverOthers: true)
        c = DisplayChange.between(old: onLeft, oldScreens: two, new: after, screens: one)
        #expect(c.moveDesk == 1 && c.removeWalls == [1] && c.addWalls.isEmpty)
        // Nothing changed.
        #expect(DisplayChange.between(old: p2, oldScreens: two, new: p2, screens: two).isEmpty)
    }

    @Test("A resolution or Dock change resizes in place")
    func resize() {
        let screens = [Self.main, Self.left]
        let plan = DisplayPlan.make(screens, deskUUID: nil, coverOthers: true)
        var main = Self.main
        main.visibleFrame = PointRect(x: 0, y: 70, width: 1470, height: 853)  // the Dock appeared
        var left = Self.left
        left.frame = PointRect(x: -2560, y: 0, width: 2560, height: 1440)
        let c = DisplayChange.between(old: plan, oldScreens: screens, new: plan, screens: [main, left])
        #expect(c.resizeDesk && c.resizeWalls == [2] && c.moveDesk == nil && c.addWalls.isEmpty)
    }

    @Test("A display's geometry: insets from its visible frame")
    func geometry() {
        let g = Self.main.geometry
        #expect(g.frameWidthPx == 2940 && g.frameHeightPx == 1912)
        #expect(g.visibleRectPx == DeviceRect(0, 66, 2940, 1846))
    }

    @Test("Walls over the nine §1.2 displays: the desk's canvas, its floor line, only Apollo colours, lit by the hour",
          arguments: pixelGridDesignTable)
    func wallSizes(_ row: PixelGridTableRow) {
        let grid = PixelGrid(display: row.display())
        #expect(grid.scale == row.scale)
        let layout = LayoutSolver.solve(grid: grid)
        let day = RoomState(time: WallTime(hour: 10, minute: 0))
        let night = RoomState(time: WallTime(hour: 22, minute: 0))
        let a = WallArt.render(grid: grid, state: day)
        let b = WallArt.render(grid: grid, state: night)
        #expect(a.size == grid.artSize && b.size == grid.artSize)
        #expect(a.pixels.allSatisfy { Apollo.index(of: $0) != nil }, "day wall has foreign colours")
        #expect(b.pixels.allSatisfy { Apollo.index(of: $0) != nil }, "night wall has foreign colours")
        #expect(a != b, "the night wall is darker")
        // The wall meets the floor where the desk's room does, so the displays line up.
        let unlit = WallArt.compose(layout, day)
        let room = RoomArt.backdrop(layout)
        let x = 2, y = layout.wallBaseY
        #expect(unlit.pixel(x, y - 1) == room.pixel(x, y - 1) && unlit.pixel(x, y + 1) == room.pixel(x, y + 1))
        #expect(WallArt.signature(grid: grid, state: day) != WallArt.signature(grid: grid, state: night))
        #expect(WallArt.signature(grid: grid, state: day)
            == WallArt.signature(grid: grid, state: RoomState(time: WallTime(hour: 10, minute: 30))))
    }
}

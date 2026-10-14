import Foundation

/// A rectangle in points (AppKit screen frames, window-list bounds); DeskCore has no CoreGraphics.
public struct PointRect: Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The overlap (empty when there is none).
    public func intersection(_ r: PointRect) -> PointRect {
        let x0 = max(minX, r.minX), y0 = max(minY, r.minY)
        let x1 = min(maxX, r.maxX), y1 = min(maxY, r.maxY)
        return PointRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public var description: String { "[\(x),\(y) \(width)x\(height)]pt" }
}

/// One connected display as the app sees it (DESIGN §4.10): `NSScreenNumber`, the persistent UUID
/// (`CGDisplayCreateUUIDFromDisplayID`), frames in global points (AppKit, y-up) and whether it holds the menu bar.
public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32
    public var uuid: String?
    public var frame: PointRect
    public var visibleFrame: PointRect
    public var backingScale: Double
    public var hasMenuBar: Bool

    public init(id: UInt32, uuid: String? = nil, frame: PointRect, visibleFrame: PointRect? = nil, backingScale: Double = 2,
                hasMenuBar: Bool = false) {
        self.id = id
        self.uuid = uuid
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.backingScale = backingScale
        self.hasMenuBar = hasMenuBar
    }

    /// The geometry the `PixelGrid` of this display sees (insets from `visibleFrame`).
    public var geometry: DisplayGeometry {
        DisplayGeometry(
            widthPt: frame.width, heightPt: frame.height, backingScale: backingScale,
            topInsetPt: frame.maxY - visibleFrame.maxY, bottomInsetPt: visibleFrame.minY - frame.minY,
            leftInsetPt: visibleFrame.minX - frame.minX, rightInsetPt: frame.maxX - visibleFrame.maxX
        )
    }
}

/// Which display holds the desk and which get a wall (DESIGN §4.10, §4.8 `deskDisplayUUID`/`coverOtherDisplays`):
/// the desk lives on the chosen display while it is connected, else on the menu-bar display (the first one listed
/// when none says so); every other display gets a static wall only when the user said Cover (not before they were
/// asked). Pure, so hot-plugging is tested without screens.
public struct DisplayPlan: Equatable, Sendable {
    /// The desk's display (nil: no display at all).
    public var desk: UInt32?
    /// Displays covered by a wall, in the order given.
    public var walls: [UInt32]

    public init(desk: UInt32?, walls: [UInt32]) {
        self.desk = desk
        self.walls = walls
    }

    public static func make(_ screens: [DisplayInfo], deskUUID: String?, coverOthers: Bool?) -> DisplayPlan {
        guard !screens.isEmpty else { return DisplayPlan(desk: nil, walls: []) }
        let chosen = deskUUID.flatMap { u in screens.first { $0.uuid == u } }
        let desk = chosen ?? screens.first { $0.hasMenuBar } ?? screens[0]
        let walls = coverOthers == true ? screens.filter { $0.id != desk.id }.map(\.id) : []
        return DisplayPlan(desk: desk.id, walls: walls)
    }

    /// True on a first run with more than one display, until the user answers (onboarding's cover prompt).
    public static func needsCoverPrompt(screenCount: Int, coverOthers: Bool?) -> Bool {
        screenCount > 1 && coverOthers == nil
    }
}

/// What to do to the windows when the screens change (debounced `didChangeScreenParameters`; DESIGN §4.10).
public struct DisplayChange: Equatable, Sendable {
    /// The desk window moves to another display (its old one went away, or the user chose another).
    public var moveDesk: UInt32?
    /// The desk's display changed size, scale, visible frame or position: new frame and grid.
    public var resizeDesk = false
    public var addWalls: [UInt32] = []
    public var removeWalls: [UInt32] = []
    /// Walls whose display changed geometry: new frame and a re-render.
    public var resizeWalls: [UInt32] = []

    public init() {}

    public var isEmpty: Bool {
        moveDesk == nil && !resizeDesk && addWalls.isEmpty && removeWalls.isEmpty && resizeWalls.isEmpty
    }

    /// The change from what is shown (`old` plan over `oldScreens`) to the `new` plan over `screens`.
    public static func between(old: DisplayPlan, oldScreens: [DisplayInfo], new: DisplayPlan,
                               screens: [DisplayInfo]) -> DisplayChange {
        var c = DisplayChange()
        func info(_ id: UInt32, _ list: [DisplayInfo]) -> DisplayInfo? { list.first { $0.id == id } }
        func moved(_ id: UInt32) -> Bool {
            guard let a = info(id, oldScreens), let b = info(id, screens) else { return false }
            return a.frame != b.frame || a.visibleFrame != b.visibleFrame || a.backingScale != b.backingScale
        }
        if new.desk != old.desk {
            c.moveDesk = new.desk
        } else if let d = new.desk, moved(d) {
            c.resizeDesk = true
        }
        let before = Set(old.walls), after = Set(new.walls)
        c.addWalls = new.walls.filter { !before.contains($0) }
        c.removeWalls = old.walls.filter { !after.contains($0) }
        c.resizeWalls = new.walls.filter { before.contains($0) && moved($0) }
        return c
    }
}

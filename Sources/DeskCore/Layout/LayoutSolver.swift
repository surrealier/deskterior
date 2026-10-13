/// One procedural wall or floor decoration outside the core composition, in canvas px.
public struct WallDecor: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// Fairy lights strung across the top of the wall (`rect` spans hook to hook, sag included).
        case stringLights
        /// Floating shelf; `rect` covers the items, the board and the brackets.
        case shelf
        /// Framed print.
        case frame
        /// Pegboard with a few tools.
        case pegboard
        /// Landscape painting centred over the monitor: large on tall walls, a small print on medium ones.
        case painting
        /// Potted floor plant standing on the floor line.
        case floorPlant
        /// The ceiling plane above a tall wall (`rect` runs from the canvas top down to the crown).
        case ceiling
        /// Crown moulding where a tall wall meets the ceiling.
        case crown
        /// Picture rail near the top of a medium-height wall; the string lights hang from it.
        case rail
        /// Pendant lamp hanging from the crown of a very tall wall (`rect` = cord and shade).
        case pendant
        /// Macramé hanging plant from the crown of a very tall wall.
        case hangingPlant
    }

    public var kind: Kind
    public var rect: ArtRect

    public init(_ kind: Kind, _ rect: ArtRect) {
        self.kind = kind
        self.rect = rect
    }

    public var description: String { "\(kind.rawValue)\(rect)" }
}

/// The solved room for one canvas: the (possibly nudged) grid, the core placement, the decor that fits, and
/// every anchor in canvas px.
public struct SceneLayout: Hashable, Sendable {
    public let grid: PixelGrid
    /// Canvas rects to keep critical rects away from (widgets), as given to the solver.
    public let avoid: [ArtRect]
    public let decor: [WallDecor]
    public let anchors: Anchors
    /// True when no nudge could clear the avoid rects (show the one-time tip).
    public let avoidUnresolved: Bool
    /// Rows the core sits above the grid's floor line so some floor shows under the furniture
    /// (`LayoutSolver.floorLift`).
    public let floorLift: Int

    public var canvas: ArtSize { grid.artSize }
    /// Canvas position of the core's top-left (the grid's, lifted by `floorLift`).
    public var coreOrigin: ArtPoint { ArtPoint(grid.coreOrigin.x, grid.coreOrigin.y - floorLift) }
    public var visible: ArtRect { grid.visibleArtRect }

    /// A core rect in canvas px.
    public func rect(_ core: ArtRect) -> ArtRect { core.offsetBy(coreOrigin.x, coreOrigin.y) }
    /// A core point in canvas px.
    public func point(_ core: ArtPoint) -> ArtPoint { core + coreOrigin }
    /// A core y in canvas px.
    public func y(_ coreY: Int) -> Int { coreY + coreOrigin.y }
    /// A core x in canvas px.
    public func x(_ coreX: Int) -> Int { coreX + coreOrigin.x }

    /// Canvas y of the front floor line.
    public var floorY: Int { y(CoreLayout.floorY) }
    /// Canvas y where the wall meets the floor.
    public var wallBaseY: Int { y(CoreLayout.wallBaseY) }

    public func decor(_ kind: WallDecor.Kind) -> [WallDecor] { decor.filter { $0.kind == kind } }
}

/// Places the 512×320 core on the canvas (DESIGN §1.2 widget nudge) and fills the margins with decor that
/// adapts to the space left: string lights across the top band, a shelf and a framed print on the right wall,
/// a pegboard in a wide left margin, a floor plant beside the desk, and a painting plus crown moulding on
/// tall walls. Decor never sits behind the menu bar and drops out when it does not fit.
public enum LayoutSolver {
    /// Core rects a widget must not cover (§1.2): screen, chin, drawer fronts, mat, cabinet.
    public static let criticalCoreRects: [ArtRect] = [
        CoreLayout.screen, CoreLayout.chin, CoreLayout.riserDrawerL, CoreLayout.riserCubby,
        CoreLayout.riserDrawerR, CoreLayout.matDefault, CoreLayout.cabinet,
    ]
    /// Nudge step in art px.
    public static let nudgeStep = 8

    /// Solves for a display: tries core nudges 0, +8, −8, +16, … within the slack until no critical rect meets
    /// an avoid rect (canvas px of the un-nudged grid; the canvas does not depend on the nudge).
    public static func solve(display: DisplayGeometry, pixelSize: PixelSize = .normal, avoid: [ArtRect] = []) -> SceneLayout {
        solve(grid: PixelGrid(display: display, pixelSize: pixelSize), avoid: avoid)
    }

    /// Solves starting from an existing grid (its nudge is replaced by the solver's).
    public static func solve(grid base: PixelGrid, avoid: [ArtRect] = []) -> SceneLayout {
        var grid = base.nudge == 0 ? base : PixelGrid(display: base.display, pixelSize: base.pixelSize)
        var unresolved = false
        if !avoid.isEmpty, blocked(grid, avoid) {
            unresolved = true
            if let range = grid.nudgeRange {
                let span = max(abs(range.lowerBound), abs(range.upperBound))
                var step = nudgeStep
                search: while step <= span {
                    for n in [step, -step] where range.contains(n) {
                        let g = PixelGrid(display: base.display, pixelSize: base.pixelSize, nudge: n)
                        if !blocked(g, avoid) {
                            grid = g
                            unresolved = false
                            break search
                        }
                    }
                    step += nudgeStep
                }
            }
        }
        let lift = floorLift(grid)
        let o = ArtPoint(grid.coreOrigin.x, grid.coreOrigin.y - lift)
        return SceneLayout(
            grid: grid, avoid: avoid, decor: decor(for: grid, origin: o, avoid: avoid),
            anchors: Anchors.core.offsetBy(o.x, o.y), avoidUnresolved: unresolved, floorLift: lift
        )
    }

    /// Floor rows kept under the floor line when no Dock strip is reserved, so casters and plinths do not sit
    /// on the bezel.
    public static let minFloorMargin = 14

    /// How far the core rises above the grid's floor line to show `minFloorMargin` rows of floor below it
    /// (0 when a Dock strip already does; never past the top of the visible band).
    public static func floorLift(_ grid: PixelGrid) -> Int {
        let below = grid.artSize.h - grid.floorLineY
        let room = grid.coreOrigin.y - grid.visibleArtRect.minY
        return max(0, min(minFloorMargin - below, room))
    }

    /// The canvas rect covering a device-pixel rect (e.g. a widget frame converted to device px).
    public static func artRect(coveringDevice r: DeviceRect, grid: PixelGrid) -> ArtRect {
        let s = grid.scale
        let x0 = PixelGrid.floorDiv(r.x + grid.cropLeft, s), y0 = PixelGrid.floorDiv(r.y + grid.cropTop, s)
        let x1 = PixelGrid.ceilDiv(r.maxX + grid.cropLeft, s), y1 = PixelGrid.ceilDiv(r.maxY + grid.cropTop, s)
        return ArtRect(x0, y0, x1 - x0, y1 - y0)
    }

    private static func blocked(_ grid: PixelGrid, _ avoid: [ArtRect]) -> Bool {
        let o = ArtPoint(grid.coreOrigin.x, grid.coreOrigin.y - floorLift(grid))
        return criticalCoreRects.contains { core in
            let r = core.offsetBy(o.x, o.y)
            return avoid.contains { $0.intersects(r) }
        }
    }

    // MARK: Decor

    /// The most wall shown above the core; taller canvases show the ceiling above a crown moulding.
    public static let maxWallAbove = 230
    /// Longest cord a pendant or hanging plant hangs on.
    public static let maxCord = 72

    /// Decor for a grid with the core at `c`, back to front. Pure and deterministic.
    static func decor(for grid: PixelGrid, origin c: ArtPoint, avoid: [ArtRect]) -> [WallDecor] {
        let canvas = grid.artSize
        let top = max(grid.visibleArtRect.minY, 0)
        var out: [WallDecor] = []
        func clear(_ r: ArtRect) -> Bool { !avoid.contains { $0.intersects(r) } }
        let wallAbove = c.y - top
        let monitorTop = c.y + CoreLayout.monitorBody.y

        // Tall walls end at a crown moulding with the ceiling above it; medium walls get a picture rail near the
        // top that the string lights hang from.
        var hangTop = top
        var rail = false
        if wallAbove > maxWallAbove {
            let crownY = c.y - maxWallAbove
            out.append(WallDecor(.ceiling, ArtRect(0, 0, canvas.w, crownY)))
            out.append(WallDecor(.crown, ArtRect(0, crownY, canvas.w, 6)))
            hangTop = crownY + 6
        } else if wallAbove >= 56 {
            out.append(WallDecor(.rail, ArtRect(0, top + 4, canvas.w, 3)))
            hangTop = top + 7
            rail = true
        }
        // The lights drape a little above the furniture (or from the rail), not along a far-off ceiling.
        let lightsTop = rail ? hangTop : max(hangTop, c.y - 38)

        // String lights: hooks near the top of the band, lowest bulb above the window and monitor (core y 12).
        var lightsBottom = hangTop
        let band = c.y + 9 - lightsTop
        if band >= 14 {
            let sag = rail ? min(14, max(6, (monitorTop - lightsTop) / 3)) : min(8, band - 10)
            let r = ArtRect(4, lightsTop + (rail ? 0 : 2), canvas.w - 8, sag + 6)
            out.append(WallDecor(.stringLights, r))
            lightsBottom = r.maxY + 4
        }

        // A painting centred over the monitor: large on a tall wall, a small print where a medium wall leaves a
        // band between the lights and the monitor.
        if wallAbove >= 110 {
            let w = 112, h = 64
            let r = ArtRect(c.x + 264 - w / 2, lightsTop - 10 - h, w, h)
            if r.minY >= hangTop, clear(r) { out.append(WallDecor(.painting, r)) }
        } else if monitorTop - lightsBottom >= 40 {
            let gap = monitorTop - lightsBottom
            let h = min(30, gap - 12), w = h * 8 / 5
            let r = ArtRect(c.x + 264 - w / 2, lightsBottom + (gap - h) / 2, w, h)
            if clear(r) { out.append(WallDecor(.painting, r)) }
        }

        // Very tall walls: a pendant and a hanging plant on short cords from the crown.
        if wallAbove > maxWallAbove {
            let pendantH = min(maxCord + 12, c.y - 96 - hangTop)
            let pendant = ArtRect(c.x + 92, hangTop, 24, pendantH)
            if pendantH >= 40, clear(pendant) { out.append(WallDecor(.pendant, pendant)) }
            let plantH = min(maxCord + 28, c.y - 46 - hangTop)
            let hanging = ArtRect(c.x + 438, hangTop, 32, plantH)
            if plantH >= 60, clear(hanging) { out.append(WallDecor(.hangingPlant, hanging)) }
        }

        // Right wall: the shelf hangs over the phone and hub; it widens into a wide right margin.
        let rightLimit = canvas.w - 4
        let shelfX = c.x + 434
        let shelfW = min(92, rightLimit - shelfX)
        if shelfW >= 40 {
            let r = ArtRect(shelfX, c.y + 74, shelfW, 36)
            if clear(r) { out.append(WallDecor(.shelf, r)) }
        }
        // Framed print above the shelf, under the lights.
        let frameTop = max(lightsBottom + 2, c.y + 2)
        let frameRoom = c.y + 68 - frameTop
        if frameRoom >= 34 {
            let h = min(40, frameRoom)
            let w = h * 3 / 4 + 2
            let cx = shelfX + max(shelfW, 40) / 2 + 6
            let r = ArtRect(min(cx - w / 2, rightLimit - w), frameTop + (frameRoom - h) / 2, w, h)
            if r.minX >= c.x + 430, clear(r) { out.append(WallDecor(.frame, r)) }
        }

        // Left margin: a pegboard beside the window when there is room for one.
        let leftRoom = c.x + 12 - 4
        if leftRoom >= 34 {
            let w = min(40, leftRoom - 4)
            let h = 44
            let r = ArtRect(4 + (leftRoom - w) / 2, max(lightsBottom + 4, c.y + 24), w, h)
            if r.maxY <= c.y + 132, clear(r) { out.append(WallDecor(.pegboard, r)) }
        }

        // Floor plant right of the desk.
        let plantRoom = canvas.w - (c.x + 500)
        if plantRoom >= 30 {
            let w = min(40, plantRoom - 2)
            let h = 92
            let r = ArtRect(c.x + 500 + (plantRoom - w) / 2 + 1, c.y + CoreLayout.floorY - h - 6, w, h)
            if r.minY >= top { out.append(WallDecor(.floorPlant, r)) }
        }
        return out
    }
}

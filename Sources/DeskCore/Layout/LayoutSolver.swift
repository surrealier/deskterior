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
        /// Large landscape painting for tall walls.
        case painting
        /// Potted floor plant standing on the floor line.
        case floorPlant
        /// Crown moulding where a tall wall meets the ceiling.
        case crown
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

    public var canvas: ArtSize { grid.artSize }
    public var coreOrigin: ArtPoint { grid.coreOrigin }
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
        let o = grid.coreOrigin
        return SceneLayout(
            grid: grid, avoid: avoid, decor: decor(for: grid, avoid: avoid),
            anchors: Anchors.core.offsetBy(o.x, o.y), avoidUnresolved: unresolved
        )
    }

    /// The canvas rect covering a device-pixel rect (e.g. a widget frame converted to device px).
    public static func artRect(coveringDevice r: DeviceRect, grid: PixelGrid) -> ArtRect {
        let s = grid.scale
        let x0 = PixelGrid.floorDiv(r.x + grid.cropLeft, s), y0 = PixelGrid.floorDiv(r.y + grid.cropTop, s)
        let x1 = PixelGrid.ceilDiv(r.maxX + grid.cropLeft, s), y1 = PixelGrid.ceilDiv(r.maxY + grid.cropTop, s)
        return ArtRect(x0, y0, x1 - x0, y1 - y0)
    }

    private static func blocked(_ grid: PixelGrid, _ avoid: [ArtRect]) -> Bool {
        criticalCoreRects.contains { core in
            let r = grid.canvasRect(fromCore: core)
            return avoid.contains { $0.intersects(r) }
        }
    }

    // MARK: Decor

    /// Decor for a grid, back to front. Pure and deterministic.
    static func decor(for grid: PixelGrid, avoid: [ArtRect]) -> [WallDecor] {
        let c = grid.coreOrigin, canvas = grid.artSize
        let top = max(grid.visibleArtRect.minY, 0)
        var out: [WallDecor] = []
        func clear(_ r: ArtRect) -> Bool { !avoid.contains { $0.intersects(r) } }

        // Tall walls: crown moulding at the ceiling, and decor stays within reach of the desk.
        let wallAbove = c.y - top
        if c.y > 150 {
            out.append(WallDecor(.crown, ArtRect(0, 0, canvas.w, 6)))
        }
        let ceiling = c.y > 150 ? max(top + 8, c.y - 150) : top

        // String lights: hooks near the top of the band, lowest bulb above the window and monitor (core y 12).
        var lightsBottom = ceiling
        let band = c.y + 9 - ceiling
        if band >= 14 {
            let sag = min(8, band - 10)
            let r = ArtRect(4, ceiling + 2, canvas.w - 8, sag + 6)
            out.append(WallDecor(.stringLights, r))
            lightsBottom = r.maxY
        }

        // Painting on a tall wall, centred over the monitor.
        if wallAbove >= 110 {
            let w = 112, h = 64
            let r = ArtRect(c.x + 264 - w / 2, max(lightsBottom + 10, c.y - 24 - h), w, h)
            if clear(r) { out.append(WallDecor(.painting, r)) }
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
        let frameTop = max(lightsBottom + 6, c.y + 2)
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
            let r = ArtRect(4 + (leftRoom - w) / 2, max(lightsBottom + 8, c.y + 24), w, h)
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

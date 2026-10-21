/// The static wall on a display that does not hold the desk (DESIGN §4.10 `WallScene`): the same room shell the desk
/// stands in on a display of that size — wall, wainscot, baseboard and floor at the same heights — with the window
/// and the margins' decor (string lights, shelf, pegboard, floor plant, and the ceiling, crown, pendant and hanging
/// plant on a tall wall), but no desk: a large painting hangs where the monitor would stand and a second floor plant
/// stands where the desk's left legs would. It is lit on the CPU like the room at that moment: the ambient level,
/// plus the window's sky, lit string lights and the pendant's bulb. The app renders it once per size and light phase
/// (no frame loop, so no idle cost). Wall decor put away on the desk's display is put away here too (Erratum 30).
/// Its framed print shows the photo hung in the picture frame and takes a photo dropped on it (Erratum 33).
public enum WallArt {
    /// The lit wall for `grid` (a whole canvas) at `state`'s time and lights.
    public static func render(grid: PixelGrid, state: RoomState) -> PixelBuffer {
        let layout = LayoutSolver.solve(grid: grid)
        let tod = state.timeOfDay
        return lightMask(layout, state: state).apply(to: compose(layout, state), ambient: tod.ambient)
    }

    /// The unlit wall.
    public static func compose(_ layout: SceneLayout, _ state: RoomState) -> PixelBuffer {
        let tod = state.timeOfDay
        let lights = state.effectiveLights
        var c = PixelCanvas(width: layout.canvas.w, height: layout.canvas.h, fill: RoomArt.wall)
        RoomArt.drawShell(&c, layout: layout)
        RoomArt.drawFloor(&c, from: layout.wallBaseY, layout: layout)
        for d in decor(layout, stowed: state.stowed) {
            let lit = switch d.kind {
            case .pendant, .ceilingLamp: tod.isDark && lights.roomLightOn
            case .stringLights: RoomArt.stringLightsLit(tod)
            default: tod.isDark
            }
            // MARK: picture frame (0.4.0): the wall's own framed print shows the room's photo; its painting stays one.
            c.blit(DecorArt.sprite(d, lit: lit, photo: state.framePhoto).frames[0], at: d.rect.origin)
        }
        let window = WindowArt.window(sky: state.sky, minuteOfDay: state.time.minuteOfDay)
        c.blit(window.frames[0], at: layout.rect(CoreLayout.window).origin)
        return c.buffer
    }

    /// The room's decor without its painting (whose place depends on the monitor), plus a painting centred where the
    /// monitor would stand and a floor plant left of centre; without the decor of `stowed` (its own painting goes with
    /// Wall Art, its own floor plant with Floor Plant). The framed print shows the room's photo (Erratum 33).
    public static func decor(_ layout: SceneLayout, stowed: Set<StowID> = []) -> [WallDecor] {
        let hidden = StowCatalog.decorKinds(hiddenBy: stowed)
        var out = layout.decor.filter { $0.kind != .painting && !hidden.contains($0.kind) }
        if !hidden.contains(.painting) { out.append(WallDecor(.painting, layout.rect(ArtRect(208, 34, 112, 64)))) }
        let plant = ArtRect(120, CoreLayout.floorY - 92 - 6, 40, 92)
        if !hidden.contains(.floorPlant) { out.append(WallDecor(.floorPlant, layout.rect(plant))) }
        return out
    }

    // MARK: picture frame (0.4.0)
    /// The wall's framed print (canvas px) as `compose` draws it, where a Finder drop is the picture frame's (Erratum
    /// 33): nil while the wall shelf is put away or no frame fits.
    public static func frameRect(_ layout: SceneLayout, stowed: Set<StowID> = []) -> ArtRect? {
        decor(layout, stowed: stowed).first { $0.kind == .frame }?.rect
    }

    /// What glows on the wall: the window's sky, and after dark the lit string lights and the pendant's bulb.
    public static func lightMask(_ layout: SceneLayout, state: RoomState) -> LightMask {
        let layout = layout.hiding(StowCatalog.decorKinds(hiddenBy: state.stowed))
        let tod = state.timeOfDay
        var m = LightMask(size: layout.canvas)
        let win = layout.rect(CoreLayout.window)
        m.addPoints(WindowArt.skyPixels().map { $0 + win.origin }, level: 7, tint: .cool)
        if tod.isDark && state.effectiveLights.roomLightOn {
            for p in layout.decor(.pendant) {
                let bulb = DecorArt.pendantBulb(in: p.rect.size).offsetBy(p.rect.x, p.rect.y)
                m.addEllipse(bulb.insetBy(-10, -6), level: 7, tint: .warm, edge: 6)
            }
            m.addCeilingLamps(layout)
        }
        if tod.isDark, RoomArt.stringLightsLit(tod) {
            for d in layout.decor(.stringLights) {
                m.addPoints(RoomArt.stringLightGlass(in: d.rect) + RoomArt.stringLightHalo(in: d.rect).map(\.point),
                            level: 7, tint: .warm)
            }
        }
        return m
    }

    /// A key for "would the wall look different": its canvas, the light phase, the sky, the lights, the decor put
    /// away and the framed photo (Erratum 33). The app re-renders a wall only when this changes (the window's clouds
    /// drift by the minute, but a wall may lag a little).
    public static func signature(grid: PixelGrid, state: RoomState) -> String {
        let tod = state.timeOfDay
        let l = state.effectiveLights
        let away = StowCatalog.decorKinds(hiddenBy: state.stowed).map(\.rawValue).sorted().joined(separator: ",")
        // MARK: picture frame (0.4.0): another photo re-renders the wall
        let photo = state.framePhoto.map(FramePhoto.digest) ?? "-"
        return "\(grid.artSize) \(grid.coreOrigin) \(tod.phase.rawValue) \(tod.ambientLevel) \(tod.ambientTint) "
            + "\(state.sky.rawValue) \(l.roomLightOn) \(state.time.hour / 2) [\(away)] \(photo)"
    }
}

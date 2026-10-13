import Foundation

/// The room shell (DESIGN §1.3, §2.2 E12–E13): wall, wainscot, floor and rug, the desk top and its front, and
/// the wall pieces (window with sky and blinds, clock, calendar, light switch) plus the procedural decor that
/// fills the margins. Light comes from the window, top-left.
public enum RoomArt {
    // MARK: Palette roles for the shell

    static let wall = Role.wallDay                 // ebede9
    static let wallShade = Role.wallDayShade       // c7cfcc
    static let wainscot = Ink.neutral8
    static let wainscotLine = Ink.neutral7
    static let floorBase = Ink.oak2
    static let floorSeam = Ink.oak1
    static let floorLight = Ink.oak3

    /// Core y where the wainscot (chair rail) starts.
    static let chairRailY = 194

    // MARK: Backdrop

    /// Everything static behind the room's objects, canvas-sized: wall, wainscot, baseboard, floor, rug, the
    /// desk top face, and the soft shadows that wall pieces and back-strip props cast.
    public static func backdrop(_ layout: SceneLayout) -> PixelBuffer {
        let w = layout.canvas.w, h = layout.canvas.h
        var c = PixelCanvas(width: w, height: h, fill: wall)
        let base = layout.wallBaseY
        let desk = layout.rect(CoreLayout.deskTop)

        // Wainscot with a chair rail and raised panels (visible beside and under the desk).
        let rail = layout.y(chairRailY)
        c.fill(ArtRect(0, rail, w, base - rail), wainscot)
        c.hline(x: 0, y: rail - 3, length: w, .neutral9)
        c.hline(x: 0, y: rail - 2, length: w, .neutral8)
        c.hline(x: 0, y: rail - 1, length: w, wainscotLine)
        let panelTop = rail + 5, panelBottom = base - 10
        if panelBottom - panelTop >= 8 {
            var x = layout.x(-4) - 64 * ((layout.x(-4) + 63) / 64)
            while x < w {
                let r = ArtRect(x + 6, panelTop, 52, panelBottom - panelTop)
                c.bevel(r, light: .neutral9, dark: wainscotLine)
                x += 64
            }
        }
        // Baseboard.
        c.fill(ArtRect(0, base - 7, w, 7), .neutral9)
        c.hline(x: 0, y: base - 7, length: w, wainscotLine)
        c.hline(x: 0, y: base - 2, length: w, .neutral8)
        c.hline(x: 0, y: base - 1, length: w, wainscotLine)

        drawFloor(&c, from: base, layout: layout)
        drawRug(&c, layout: layout)

        // Under-desk shade: wall strip and floor darken toward the back, fading out over a dithered band.
        let shadeBottom = layout.y(292)
        let apronBottom = layout.y(CoreLayout.apron.maxY)
        shade(&c, ArtRect(desk.x, apronBottom, desk.w, shadeBottom - apronBottom), steps: 1)
        let deep = base + 12
        shade(&c, ArtRect(desk.x, apronBottom, desk.w, deep - apronBottom), steps: 1)
        softEdge(&c, y: deep, x: desk.minX..<desk.maxX)
        softEdge(&c, y: shadeBottom, x: desk.minX..<desk.maxX)

        // Contact shadow on the wall just above the desk's back edge.
        for x in desk.minX..<desk.maxX where c.ink(at: x, desk.y - 1) == wall { c.plot(x, desk.y - 1, wallShade) }
        drawDeskTop(&c, desk)
        drawWallShadows(&c, layout)
        drawDeskShadows(&c, layout)
        return c.buffer
    }

    /// One half-dithered row under a shadow's edge, so it reads soft without a visible pattern band.
    static func softEdge(_ c: inout PixelCanvas, y: Int, x range: Range<Int>) {
        guard y >= 0, y < c.height else { return }
        for x in range where (x + y) % 2 == 0 {
            if let ink = c.ink(at: x, y), !ink.isClear { c.plot(x, y, ink.darker()) }
        }
    }

    /// Darkens every pixel of `r` by `steps` ramp steps.
    static func shade(_ c: inout PixelCanvas, _ r: ArtRect, steps: Int) {
        let clip = r.intersection(c.bounds)
        guard !clip.isEmpty else { return }
        for y in clip.minY..<clip.maxY {
            for x in clip.minX..<clip.maxX {
                if let ink = c.ink(at: x, y), !ink.isClear { c.plot(x, y, ink.darker(steps)) }
            }
        }
    }

    static func drawFloor(_ c: inout PixelCanvas, from top: Int, layout: SceneLayout) {
        let w = c.width
        c.fill(ArtRect(0, top, w, c.height - top), floorBase)
        // Boards run parallel to the wall: 6-row planks (5 board + 1 seam), staggered end joints, a lit
        // bevel on most boards and the odd short grain streak.
        var row = 0
        var y = top
        while y < c.height {
            let boardH = 5
            let seed = UInt64(row) &* 7919
            var x = -ArtKit.noise(row, 3, seed: seed, 70) - layout.coreOrigin.x % 70
            var seg = 0
            while x < w {
                let len = 58 + ArtKit.noise(row, seg, seed: seed, 40)
                if ArtKit.noise(seg, row, seed: 99, 3) == 0 {
                    c.hline(x: x + 1, y: y, length: len - 2, floorLight)
                }
                if ArtKit.noise(seg, row, seed: 7, 3) == 0 {
                    let gx = x + 8 + ArtKit.noise(seg, row, seed: 5, max(1, len - 30))
                    c.hline(x: gx, y: y + 2 + ArtKit.noise(seg, row, seed: 8, 2), length: 8 + ArtKit.noise(row, seg, seed: 6, 10), floorLight)
                }
                c.vline(x: x + len - 1, y: y, length: boardH, floorSeam)
                x += len
                seg += 1
            }
            c.hline(x: 0, y: y + boardH, length: w, floorSeam)
            y += boardH + 1
            row += 1
        }
    }

    static func drawRug(_ c: inout PixelCanvas, layout: SceneLayout) {
        let r = ArtRect(layout.x(104), layout.y(290), 272, c.height - layout.y(290))
        guard r.h > 2 else { return }
        c.fill(r, .red2)
        c.hline(x: r.x, y: r.y, length: r.w, .red3)
        // Border band and a row of diamonds.
        let band = ArtRect(r.x + 4, r.y + 3, r.w - 8, r.h)
        c.stroke(ArtRect(band.x, band.y, band.w, band.h + 2), .walnut4)
        let inner = band.insetBy(3, 3)
        if inner.h > 0 { c.stroke(ArtRect(inner.x, inner.y, inner.w, inner.h + 6), .red1) }
        var x = band.x + 8
        while x + 6 < band.maxX - 4 {
            let cy = band.y + 7
            if cy + 2 < c.height {
                c.plot(x + 2, cy - 2, .walnut5)
                c.hline(x: x + 1, y: cy - 1, length: 3, .walnut4)
                c.hline(x: x, y: cy, length: 5, .walnut4)
                c.plot(x + 2, cy, .red1)
                c.hline(x: x + 1, y: cy + 1, length: 3, .walnut4)
                c.plot(x + 2, cy + 2, .walnut3)
            }
            x += 12
        }
        // Fringe at the back edge, then a dark contact line under the rug's lip.
        c.hline(x: r.x, y: r.y - 1, length: r.w, .oak0)
        var fx = r.x + 1
        while fx < r.maxX {
            c.plot(fx, r.y - 1, .oak5)
            fx += 2
        }
    }

    static func drawDeskTop(_ c: inout PixelCanvas, _ d: ArtRect) {
        c.fill(d, Role.desk)
        // Long, quiet grain streaks; a few highlights where the window light falls.
        for i in 0..<22 {
            let y = d.y + 3 + ArtKit.noise(i, 1, seed: 11, d.h - 6)
            let x = d.x + ArtKit.noise(i, 2, seed: 11, d.w - 40)
            let len = min(30 + ArtKit.noise(i, 3, seed: 11, 70), d.maxX - 2 - x)
            // Long streaks that drift a row up or down now and then read as grain, not scratches.
            var gx = x, gy = y
            var k = 0
            while gx < x + len {
                let seg = 10 + ArtKit.noise(i, k, seed: 17, 22)
                c.hline(x: gx, y: gy, length: min(seg, x + len - gx), Role.deskEdge)
                gx += seg
                gy = min(max(gy + (ArtKit.noise(k, i, seed: 19, 2) == 0 ? -1 : 1), d.y + 3), d.maxY - 3)
                k += 1
            }
        }
        for i in 0..<8 {
            let y = d.y + 4 + ArtKit.noise(i, 5, seed: 13, d.h - 10)
            let x = d.x + 4 + ArtKit.noise(i, 6, seed: 13, d.w / 3)
            c.hline(x: x, y: y, length: 10 + ArtKit.noise(i, 7, seed: 13, 24), Role.deskHighlight)
        }
        // Back edge meets the wall; front bullnose catches the light.
        c.hline(x: d.x, y: d.y, length: d.w, Role.deskShadow)
        c.hline(x: d.x, y: d.y + 1, length: d.w, Role.deskEdge)
        c.hline(x: d.x, y: d.maxY - 1, length: d.w, Role.deskHighlight)
        c.vline(x: d.x, y: d.y, length: d.h, Role.deskEdge)
        c.vline(x: d.maxX - 1, y: d.y, length: d.h, Role.deskShadow)
        c.plot(d.x, d.maxY - 1, Role.deskHighlight)
    }

    /// Soft wall shadows (down-right of each wall piece and of the monitor).
    static func drawWallShadows(_ c: inout PixelCanvas, _ layout: SceneLayout) {
        func drop(_ r: ArtRect, dx: Int, dy: Int) {
            let s = r.offsetBy(dx, dy)
            for y in s.minY..<s.maxY {
                for x in s.minX..<s.maxX where !r.contains(ArtPoint(x, y)) {
                    if c.ink(at: x, y) == wall { c.plot(x, y, wallShade) }
                }
            }
        }
        let win = layout.rect(CoreLayout.window)
        drop(ArtRect(win.x + 2, win.y, win.w - 4, win.h - 2), dx: 3, dy: 3)
        drop(layout.rect(CoreLayout.calendar), dx: 2, dy: 2)
        drop(layout.rect(CoreLayout.roomSwitch), dx: 1, dy: 1)
        let clock = layout.rect(CoreLayout.clock)
        var disc = PixelCanvas(width: clock.w, height: clock.h)
        disc.ellipseFill(disc.bounds, .neutral0)
        ArtKit.castShadow(of: disc.buffer, at: clock.origin, offset: ArtPoint(2, 2), ink: wallShade, into: &c) {
            $0 == wall
        }
        let mon = layout.rect(CoreLayout.monitorBody)
        drop(ArtRect(mon.x, mon.y, mon.w, mon.h - 6), dx: 5, dy: 4)
        for d in layout.decor {
            switch d.kind {
            case .shelf:
                drop(ArtRect(d.rect.x, d.rect.y + 22, d.rect.w, 4), dx: 2, dy: 3)
            case .frame, .pegboard, .painting:
                drop(d.rect, dx: 2, dy: 2)
            default:
                break
            }
        }
    }

    /// Contact shadows of the back-strip props on the desk top (down-right, one oak step darker).
    static func drawDeskShadows(_ c: inout PixelCanvas, _ layout: SceneLayout) {
        func onDesk(_ i: Ink) -> Bool { i == Role.desk || i == Role.deskHighlight }
        let props: [(PixelBuffer, ArtRect)] = [
            (StorageArt.riser().image, CoreLayout.riser),
            (MonitorArt.stand().image, MonitorArt.standRect),
            (PropArt.plant().image, CoreLayout.plant),
            (PropArt.phoneStand(faceUp: true).image, PropArt.phoneStandRect),
            (PropArt.driveHub().image, CoreLayout.driveHub),
            (PropArt.lamp(on: false).image, PropArt.lampRect),
        ]
        for (img, core) in props {
            let r = layout.rect(core)
            ArtKit.castShadow(of: img, at: r.origin, offset: ArtPoint(3, 2), ink: Role.deskEdge, into: &c, where: onDesk)
        }
    }

    // MARK: Desk front

    /// The apron (desk front face) and the two front legs, as one sprite covering apron.x…, apron.y…floor.
    public static func deskFront() -> SpriteAsset {
        let a = CoreLayout.apron
        let h = CoreLayout.floorY - a.y
        var c = PixelCanvas(width: a.w, height: h)
        // Apron: bullnose highlight, face, lower shadow, dark lip.
        c.fill(ArtRect(0, 0, a.w, a.h), Role.deskEdge)
        c.hline(x: 0, y: 0, length: a.w, Role.deskHighlight)
        c.hline(x: 0, y: 1, length: a.w, Role.desk)
        c.hline(x: 0, y: a.h - 3, length: a.w, Role.deskShadow)
        c.hline(x: 0, y: a.h - 2, length: a.w, .oak1)
        c.hline(x: 0, y: a.h - 1, length: a.w, .oak0)
        c.vline(x: 0, y: 0, length: a.h, Role.desk)
        c.vline(x: a.w - 1, y: 0, length: a.h, .oak1)
        for leg in [CoreLayout.legLeft, CoreLayout.legRight] {
            let x = leg.x - a.x, top = a.h
            let lh = h - top
            c.fill(ArtRect(x, top, leg.w, lh), Role.deskEdge)
            c.vline(x: x + 1, y: top, length: lh, Role.desk)
            c.vline(x: x + 2, y: top, length: lh - 1, Role.deskHighlight)
            c.vline(x: x + leg.w - 2, y: top, length: lh, Role.deskShadow)
            c.vline(x: x, y: top, length: lh, .oak1)
            c.vline(x: x + leg.w - 1, y: top, length: lh, .oak0)
            c.hline(x: x, y: top, length: leg.w, .oak1)
            // Shadow under the apron, then a foot cap.
            c.hline(x: x + 1, y: top, length: leg.w - 2, Role.deskShadow)
            c.hline(x: x, y: h - 2, length: leg.w, Role.deskShadow)
            c.hline(x: x, y: h - 1, length: leg.w, .oak0)
        }
        return SpriteAsset("desk.front", c, anchor: ArtPoint(0, 0), hitRects: ["apron": ArtRect(0, 0, a.w, a.h)])
    }

    // MARK: Light switch

    public static func roomSwitch(on: Bool) -> SpriteAsset {
        let r = CoreLayout.roomSwitch
        var c = PixelCanvas(width: r.w, height: r.h)
        c.roundedRectFill(c.bounds, radius: 1, .neutral6)
        c.fill(c.bounds.insetBy(1, 1), .neutral9)
        c.hline(x: 1, y: r.h - 2, length: r.w - 2, .neutral8)
        c.vline(x: r.w - 2, y: 1, length: r.h - 2, .neutral8)
        // Rocker: lit top half when on.
        let rocker = ArtRect(3, 3, 2, 6)
        c.fill(rocker, .neutral7)
        if on {
            c.fill(ArtRect(3, 3, 2, 3), .neutral9)
            c.hline(x: 3, y: 6, length: 2, .neutral6)
        } else {
            c.fill(ArtRect(3, 6, 2, 3), .neutral9)
            c.hline(x: 3, y: 3, length: 2, .neutral6)
        }
        c.plot(4, 1, .neutral7)
        c.plot(4, r.h - 2, .neutral7)
        return SpriteAsset(on ? "room.switch.on" : "room.switch.off", c, anchor: .zero)
    }

    // MARK: Clock

    /// The wall clock showing `hour:minute` (hands drawn with LineRaster, pixel-perfect).
    public static func clock(hour: Int, minute: Int) -> SpriteAsset {
        let n = CoreLayout.clock.w
        var c = PixelCanvas(width: n, height: n)
        c.ellipseFill(c.bounds, .walnut1)
        c.ellipseFill(c.bounds.insetBy(1, 1), .walnut2)
        // Rim highlight top-left, shade bottom-right.
        var rim = PixelCanvas(width: n, height: n)
        rim.ellipseStroke(rim.bounds.insetBy(1, 1), .walnut3)
        for y in 0..<n {
            for x in 0..<n where rim.ink(at: x, y) == .walnut3 && x + y < n - 4 { c.plot(x, y, .walnut3) }
        }
        c.ellipseStroke(c.bounds, .walnut0)
        let face = c.bounds.insetBy(3, 3)
        c.ellipseFill(face, .neutral9)
        // Inner shadow along the top-left of the face (the rim stands proud).
        var inner = PixelCanvas(width: n, height: n)
        inner.ellipseStroke(face, .neutral8)
        for y in 0..<n {
            for x in 0..<n where inner.ink(at: x, y) == .neutral8 && x + y < n {
                c.plot(x, y, .neutral8)
            }
        }
        let cx = 13.5, cy = 13.5
        func at(_ deg: Double, _ r: Double) -> ArtPoint {
            let a = (deg - 90) * .pi / 180
            return ArtPoint(Int((cx + cos(a) * r).rounded(.down)), Int((cy + sin(a) * r).rounded(.down)))
        }
        for i in 0..<12 {
            let p = at(Double(i) * 30, 9.6)
            if i % 3 == 0 {
                c.plot(p, .neutral3)
                c.plot(at(Double(i) * 30, 8.4), .neutral3)
            } else {
                c.plot(p, .neutral6)
            }
        }
        let m = Double(minute), hr = Double(hour % 12) + m / 60
        let centre = ArtPoint(13, 13)
        c.polyline([centre, at(hr * 30, 6.2)], .neutral1)
        c.polyline([ArtPoint(14, 14), at(hr * 30, 5.6)], .neutral1)
        c.polyline([centre, at(m * 6, 9.2)], .neutral2)
        c.fill(ArtRect(13, 13, 2, 2), .red3)
        c.plot(13, 13, .red4)
        return SpriteAsset("clock", c, anchor: .zero)
    }

    // MARK: Calendar

    static let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// The hanging wall calendar for `date`'s month, with today's cell ringed.
    public static func calendar(_ date: WallTime) -> SpriteAsset {
        let r = CoreLayout.calendar
        var c = PixelCanvas(width: r.w, height: r.h)
        // Paper with a lifted bottom-right corner.
        let paper = ArtRect(0, 4, r.w, r.h - 4)
        c.fill(paper, .neutral9)
        c.stroke(paper, .neutral6)
        c.vline(x: r.w - 2, y: 5, length: paper.h - 2, .neutral8)
        c.hline(x: 1, y: r.h - 2, length: r.w - 2, .neutral8)
        // Header.
        c.fill(ArtRect(1, 5, r.w - 2, 9), .red3)
        c.hline(x: 1, y: 5, length: r.w - 2, .red4)
        c.hline(x: 1, y: 13, length: r.w - 2, .red2)
        let month = monthNames[date.month - 1]
        Digits.draw(month, at: ArtPoint((r.w - Digits.measure(month)) / 2, 7), .neutral9, into: &c)
        // Binder rings on a nail.
        for x in [9, r.w - 10] {
            c.vline(x: x, y: 1, length: 6, .neutral4)
            c.vline(x: x + 1, y: 1, length: 6, .neutral6)
            c.plot(x, 1, .neutral6)
        }
        c.fill(ArtRect(r.w / 2 - 1, 0, 2, 2), .neutral3)
        // Day grid: 7 columns × up to 6 rows of 4-px cells.
        let first = WallTime(year: date.year, month: date.month, day: 1, hour: 0, minute: 0).weekday
        let rows = (first + date.daysInMonth + 6) / 7
        let pitchY = rows > 5 ? 3 : 4
        for day in 1...date.daysInMonth {
            let i = first + day - 1
            let col = i % 7, row = i / 7
            let x = 2 + col * 4, y = 16 + row * pitchY
            let weekend = col == 0 || col == 6
            if day == date.day {
                c.fill(ArtRect(x - 1, y - 1, 4, pitchY == 4 ? 4 : 3), .red4)
                c.hline(x: x, y: y, length: 2, .neutral9)
            } else {
                c.hline(x: x, y: y, length: 2, weekend ? .red4 : .neutral5)
                if pitchY == 4 { c.plot(x, y + 1, weekend ? .red3 : .neutral7) }
            }
        }
        // Curled corner.
        c.plot(r.w - 1, r.h - 1, .clear)
        c.plot(r.w - 2, r.h - 1, .neutral6)
        c.plot(r.w - 1, r.h - 2, .neutral6)
        c.plot(r.w - 2, r.h - 2, .neutral7)
        c.plot(r.w - 3, r.h - 2, .neutral7)
        c.plot(r.w - 2, r.h - 3, .neutral7)
        return SpriteAsset("calendar", c, anchor: .zero)
    }

    // MARK: String lights

    /// Bulb positions (canvas px, top of each bulb) for string lights strung across `rect`.
    public static func stringLightBulbs(in rect: ArtRect) -> [ArtPoint] {
        let wire = stringLightWire(in: rect)
        var out: [ArtPoint] = []
        var x = rect.x + 6
        while x < rect.maxX - 4 {
            if let y = wire[x] { out.append(ArtPoint(x, y + 1)) }
            x += 11
        }
        return out
    }

    /// Wire y per x: a catenary-ish sag between hooks every ~120 px.
    static func stringLightWire(in rect: ArtRect) -> [Int: Int] {
        let sag = max(2, rect.h - 6)
        let spans = max(1, (rect.w + 60) / 120)
        let spanW = Double(rect.w) / Double(spans)
        var out: [Int: Int] = [:]
        for x in rect.x..<rect.maxX {
            let t = (Double(x - rect.x) / spanW).truncatingRemainder(dividingBy: 1)
            let dip = 4 * t * (1 - t)
            out[x] = rect.y + Int((Double(sag) * dip).rounded())
        }
        return out
    }

    /// Fairy lights across `rect` (sprite in rect-local px). `lit` brightens the glass (night).
    public static func stringLights(_ rect: ArtRect, lit: Bool) -> SpriteAsset {
        var c = PixelCanvas(width: rect.w, height: rect.h + 4)
        let wire = stringLightWire(in: rect)
        var prev: ArtPoint?
        for x in rect.x..<rect.maxX {
            let p = ArtPoint(x - rect.x, wire[x]! - rect.y)
            if let q = prev { c.line(from: q, to: p, .neutral4) } else { c.plot(p, .neutral4) }
            prev = p
        }
        // Hooks at span ends.
        let spans = max(1, (rect.w + 60) / 120)
        for i in 0...spans {
            let x = min(rect.w - 1, i * rect.w / spans)
            c.fill(ArtRect(x - 1, 0, 2, 2), .neutral5)
        }
        let colours: [(Ink, Ink)] = [(.walnut5, .walnut4), (.red5, .red4), (.green5, .green4), (.walnut5, .walnut4), (.blue5, .blue4)]
        for (i, b) in stringLightBulbs(in: rect).enumerated() {
            let x = b.x - rect.x, y = b.y - rect.y
            let (glass, deep) = colours[i % colours.count]
            c.plot(x, y, .neutral3)
            c.fill(ArtRect(x - 1, y + 1, 3, 2), lit ? glass : deep)
            c.plot(x, y + 3, lit ? deep : deep.darker())
            c.plot(x - 1, y + 1, lit ? .neutral9 : glass)
        }
        return SpriteAsset(lit ? "decor.stringLights.lit" : "decor.stringLights", c, anchor: .zero)
    }

    // MARK: Crown moulding

    public static func crown(width: Int) -> SpriteAsset {
        var c = PixelCanvas(width: width, height: 6, fill: .neutral9)
        c.hline(x: 0, y: 0, length: width, .neutral7)
        c.hline(x: 0, y: 2, length: width, .neutral8)
        c.hline(x: 0, y: 4, length: width, .neutral8)
        c.hline(x: 0, y: 5, length: width, .neutral7)
        return SpriteAsset("decor.crown", c, anchor: .zero)
    }
}

// MARK: - Window

/// The window, its sky by phase (clouds drift 1 px per minute; stars and moon at night) and the blinds.
public enum WindowArt {
    /// Local geometry inside the 84×96 window rect.
    static let casing = ArtRect(2, 0, 80, 90)
    static let glass = ArtRect(6, 4, 72, 82)
    static let blindsBottom = 34
    static let sill = ArtRect(0, 87, 84, 7)

    /// The sky visible under the blinds, in the coordinates of `window` (pass core or canvas rects).
    public static func skyRect(in window: ArtRect) -> ArtRect {
        ArtRect(window.x + glass.x, window.y + blindsBottom + 3, glass.w, glass.maxY - blindsBottom - 3)
    }

    /// The whole window for a sky variant at `minuteOfDay`.
    public static func window(sky: SkyVariant, minuteOfDay: Int, blindsDown: Int? = nil) -> SpriteAsset {
        let r = CoreLayout.window
        var c = PixelCanvas(width: r.w, height: r.h)
        let skyArea = ArtRect(glass.x, glass.y, glass.w, glass.h)
        c.blit(skyImage(sky, size: skyArea.size, minuteOfDay: minuteOfDay), at: skyArea.origin)

        // Mullion and a glass glint.
        let mx = glass.x + glass.w / 2 - 1
        c.fill(ArtRect(mx, glass.y, 2, glass.h), .neutral9)
        c.vline(x: mx + 1, y: glass.y, length: glass.h, .neutral8)
        if sky == .day || sky == .dawn {
            for i in 0..<10 {
                c.plot(glass.x + 50 + i, glass.maxY - 6 - i, .blue5)
                c.plot(glass.x + 53 + i, glass.maxY - 6 - i, .neutral9)
            }
        }

        // Casing: painted wood, lit from the top-left.
        let cs = casing
        for i in 0..<4 {
            c.stroke(cs.insetBy(i, i), i == 3 ? .neutral7 : .neutral9)
        }
        c.hline(x: cs.x + 1, y: cs.maxY - 2, length: cs.w - 2, .neutral8)
        c.vline(x: cs.maxX - 2, y: cs.y + 1, length: cs.h - 2, .neutral8)
        c.stroke(cs, .neutral6)
        c.hline(x: cs.x + 3, y: cs.y + 3, length: cs.w - 6, .neutral7)

        drawBlinds(&c, bottom: blindsDown ?? blindsBottom)

        // Sill: top face, front face, dark lip.
        let s = sill
        c.fill(s, .neutral8)
        c.hline(x: s.x, y: s.y, length: s.w, .neutral6)
        c.fill(ArtRect(s.x, s.y + 1, s.w, 2), .neutral9)
        c.hline(x: s.x, y: s.y + 3, length: s.w, .neutral8)
        c.hline(x: s.x, y: s.maxY - 2, length: s.w, .neutral7)
        c.hline(x: s.x, y: s.maxY - 1, length: s.w, .neutral6)
        c.vline(x: s.x, y: s.y, length: s.h, .neutral6)
        c.vline(x: s.maxX - 1, y: s.y, length: s.h, .neutral6)
        let skyName = "window.\(sky.rawValue)"
        return SpriteAsset(skyName, c, anchor: .zero, hitRects: ["sky": skyRect(in: ArtRect(0, 0, r.w, r.h))])
    }

    /// Venetian blinds pulled down to local y `bottom`: headrail, slats, bottom rail, cord.
    static func drawBlinds(_ c: inout PixelCanvas, bottom: Int) {
        let x0 = glass.x - 1, w = glass.w + 2
        c.fill(ArtRect(x0, glass.y, w, 3), .neutral9)
        c.hline(x: x0, y: glass.y + 2, length: w, .neutral7)
        var y = glass.y + 3
        while y + 3 <= bottom {
            c.hline(x: x0 + 1, y: y, length: w - 2, .neutral9)
            c.hline(x: x0 + 1, y: y + 1, length: w - 2, .neutral8)
            c.hline(x: x0 + 1, y: y + 2, length: w - 2, .neutral7)
            y += 3
        }
        c.fill(ArtRect(x0, y, w, 3), .neutral8)
        c.hline(x: x0, y: y, length: w, .neutral9)
        c.hline(x: x0, y: y + 2, length: w, .neutral6)
        // Ladder strings and the pull cord with its tassel.
        for lx in [x0 + 12, x0 + w - 13] { c.vline(x: lx, y: glass.y + 3, length: y - glass.y - 3, .neutral8) }
        let cord = x0 + w - 6
        c.vline(x: cord, y: y + 3, length: 14, .neutral6)
        c.fill(ArtRect(cord - 1, y + 17, 3, 4), .neutral7)
        c.plot(cord - 1, y + 17, .neutral9)
    }

    /// The sky behind the glass.
    public static func skyImage(_ sky: SkyVariant, size: ArtSize, minuteOfDay: Int) -> PixelBuffer {
        var c = PixelCanvas(width: size.w, height: size.h)
        let full = c.bounds
        switch sky {
        case .day:
            c.gradientV(full, inks: [.blue3, .blue4, .blue4, .blue5])
        case .dusk:
            c.gradientV(full, inks: [.purple1, .purple2, .purple4, .red4, .walnut4, .walnut5])
        case .dawn:
            c.gradientV(full, inks: [.blue2, .purple3, .purple5, .red5, .walnut5])
        case .night:
            c.gradientV(full, inks: [.blue0, .blue0, .purple0, .blue1])
            for i in 0..<26 {
                let x = ArtKit.noise(i, 1, seed: 77, size.w), y = ArtKit.noise(i, 2, seed: 77, size.h * 2 / 3)
                c.plot(x, y, i % 4 == 0 ? .blue5 : (i % 3 == 0 ? .neutral6 : .neutral9))
                if i % 9 == 0 {
                    c.plot(x - 1, y, .blue3)
                    c.plot(x + 1, y, .blue3)
                    c.plot(x, y - 1, .blue3)
                    c.plot(x, y + 1, .blue3)
                }
            }
        }
        // The sun low at dusk / dawn, the moon at night.
        if sky == .dusk || sky == .dawn {
            let sx = sky == .dusk ? size.w - 22 : 10
            c.ellipseFill(ArtRect(sx, size.h - 34, 14, 14), .walnut5)
            c.ellipseFill(ArtRect(sx + 2, size.h - 32, 10, 10), .neutral9)
        }
        if sky == .night {
            let mx = size.w - 22, my = 44
            c.ellipseFill(ArtRect(mx, my, 11, 11), .walnut5)
            c.ellipseFill(ArtRect(mx + 1, my + 1, 6, 6), .neutral9)
            c.ellipseFill(ArtRect(mx + 4, my - 1, 10, 10), .blue0)
        }
        // Clouds drift right 1 px per minute.
        let cloudInks: (Ink, Ink, Ink)
        switch sky {
        case .day: cloudInks = (.neutral9, .neutral8, .blue5)
        case .dusk: cloudInks = (.red5, .purple4, .purple3)
        case .dawn: cloudInks = (.neutral9, .purple5, .purple4)
        case .night: cloudInks = (.blue2, .blue1, .purple0)
        }
        let period = size.w + 40
        for (i, base) in [(0, 6), (1, 50), (2, 24)] {
            let w = [30, 22, 16][i], cy = [36, 50, 62][i]
            let x = ((base + minuteOfDay * (i == 1 ? 1 : 1) + i * 37) % period) - 30
            drawCloud(&c, x: x, y: cy, w: w, inks: cloudInks)
        }
        // Distant trees along the bottom of the glass.
        let treeInks: (Ink, Ink)
        switch sky {
        case .day: treeInks = (.green2, .green3)
        case .dusk: treeInks = (.purple1, .purple2)
        case .dawn: treeInks = (.purple2, .purple3)
        case .night: treeInks = (.blue0, .purple0)
        }
        var x = -4
        var i = 0
        while x < size.w {
            let r = 4 + ArtKit.noise(i, 1, seed: 21, 4)
            let top = size.h - 4 - r - ArtKit.noise(i, 2, seed: 21, 3)
            c.ellipseFill(ArtRect(x, top, r * 2, r * 2 + 6), treeInks.0)
            c.ellipseFill(ArtRect(x + 2, top + 1, r, r - 1), treeInks.1)
            x += r + 3
            i += 1
        }
        c.fill(ArtRect(0, size.h - 4, size.w, 4), treeInks.0)
        if sky == .night {
            // A few lit windows in a distant house.
            c.fill(ArtRect(14, size.h - 12, 12, 9), .blue1)
            c.fill(ArtRect(16, size.h - 10, 2, 2), .walnut4)
            c.fill(ArtRect(21, size.h - 10, 2, 2), .walnut5)
        }
        return c.buffer
    }

    static func drawCloud(_ c: inout PixelCanvas, x: Int, y: Int, w: Int, inks: (Ink, Ink, Ink)) {
        let h = w / 3
        c.ellipseFill(ArtRect(x, y, w, h + 2), inks.2)
        c.ellipseFill(ArtRect(x + 2, y - 1, w - 4, h), inks.1)
        c.ellipseFill(ArtRect(x + w / 5, y - h / 2 - 1, w / 2, h + 1), inks.0)
        c.ellipseFill(ArtRect(x + w / 2, y - h / 3 - 1, w / 3, h), inks.0)
        c.hline(x: x + 3, y: y + h, length: w - 6, inks.2)
    }

}

extension RoomArt {
    static func sine(_ x: Double) -> Double { sin(x) }
}

// MARK: - Wall decor

/// Procedural decor for the margins (`LayoutSolver` decides what fits): shelf, framed print, pegboard,
/// painting and floor plant. Each takes its solved rect's size.
public enum DecorArt {
    /// The decor sprite for a solved placement (string lights depend on the light, so pass `lit`).
    public static func sprite(_ d: WallDecor, lit: Bool = false) -> SpriteAsset {
        switch d.kind {
        case .stringLights: RoomArt.stringLights(d.rect, lit: lit)
        case .shelf: shelf(d.rect.size)
        case .frame: frame(d.rect.size)
        case .pegboard: pegboard(d.rect.size)
        case .painting: painting(d.rect.size)
        case .floorPlant: floorPlant(d.rect.size)
        case .crown: RoomArt.crown(width: d.rect.w)
        case .pendant: pendant(d.rect.size, lit: lit)
        case .hangingPlant: hangingPlant(d.rect.size)
        }
    }

    /// The pendant's bulb (sprite-local), emissive when the room light is on in the dark.
    public static func pendantBulb(in size: ArtSize) -> ArtRect { ArtRect(size.w / 2 - 3, size.h - 3, 6, 3) }

    /// A mustard enamel pendant lamp on a long cord.
    public static func pendant(_ size: ArtSize, lit: Bool) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h)
        let cx = size.w / 2
        c.fill(ArtRect(cx - 3, 0, 6, 2), .neutral7)
        c.vline(x: cx, y: 2, length: size.h - 14, .neutral3)
        let top = size.h - 12
        c.fill(ArtRect(cx - 2, top, 4, 3), .neutral4)
        // Dome shade.
        c.ellipseFill(ArtRect(0, top + 2, size.w, 14), .walnut2)
        c.ellipseFill(ArtRect(1, top + 2, size.w - 2, 12), .walnut4)
        c.ellipseFill(ArtRect(3, top + 3, size.w / 2 - 2, 5), .walnut5)
        c.fill(ArtRect(0, size.h - 4, size.w, 4), .clear)
        c.hline(x: 0, y: size.h - 5, length: size.w, .walnut2)
        let bulb = pendantBulb(in: size)
        c.fill(bulb, lit ? .neutral9 : .neutral7)
        c.hline(x: bulb.x + 1, y: bulb.maxY - 1, length: bulb.w - 2, lit ? .walnut5 : .neutral6)
        return SpriteAsset(lit ? "decor.pendant.lit" : "decor.pendant", c, anchor: .zero)
    }

    /// A pothos in a macramé hanger.
    public static func hangingPlant(_ size: ArtSize) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h)
        let cx = size.w / 2
        let potTop = size.h - 26
        c.fill(ArtRect(cx - 2, 0, 4, 2), .neutral7)
        c.vline(x: cx, y: 2, length: potTop - 14, .oak4)
        let knot = potTop - 12
        c.fill(ArtRect(cx - 1, knot, 3, 3), .oak3)
        for dx in [-6, 0, 6] {
            c.line(from: ArtPoint(cx, knot + 2), to: ArtPoint(cx + dx, potTop + 1), .oak4)
        }
        var foliage = PixelCanvas(width: size.w, height: size.h)
        for (dx, dy) in [(-9, -4), (-5, -6), (0, -7), (4, -6), (7, -4), (-10, 0), (8, 0)] {
            leaf(&foliage, cx + dx, potTop + dy)
        }
        for (vx, len, dir) in [(cx - 7, 20, -1), (cx + 2, 14, 1), (cx + 7, 22, 1)] {
            for i in 0..<len {
                let y = potTop + 8 + i, xx = vx + ((i / 5) % 2 == 0 ? 0 : dir)
                guard y < size.h - 2 else { break }
                foliage.plot(xx, y, .green1)
                if i % 3 == 1 { leaf(&foliage, i % 2 == 0 ? xx - 3 : xx + 1, y) }
            }
        }
        c.blit(ArtKit.outline(foliage.buffer, .green0).cropped(to: ArtRect(1, 1, size.w, size.h)), at: .zero)
        c.blit(foliage.buffer, at: .zero)
        let pot = ArtRect(cx - 6, potTop, 12, 9)
        c.roundedRectFill(pot, radius: 2, .neutral6)
        c.fill(pot.insetBy(1, 0), .neutral9)
        c.vline(x: pot.maxX - 2, y: pot.y + 1, length: pot.h - 2, .neutral8)
        c.hline(x: pot.x + 1, y: pot.y + 3, length: pot.w - 2, .oak4)
        c.hline(x: pot.x, y: pot.y, length: pot.w, .neutral8)
        return SpriteAsset("decor.hangingPlant", c, anchor: .zero)
    }

    /// Floating shelf: books, a framed photo and a trailing pothos over the edge.
    public static func shelf(_ size: ArtSize) -> SpriteAsset {
        let w = size.w
        var c = PixelCanvas(width: w, height: size.h)
        let boardY = 22
        // Brackets.
        for x in [5, w - 8] {
            c.fill(ArtRect(x, boardY + 4, 3, 7), .neutral3)
            c.vline(x: x, y: boardY + 4, length: 7, .neutral5)
            c.line(from: ArtPoint(x + 1, boardY + 10), to: ArtPoint(x + 1, boardY + 4), .neutral4)
        }
        // Books, left to right.
        let books: [(w: Int, h: Int, ink: Ink)] = [
            (4, 18, .red3), (3, 20, .blue2), (5, 17, .oak4), (3, 19, .green2), (4, 15, .purple3), (3, 18, .walnut4),
        ]
        var x = 3
        let shelfLimit = w - 30
        for (i, b) in books.enumerated() where x + b.w < shelfLimit && i < max(3, (w - 30) / 7) {
            let r = ArtRect(x, boardY - b.h, b.w, b.h)
            c.fill(r, b.ink)
            c.vline(x: r.x, y: r.y, length: r.h, b.ink.lighter())
            c.vline(x: r.maxX - 1, y: r.y, length: r.h, b.ink.darker())
            c.hline(x: r.x, y: r.y, length: r.w, b.ink.darker(2))
            c.hline(x: r.x, y: r.y + 3, length: r.w, b.ink == .oak4 ? .walnut3 : .walnut5)
            c.hline(x: r.x, y: r.maxY - 4, length: r.w, b.ink.darker())
            x += b.w
        }
        // A leaning book and a bookend gap.
        let lean = [ArtPoint(x + 1, boardY), ArtPoint(x + 5, boardY), ArtPoint(x + 12, boardY - 15), ArtPoint(x + 8, boardY - 16)]
        c.polygonFill(lean, .blue3)
        c.line(from: ArtPoint(x + 2, boardY - 1), to: ArtPoint(x + 9, boardY - 15), .blue4)
        c.line(from: ArtPoint(x + 5, boardY - 1), to: ArtPoint(x + 11, boardY - 14), .blue1)
        x += 15
        // Framed photo.
        if x + 11 < w - 14 {
            let f = ArtRect(x, boardY - 13, 10, 13)
            c.fill(f, .oak1)
            c.fill(f.insetBy(1, 1), .neutral9)
            let pic = f.insetBy(2, 2)
            c.fill(pic, .blue4)
            c.fill(ArtRect(pic.x, pic.maxY - 3, pic.w, 3), .green3)
            c.fill(ArtRect(pic.x + 2, pic.y + 2, 2, 4), .red4)
            c.plot(pic.x + 2, pic.y + 1, .oak3)
            c.plot(pic.x + 3, pic.y + 1, .oak3)
            x += 12
        }
        // Pothos in a little white pot at the right end; two vines trail down past the board.
        let px = w - 14
        var foliage = PixelCanvas(width: w, height: size.h)
        let mound: [(Int, Int)] = [(-3, -11), (0, -14), (4, -15), (8, -13), (10, -10), (-4, -8), (2, -11), (6, -10)]
        for (dx, dy) in mound { leaf(&foliage, px + dx, boardY + dy) }
        for (vx, len, dir) in [(px + 1, 14, -1), (px + 8, 10, 1)] {
            for i in 0..<len {
                let y = boardY + 4 + i, xx = vx + ((i / 4) % 2 == 0 ? 0 : dir)
                foliage.plot(xx, y, .green1)
                if i % 3 == 1 { leaf(&foliage, i % 2 == 0 ? xx - 3 : xx + 1, y) }
            }
            leaf(&foliage, vx - 1, boardY + 4 + len)
        }
        c.blit(ArtKit.outline(foliage.buffer, .green0).cropped(to: ArtRect(1, 1, w, size.h)), at: .zero)
        c.blit(foliage.buffer, at: .zero)
        c.fill(ArtRect(px, boardY - 7, 10, 7), .neutral8)
        c.fill(ArtRect(px + 1, boardY - 7, 6, 6), .neutral9)
        c.hline(x: px, y: boardY - 7, length: 10, .neutral9)
        c.vline(x: px + 9, y: boardY - 7, length: 7, .neutral6)
        c.vline(x: px - 1, y: boardY - 6, length: 6, .neutral6)
        c.hline(x: px + 1, y: boardY - 3, length: 8, .oak4)
        // Board drawn last so the books and pot stand on it.
        c.fill(ArtRect(0, boardY, w, 4), .oak3)
        c.hline(x: 0, y: boardY, length: w, .oak5)
        c.hline(x: 0, y: boardY + 1, length: w, .oak4)
        c.hline(x: 0, y: boardY + 3, length: w, .oak1)
        c.vline(x: w - 1, y: boardY, length: 4, .oak1)
        for vx in [px + 1, px + 8] { c.vline(x: vx, y: boardY, length: 4, .green1) }
        return SpriteAsset("decor.shelf", c, anchor: .zero)
    }

    /// A small heart-shaped pothos leaf (3×3).
    static func leaf(_ c: inout PixelCanvas, _ x: Int, _ y: Int) {
        c.fill(ArtRect(x, y, 3, 2), .green3)
        c.plot(x, y, .green4)
        c.plot(x + 1, y, .green4)
        c.plot(x + 2, y + 1, .green2)
        c.plot(x + 1, y + 2, .green2)
    }

    /// A framed mid-century print (rainbow arches over a sun).
    public static func frame(_ size: ArtSize) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h)
        c.fill(c.bounds, .oak1)
        c.stroke(c.bounds, .oak0)
        c.hline(x: 1, y: 1, length: size.w - 2, .oak2)
        c.vline(x: 1, y: 1, length: size.h - 2, .oak2)
        let mat = c.bounds.insetBy(2, 2)
        c.fill(mat, .neutral9)
        let art = mat.insetBy(3, 3)
        c.fill(art, .oak5)
        let cx = art.midX, base = art.maxY - 4
        for (i, ink) in [Ink.red4, .walnut4, .blue3, .green3].enumerated() {
            let rr = art.w / 2 - 1 - i * 2
            guard rr > 1 else { break }
            c.ellipseFill(ArtRect(cx - rr, base - rr, rr * 2, rr * 2), ink)
        }
        let s = max(2, art.w / 2 - 9)
        c.ellipseFill(ArtRect(cx - s, base - s, s * 2, s * 2), .oak5)
        c.fill(ArtRect(art.x, base, art.w, art.maxY - base), .oak5)
        c.ellipseFill(ArtRect(cx - 3, art.y + 3, 6, 6), .walnut4)
        c.hline(x: art.x + 2, y: art.maxY - 2, length: art.w - 4, .oak3)
        c.hline(x: mat.x, y: mat.maxY - 1, length: mat.w, .neutral8)
        return SpriteAsset("decor.frame", c, anchor: .zero)
    }

    /// A white pegboard with headphones, scissors and a ruler.
    public static func pegboard(_ size: ArtSize) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h)
        c.fill(c.bounds, .neutral8)
        c.fill(c.bounds.insetBy(1, 1), .neutral9)
        c.vline(x: size.w - 2, y: 1, length: size.h - 2, .neutral8)
        c.hline(x: 1, y: size.h - 2, length: size.w - 2, .neutral8)
        for y in stride(from: 3, to: size.h - 2, by: 4) {
            for x in stride(from: 3, to: size.w - 2, by: 4) { c.plot(x, y, .neutral7) }
        }
        // Headphones on a hook.
        let hx = 4, hy = 7
        c.plot(hx + 8, hy - 3, .neutral4)
        c.plot(hx + 8, hy - 2, .neutral4)
        var band = PixelCanvas(width: 18, height: 18)
        band.ellipseStroke(ArtRect(0, 0, 18, 18), .neutral2)
        band.ellipseStroke(ArtRect(1, 1, 16, 16), .neutral3)
        c.blit(band.buffer.cropped(to: ArtRect(0, 0, 18, 9)), at: ArtPoint(hx, hy - 1))
        for ex in [hx - 1, hx + 14] {
            c.roundedRectFill(ArtRect(ex, hy + 7, 5, 8), radius: 1, .purple1)
            c.fill(ArtRect(ex + 1, hy + 8, 3, 6), .purple3)
            c.vline(x: ex + 1, y: hy + 8, length: 6, .purple4)
        }
        // Ruler.
        if size.w >= 34 {
            let rx = size.w - 9
            c.fill(ArtRect(rx, 4, 5, size.h - 10), .walnut4)
            c.vline(x: rx, y: 4, length: size.h - 10, .walnut5)
            c.vline(x: rx + 4, y: 4, length: size.h - 10, .walnut2)
            for y in stride(from: 6, to: size.h - 7, by: 2) { c.hline(x: rx + 2, y: y, length: y % 4 == 2 ? 2 : 1, .walnut1) }
        }
        // Scissors.
        let sx = 6, sy = size.h - 16
        c.line(from: ArtPoint(sx + 4, sy), to: ArtPoint(sx + 9, sy + 9), .neutral6)
        c.line(from: ArtPoint(sx + 9, sy), to: ArtPoint(sx + 4, sy + 9), .neutral5)
        c.ellipseStroke(ArtRect(sx, sy + 9, 6, 5), .red3)
        c.ellipseStroke(ArtRect(sx + 7, sy + 9, 6, 5), .red3)
        c.plot(sx + 6, sy + 5, .neutral3)
        return SpriteAsset("decor.pegboard", c, anchor: .zero)
    }

    /// A landscape painting for tall walls: mountains over a lake.
    public static func painting(_ size: ArtSize) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h)
        c.fill(c.bounds, .walnut2)
        c.stroke(c.bounds, .walnut0)
        c.stroke(c.bounds.insetBy(1, 1), .walnut3)
        c.hline(x: 2, y: 2, length: size.w - 4, .walnut4)
        let art = c.bounds.insetBy(4, 4)
        var a = PixelCanvas(width: art.w, height: art.h, artOrigin: art.origin)
        a.gradientV(a.bounds, inks: [.blue3, .blue4, .blue5])
        let horizon = art.h * 3 / 5
        for x in 0..<art.w {
            let m1 = horizon - 4 - Int(14 * abs(RoomArt.sine(Double(x) / 18))) - (x % 7 == 0 ? 1 : 0)
            a.vline(x: x, y: m1, length: horizon - m1, .purple2)
            if horizon - m1 > 12 { a.vline(x: x, y: m1, length: 2, .neutral9) }
            let m2 = horizon - 2 - Int(7 * abs(RoomArt.sine(Double(x) / 11 + 1)))
            a.vline(x: x, y: m2, length: horizon - m2, .purple3)
        }
        a.fill(ArtRect(0, horizon, art.w, art.h - horizon), .blue3)
        for y in stride(from: horizon + 2, to: art.h, by: 3) {
            a.hline(x: (y * 7) % 20, y: y, length: 8, .blue4)
            a.hline(x: (y * 7) % 20 + 34, y: y, length: 6, .blue4)
        }
        a.fill(ArtRect(0, art.h - 5, art.w, 5), .green2)
        for x in stride(from: 2, to: art.w, by: 9) {
            a.fill(ArtRect(x, art.h - 9, 3, 5), .green1)
            a.plot(x + 1, art.h - 10, .green1)
        }
        c.blit(a.buffer, at: art.origin)
        return SpriteAsset("decor.painting", c, anchor: .zero)
    }

    /// A fiddle-leaf fig in a woven basket, standing on the floor line.
    public static func floorPlant(_ size: ArtSize) -> SpriteAsset {
        let w = size.w, h = size.h
        var leaves = PixelCanvas(width: w, height: h)
        let cx = w / 2
        // Trunk with a couple of side branches.
        for y in 8..<(h - 14) {
            let x = cx + Int(2 * RoomArt.sine(Double(y) / 13))
            leaves.plot(x, y, .walnut1)
            leaves.plot(x + 1, y, .walnut2)
        }
        // Big fiddle leaves: (centre dx, centre y as a fraction of 92, w, h); larger and denser toward the top.
        let spots: [(Int, Int, Int, Int)] = [
            (0, 6, 10, 11), (-8, 12, 10, 10), (8, 13, 10, 10), (-12, 22, 10, 9), (2, 20, 11, 10), (11, 25, 10, 9),
            (-6, 31, 10, 10), (7, 34, 10, 9), (-11, 42, 9, 9), (2, 43, 10, 9), (10, 48, 9, 8), (-7, 53, 9, 9),
            (4, 57, 9, 8), (-10, 63, 8, 8), (8, 66, 8, 7),
        ]
        for (i, s) in spots.enumerated() {
            let x = cx + s.0 * w / 38 - s.2 / 2, y = s.1 * h / 92
            let r = ArtRect(x, y, s.2, s.3)
            let dark = i % 3 == 1
            leaves.ellipseFill(r, dark ? .green2 : .green3)
            leaves.ellipseFill(ArtRect(r.x + 1, r.y + 1, r.w / 2 + 1, r.h / 2), dark ? .green3 : .green4)
            leaves.plot(r.x + 2, r.y + 2, .green5)
            leaves.line(from: ArtPoint(r.midX, r.y + 2), to: ArtPoint(r.midX + (s.0 < 0 ? 1 : -1), r.maxY - 2), .green1)
        }
        var c = PixelCanvas(width: w, height: h)
        c.blit(ArtKit.outline(leaves.buffer, .green0).cropped(to: ArtRect(1, 1, w, h)), at: .zero)
        c.blit(leaves.buffer, at: .zero)
        // Woven basket.
        let pot = ArtRect(cx - 10, h - 16, 21, 16)
        c.roundedRectFill(pot, radius: 2, .oak1)
        c.fill(pot.insetBy(1, 1), .oak3)
        for y in stride(from: pot.y + 2, to: pot.maxY - 1, by: 3) {
            c.hline(x: pot.x + 1, y: y, length: pot.w - 2, .oak2)
            for x in stride(from: pot.x + 1 + (y / 3) % 2 * 2, to: pot.maxX - 1, by: 4) { c.plot(x, y - 1, .oak4) }
        }
        c.hline(x: pot.x, y: pot.y, length: pot.w, .oak4)
        c.hline(x: pot.x + 1, y: pot.y + 1, length: pot.w - 2, .oak5)
        c.vline(x: pot.maxX - 2, y: pot.y + 2, length: pot.h - 3, .oak2)
        return SpriteAsset("decor.floorPlant", c, anchor: ArtPoint(cx, h))
    }
}

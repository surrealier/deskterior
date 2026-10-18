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
    /// desk top face, and the soft shadows that wall pieces, back-strip props and floor furniture cast. `stowed`:
    /// the objects put away, whose shadows go with them (Erratum 30).
    public static func backdrop(_ layout: SceneLayout, stowed: Set<StowID> = []) -> PixelBuffer {
        let w = layout.canvas.w, h = layout.canvas.h
        var c = PixelCanvas(width: w, height: h, fill: wall)
        let base = layout.wallBaseY
        let desk = layout.rect(CoreLayout.deskTop)

        drawShell(&c, layout: layout)
        drawFloor(&c, from: base, layout: layout)
        drawUnderDeskShade(&c, layout: layout)
        drawRug(&c, layout: layout)
        drawFloorShadows(&c, layout: layout, cabinet: !stowed.contains(.cabinet))

        // Contact shadow on the wall just above the desk's back edge.
        for x in desk.minX..<desk.maxX where c.ink(at: x, desk.y - 1) == wall { c.plot(x, desk.y - 1, wallShade) }
        c.blit(deskSurface(skipping: stowed), at: desk.origin)
        drawWallShadows(&c, layout, partition: !stowed.contains(.partition))
        return c.buffer
    }

    /// The wainscot with its chair rail and raised panels (visible beside and under the desk), and the baseboard,
    /// over a canvas filled with the wall colour. The desk's room and the other displays' walls (`WallArt`) share it.
    static func drawShell(_ c: inout PixelCanvas, layout: SceneLayout) {
        let w = c.width
        let base = layout.wallBaseY
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
    }

    /// The desk top face in desk-local px, with the contact shadows of the back-strip props (the keyboard's is a
    /// sprite of its own, `keyboardShadow`, since it rides on the mat). It is the same for every layout, so it is
    /// built once.
    static let deskSurface: PixelBuffer = deskSurface(skipping: [])

    // MARK: tidy (0.3.0)
    /// The desk top face without the shadows of the back-strip props put away (only the plant and the phone stand cast
    /// one that can go, Erratum 30).
    static func deskSurface(skipping stowed: Set<StowID>) -> PixelBuffer {
        deskSurfaces[stowed.intersection(shadowCasters)]!
    }

    /// The back-strip props that can be put away.
    static let shadowCasters: Set<StowID> = [.plant, .phoneStand]

    /// The desk top for each subset of `shadowCasters`, built once on first use.
    private static let deskSurfaces: [Set<StowID>: PixelBuffer] = {
        let d = CoreLayout.deskTop
        var table: [Set<StowID>: PixelBuffer] = [:]
        for skipped in [[], [StowID.plant], [.phoneStand], [.plant, .phoneStand]] as [Set<StowID>] {
            var c = PixelCanvas(width: d.w, height: d.h)
            drawDeskTop(&c, c.bounds)
            drawDeskShadows(&c, offset: ArtPoint(-d.x, -d.y), skipping: skipped)
            table[skipped] = c.buffer
        }
        return table
    }()

    /// The keyboard's contact shadow on the bare desk (one oak step darker: a row under its front face and a column on
    /// its right), with its top-left at `CoreLayout.keyboard.origin`. The bare room draws it where the backdrop once
    /// had it baked in; the scene's desk mat, which the keyboard rides on, draws its own on the felt instead.
    public static func keyboardShadow() -> SpriteAsset { keyboardShadowSprite }

    private static let keyboardShadowSprite: SpriteAsset = {
        let d = CoreLayout.deskTop, k = CoreLayout.keyboard
        let base = PixelCanvas(deskSurface)
        var shaded = base
        ArtKit.castShadow(of: PropArt.keyboard().image, at: ArtPoint(k.x - d.x, k.y - d.y), offset: ArtPoint(1, 1),
                          ink: Role.deskEdge, into: &shaded, where: { $0 == Role.desk || $0 == Role.deskHighlight })
        var c = PixelCanvas(width: k.w + 1, height: k.h + 1)
        for y in 0..<c.height {
            for x in 0..<c.width {
                let p = ArtPoint(k.x - d.x + x, k.y - d.y + y)
                if let ink = shaded.ink(at: p.x, p.y), ink != base.ink(at: p.x, p.y) { c.plot(x, y, ink) }
            }
        }
        return SpriteAsset("keyboard.shadow", c, anchor: .zero)
    }()

    /// The floor under the desk darkens toward the wall in two plank-aligned steps (`602c2c`, then `7a4841`),
    /// ending well before the rug; the baseboard between the legs falls into the shadow too.
    static func drawUnderDeskShade(_ c: inout PixelCanvas, layout: SceneLayout) {
        let desk = layout.rect(CoreLayout.deskTop)
        let base = layout.wallBaseY
        let top = layout.y(CoreLayout.apron.maxY)
        // Planks are 6 rows (seam last), so each step ends on a seam.
        let deepEnd = base + 12, midEnd = base + 30
        let deep: [Ink: Ink] = [floorBase: .walnut1, floorSeam: .oak0, floorLight: floorSeam]
        let mid: [Ink: Ink] = [floorBase: floorSeam, floorSeam: .oak0, floorLight: floorBase]
        let board: [Ink: Ink] = [.neutral9: .neutral5, .neutral8: .neutral5, wainscotLine: .neutral4]
        let clip = ArtRect(desk.x, top, desk.w, midEnd - top).intersection(c.bounds)
        guard !clip.isEmpty else { return }
        for y in clip.minY..<clip.maxY {
            let map = y < base ? board : (y < deepEnd ? deep : mid)
            for x in clip.minX..<clip.maxX {
                if let ink = c.ink(at: x, y), let to = map[ink] { c.plot(x, y, to) }
            }
        }
    }

    /// Contact shadows on the floor (one ramp step darker, offset right of the light) under the wastebasket,
    /// the cabinet's plinth and the floor plant's basket; the chair carries its own.
    static func drawFloorShadows(_ c: inout PixelCanvas, layout: SceneLayout, cabinet: Bool = true) {
        func shadow(_ r: ArtRect) {
            var e = PixelCanvas(width: r.w, height: r.h)
            e.ellipseFill(e.bounds, .neutral0)
            for y in 0..<r.h {
                for x in 0..<r.w where e.ink(at: x, y) == .neutral0 {
                    if let ink = c.ink(at: r.x + x, r.y + y), !ink.isClear { c.plot(r.x + x, r.y + y, ink.darker()) }
                }
            }
        }
        let floor = CoreLayout.floorY
        let basket = CoreLayout.wastebasket
        shadow(layout.rect(ArtRect(basket.x - 1, floor - 3, basket.w + 8, 6)))
        let cab = CoreLayout.cabinet
        if cabinet { shadow(layout.rect(ArtRect(cab.x - 2, floor - 3, cab.w + 10, 6))) }
        for d in layout.decor(.floorPlant) {
            let pot = DecorArt.floorPlantPot(d.rect.size).offsetBy(d.rect.x, d.rect.y)
            shadow(ArtRect(pot.x - 2, pot.maxY - 3, pot.w + 7, 5))
        }
    }

    static func drawFloor(_ c: inout PixelCanvas, from top: Int, layout: SceneLayout) {
        let w = c.width
        c.fill(ArtRect(0, top, w, c.height - top), floorBase)
        // Boards run parallel to the wall: 6-row planks (5 board + 1 seam), staggered end joints, a lit
        // bevel on some boards and the odd short grain streak.
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

    /// The rug in front of the desk: a quiet field with a tone-on-tone border and lattice, so it recedes.
    static func drawRug(_ c: inout PixelCanvas, layout: SceneLayout) {
        let r = ArtRect(layout.x(104), layout.y(290), 272, c.height - layout.y(290))
        guard r.h > 2 else { return }
        c.fill(r, .red2)
        c.hline(x: r.x, y: r.y, length: r.w, .red3)
        // Border band and a row of small diamonds.
        let band = ArtRect(r.x + 4, r.y + 3, r.w - 8, r.h)
        c.stroke(ArtRect(band.x, band.y, band.w, band.h + 2), .red3)
        let inner = band.insetBy(3, 3)
        if inner.h > 0 { c.stroke(ArtRect(inner.x, inner.y, inner.w, inner.h + 6), .red1) }
        var x = band.x + 8
        while x + 6 < band.maxX - 4 {
            let cy = band.y + 7
            if cy + 2 < c.height {
                c.plot(x + 2, cy - 2, .red3)
                c.hline(x: x + 1, y: cy - 1, length: 3, .red3)
                c.hline(x: x, y: cy, length: 5, .red3)
                c.plot(x + 2, cy, .red1)
                c.hline(x: x + 1, y: cy + 1, length: 3, .red3)
                c.plot(x + 2, cy + 2, .red3)
            }
            x += 12
        }
        // A sparse lattice of small diamonds in the field.
        var row = 0
        var ly = band.y + 17
        while ly + 1 < c.height {
            var lx = inner.x + 6 + (row % 2) * 6
            while lx + 2 < inner.maxX - 3 {
                c.plot(lx + 1, ly - 1, .red1)
                c.hline(x: lx, y: ly, length: 3, .red1)
                c.plot(lx + 1, ly + 1, .red1)
                lx += 12
            }
            ly += 9
            row += 1
        }
        // Fringe at the back edge.
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
        for i in 0..<4 {
            let y = d.y + 4 + ArtKit.noise(i, 5, seed: 13, d.h - 10)
            let x = d.x + 4 + ArtKit.noise(i, 6, seed: 13, d.w / 3)
            c.hline(x: x, y: y, length: 10 + ArtKit.noise(i, 7, seed: 13, 24), Role.deskHighlight)
        }
        // Back edge meets the wall (a shadow row, then a soft one); front bullnose catches the light.
        c.hline(x: d.x, y: d.y, length: d.w, Role.deskShadow)
        c.hline(x: d.x, y: d.y + 1, length: d.w, Role.deskEdge)
        c.hline(x: d.x, y: d.maxY - 1, length: d.w, Role.deskHighlight)
        c.vline(x: d.x, y: d.y, length: d.h, Role.deskEdge)
        c.vline(x: d.maxX - 1, y: d.y, length: d.h, Role.deskShadow)
        c.plot(d.x, d.maxY - 1, Role.deskHighlight)
    }

    /// Soft wall shadows (down-right of each wall piece, of the monitor and of the partition's tower).
    static func drawWallShadows(_ c: inout PixelCanvas, _ layout: SceneLayout, partition: Bool = true) {
        func drop(_ r: ArtRect, dx: Int, dy: Int, ink: Ink = wallShade) {
            let s = r.offsetBy(dx, dy)
            for y in s.minY..<s.maxY {
                for x in s.minX..<s.maxX where !r.contains(ArtPoint(x, y)) {
                    if c.ink(at: x, y) == wall { c.plot(x, y, ink) }
                }
            }
        }
        let win = layout.rect(CoreLayout.window)
        drop(ArtRect(win.x + 2, win.y, win.w - 4, win.h - 2), dx: 3, dy: 3)
        drop(layout.rect(CoreLayout.calendar), dx: 2, dy: 2)
        // The switch plate is wall-grey itself, so its shadow is a step deeper.
        drop(layout.rect(CoreLayout.roomSwitch), dx: 1, dy: 1, ink: .neutral7)
        let clock = layout.rect(CoreLayout.clock)
        var disc = PixelCanvas(width: clock.w, height: clock.h)
        disc.ellipseFill(disc.bounds, .neutral0)
        ArtKit.castShadow(of: disc.buffer, at: clock.origin, offset: ArtPoint(2, 2), ink: wallShade, into: &c) {
            $0 == wall
        }
        let mon = layout.rect(CoreLayout.monitorBody)
        drop(ArtRect(mon.x, mon.y, mon.w, mon.h - 6), dx: 5, dy: 4)
        // MARK: memos (0.3.0)
        if partition { drop(layout.rect(CoreLayout.partitionTower), dx: 2, dy: 2) }
        for d in layout.decor {
            switch d.kind {
            case .shelf:
                drop(ArtRect(d.rect.x, d.rect.y + 22, d.rect.w, 4), dx: 2, dy: 3)
            case .frame, .pegboard, .painting:
                drop(d.rect, dx: 2, dy: 2)
            case .rail:
                drop(d.rect, dx: 0, dy: 1)
            // MARK: w6-polish
            // The tall wall's pieces cast the same shadows as the lower wall's (Errata 26).
            case .upperShelf:
                drop(DecorArt.upperShelfBoard(in: d.rect.size).offsetBy(d.rect.x, d.rect.y), dx: 2, dy: 3)
            case .gallery:
                for f in DecorArt.galleryFrames(in: d.rect.size) { drop(f.offsetBy(d.rect.x, d.rect.y), dx: 2, dy: 2) }
            case .wallHanging:
                ArtKit.castShadow(of: DecorArt.wallHanging(d.rect.size).image, at: d.rect.origin,
                                  offset: ArtPoint(2, 2), ink: wallShade, into: &c) { $0 == wall }
            default:
                break
            }
        }
    }

    /// Contact shadows on the desk top (one oak step darker, onto bare desk only): the back-strip props cast
    /// theirs down-right (the keyboard's is `keyboardShadow`).
    /// `offset` moves core px into the canvas being drawn.
    /// `skipping`: the plant's or phone stand's shadow is left out while it is put away.
    static func drawDeskShadows(_ c: inout PixelCanvas, offset: ArtPoint, skipping: Set<StowID> = []) {
        func onDesk(_ i: Ink) -> Bool { i == Role.desk || i == Role.deskHighlight }
        var props: [(PixelBuffer, ArtRect, ArtPoint)] = [
            (StorageArt.riser().image, CoreLayout.riser, ArtPoint(3, 2)),
            (MonitorArt.stand().image, MonitorArt.standRect, ArtPoint(3, 2)),
        ]
        if !skipping.contains(.plant) { props.append((PropArt.plant().image, CoreLayout.plant, ArtPoint(3, 2))) }
        if !skipping.contains(.phoneStand) {
            props.append((PropArt.phoneStand(faceUp: true).image, PropArt.phoneStandRect, ArtPoint(3, 2)))
        }
        props += [
            (PropArt.driveHub().image, CoreLayout.driveHub, ArtPoint(3, 2)),
            (PropArt.lamp(on: false).image, PropArt.lampRect, ArtPoint(3, 2)),
        ]
        for (img, core, shift) in props {
            ArtKit.castShadow(of: img, at: core.origin + offset, offset: shift, ink: Role.deskEdge, into: &c, where: onDesk)
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

    /// The room light switch: a grey plate with a dark outline (its wall shadow is in the backdrop) and a 2×3
    /// toggle at the top of its slot when on, at the bottom when off.
    public static func roomSwitch(on: Bool) -> SpriteAsset {
        let r = CoreLayout.roomSwitch
        var c = PixelCanvas(width: r.w, height: r.h)
        c.roundedRectFill(c.bounds, radius: 1, .neutral5)
        c.fill(c.bounds.insetBy(1, 1), .neutral8)
        c.hline(x: 1, y: 1, length: r.w - 3, .neutral9)
        c.vline(x: 1, y: 1, length: r.h - 3, .neutral9)
        // Slot and toggle.
        let slot = ArtRect(3, 3, 2, 6)
        c.fill(slot, .neutral7)
        c.fill(ArtRect(slot.x, on ? slot.y : slot.maxY - 3, 2, 3), .neutral4)
        c.plot(slot.x, on ? slot.y : slot.maxY - 3, .neutral5)
        return SpriteAsset(on ? "room.switch.on" : "room.switch.off", c, anchor: .zero)
    }

    // MARK: Clock

    /// The wall clock showing `hour:minute`: a short 2-px hour hand and a long 1-px minute hand, so the two
    /// never fuse.
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
        // Hour hand: 5 px long, doubled across its direction.
        let hourTip = at(hr * 30, 5.2)
        let a = (hr * 30 - 90) * .pi / 180
        let side = abs(cos(a)) > abs(sin(a)) ? ArtPoint(0, 1) : ArtPoint(1, 0)
        c.line(from: centre, to: hourTip, .neutral3)
        c.line(from: centre + side, to: hourTip + side, .neutral3)
        c.line(from: centre, to: at(m * 6, 9.4), .neutral0)
        c.fill(ArtRect(13, 13, 2, 2), .red3)
        c.plot(13, 13, .red4)
        return SpriteAsset("clock", c, anchor: .zero)
    }

    // MARK: Calendar

    static let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// The hanging wall calendar for `date`'s month, with today's cell ringed. `marks`: days with a page, a dated
    /// note or the D-Day (Erratum 31).
    public static func calendar(_ date: WallTime, marks: [Int: CalendarMark] = [:]) -> SpriteAsset {
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
        // Day grid: 7 columns × up to 6 rows of 4-px cells. A day with a page or a dated note is blue, the D-Day
        // purple (Erratum 31); today keeps its red block.
        let grid = calendarGrid(date)
        for day in 1...date.daysInMonth {
            let cell = grid.cell(day)
            let x = cell.x + 1, y = cell.y + 1
            let col = (cell.x - calendarGridOrigin.x) / 4
            let weekend = col == 0 || col == 6
            let mark = marks[day] ?? []
            if day == date.day {
                c.fill(cell, .red4)
                c.hline(x: x, y: y, length: 2, .neutral9)
            } else if !mark.isEmpty {
                let dDay = mark.contains(.dDay)
                c.hline(x: x, y: y, length: 2, dDay ? .purple3 : .blue3)
                if grid.pitch == 4 { c.plot(x, y + 1, dDay ? .purple2 : .blue2) }
            } else {
                c.hline(x: x, y: y, length: 2, weekend ? .red4 : .neutral5)
                if grid.pitch == 4 { c.plot(x, y + 1, weekend ? .red3 : .neutral7) }
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

    /// Top-left of the calendar's day grid (calendar-local px): the first column's cells start here.
    static let calendarGridOrigin = ArtPoint(1, 15)

    /// The month's day grid as the calendar draws it: Sunday first, 4-px columns, rows 4 px apart (3 px when the month
    /// needs six rows). Day cells tile it with no gaps.
    struct CalendarGrid {
        /// Weekday of the 1st (0 = Sunday), the days in the month, the row pitch.
        let first: Int, days: Int, pitch: Int

        /// Day `day`'s cell: 4 px wide, `pitch` tall, its 2-px dash one px in from its top-left.
        func cell(_ day: Int) -> ArtRect {
            let i = first + day - 1
            return ArtRect(calendarGridOrigin.x + i % 7 * 4, calendarGridOrigin.y + i / 7 * pitch, 4, pitch)
        }

        /// The day whose cell holds `p`, if any.
        func day(at p: ArtPoint) -> Int? {
            let dx = p.x - calendarGridOrigin.x, dy = p.y - calendarGridOrigin.y
            guard dx >= 0, dx < 28, dy >= 0 else { return nil }
            let day = dy / pitch * 7 + dx / 4 - first + 1
            return (1...days).contains(day) ? day : nil
        }
    }

    static func calendarGrid(_ date: WallTime) -> CalendarGrid {
        let first = WallTime(year: date.year, month: date.month, day: 1, hour: 0, minute: 0).weekday
        let rows = (first + date.daysInMonth + 6) / 7
        return CalendarGrid(first: first, days: date.daysInMonth, pitch: rows > 5 ? 3 : 4)
    }

    /// Day `day`'s hit cell in the calendar for `date`'s month (calendar-local px); nil for a day not in it.
    public static func calendarDayRect(day: Int, in date: WallTime) -> ArtRect? {
        (1...date.daysInMonth).contains(day) ? calendarGrid(date).cell(day) : nil
    }

    /// The day whose cell holds the calendar-local point `p` in `date`'s month (the inverse of `calendarDayRect`).
    public static func calendarDay(at p: ArtPoint, in date: WallTime) -> Int? {
        calendarGrid(date).day(at: p)
    }

    // MARK: String lights

    /// String lights are lit from dusk to dawn.
    public static func stringLightsLit(_ time: TimeOfDay) -> Bool { time.phase != .day }

    /// The desk lamp's pool and halo show only when the room is dark enough for them (ambient 5 or less).
    public static func lampGlows(_ time: TimeOfDay) -> Bool { time.ambientLevel <= 5 }

    /// Bulb positions (canvas px, the cap above each bulb) for string lights strung across `rect`.
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

    /// The glass of every bulb (canvas px): a 3-px-wide body two rows tall and a tip.
    public static func stringLightGlass(in rect: ArtRect) -> [ArtPoint] {
        stringLightBulbs(in: rect).flatMap { b in
            [ArtPoint(b.x - 1, b.y + 1), ArtPoint(b.x, b.y + 1), ArtPoint(b.x + 1, b.y + 1),
             ArtPoint(b.x - 1, b.y + 2), ArtPoint(b.x, b.y + 2), ArtPoint(b.x + 1, b.y + 2), ArtPoint(b.x, b.y + 3)]
        }
    }

    /// A lit bulb's halo (canvas px and ink): the ring one pixel round its glass, every other pixel by the
    /// Bayer pattern, warm.
    public static func stringLightHalo(in rect: ArtRect) -> [(point: ArtPoint, ink: Ink)] {
        var out: [(point: ArtPoint, ink: Ink)] = []
        for b in stringLightBulbs(in: rect) {
            for y in (b.y + 1)...(b.y + 4) {
                for x in (b.x - 2)...(b.x + 2) {
                    let inGlass = (y <= b.y + 2 && abs(x - b.x) <= 1) || (y == b.y + 3 && x == b.x)
                    guard !inGlass, abs(x - b.x) + abs(y - b.y - 2) <= 3 else { continue }
                    if Dither.pick(x: x, y: y, sixteenths: 8) { out.append((ArtPoint(x, y), y == b.y + 4 ? .walnut3 : .walnut4)) }
                }
            }
        }
        return out
    }

    /// Hook x positions (rect-local) for the spans: about 120 px apart, the inner ones jittered.
    static func stringLightHooks(in rect: ArtRect) -> [Int] {
        let spans = max(1, (rect.w + 60) / 120)
        return (0...spans).map { i in
            let x = min(rect.w - 1, i * rect.w / spans)
            guard i > 0, i < spans else { return x }
            return x + ArtKit.noise(i, rect.w, seed: 61, 13) - 6
        }
    }

    /// Wire y per canvas x: a catenary-ish sag between hooks, each span 0–2 px shallower than the deepest.
    static func stringLightWire(in rect: ArtRect) -> [Int: Int] {
        let sag = max(2, rect.h - 6)
        let hooks = stringLightHooks(in: rect)
        var out: [Int: Int] = [:]
        for s in 0..<(hooks.count - 1) {
            let a = hooks[s], b = max(hooks[s + 1], a + 1)
            let spanSag = Double(max(2, sag - ArtKit.noise(s, rect.w, seed: 67, 3)))
            let end = s == hooks.count - 2 ? rect.w : b
            for lx in a..<end {
                let t = min(1, Double(lx - a) / Double(b - a))
                out[rect.x + lx] = rect.y + Int((spanSag * 4 * t * (1 - t)).rounded())
            }
        }
        return out
    }

    /// Fairy lights across `rect` (sprite in rect-local px). Unlit: grey glass under a coloured cap. Lit: the
    /// glass glows in its colour inside a warm dithered halo.
    public static func stringLights(_ rect: ArtRect, lit: Bool) -> SpriteAsset {
        var c = PixelCanvas(width: rect.w, height: rect.h + 4, artOrigin: rect.origin)
        let wire = stringLightWire(in: rect)
        var prev: ArtPoint?
        for x in rect.x..<rect.maxX {
            let p = ArtPoint(x - rect.x, wire[x]! - rect.y)
            if let q = prev { c.line(from: q, to: p, .neutral4) } else { c.plot(p, .neutral4) }
            prev = p
        }
        for x in stringLightHooks(in: rect) { c.fill(ArtRect(x - 1, 0, 2, 2), .neutral5) }
        if lit {
            for h in stringLightHalo(in: rect) { c.plot(h.point.x - rect.x, h.point.y - rect.y, h.ink) }
        }
        let colours: [(Ink, Ink)] = [(.walnut5, .walnut4), (.red5, .red4), (.green5, .green4), (.walnut5, .walnut4), (.blue5, .blue4)]
        for (i, b) in stringLightBulbs(in: rect).enumerated() {
            let x = b.x - rect.x, y = b.y - rect.y
            let (glass, deep) = colours[i % colours.count]
            if lit {
                c.plot(x, y, .neutral3)
                c.fill(ArtRect(x - 1, y + 1, 3, 2), deep)
                c.plot(x, y + 1, glass)
                c.plot(x - 1, y + 1, .neutral9)
                c.plot(x, y + 3, deep)
            } else {
                c.plot(x, y, deep)
                c.fill(ArtRect(x - 1, y + 1, 3, 2), .neutral5)
                c.plot(x - 1, y + 1, .neutral6)
                c.plot(x, y + 3, .neutral4)
            }
        }
        return SpriteAsset(lit ? "decor.stringLights.lit" : "decor.stringLights", c, anchor: .zero)
    }

    // MARK: Ceiling, crown and rail

    /// Crown moulding where a tall wall meets the ceiling.
    public static func crown(width: Int) -> SpriteAsset {
        var c = PixelCanvas(width: width, height: 6, fill: .neutral9)
        c.hline(x: 0, y: 0, length: width, .neutral7)
        c.hline(x: 0, y: 2, length: width, .neutral8)
        c.hline(x: 0, y: 4, length: width, .neutral8)
        c.hline(x: 0, y: 5, length: width, .neutral7)
        return SpriteAsset("decor.crown", c, anchor: .zero)
    }

    /// The ceiling plane above a tall wall: it darkens in three steps away from the crown (2×2 Bayer bands), its board
    /// joints crowd together toward the far wall, and four oak beams run back to the wall over them (Errata 26).
    public static func ceiling(_ size: ArtSize) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h, fill: .neutral8)
        let inks: [Ink] = [.neutral9, .neutral8, .neutral7]
        let step = max(8, size.h / 3)
        // The band (0 at the crown) each pixel falls in, dithered over the last quarter of a band.
        func band(_ x: Int, _ y: Int) -> Int {
            let d = Double(size.h - 1 - y) / Double(step)
            let band = min(Int(d), inks.count - 1)
            let f = d - Double(band)
            return f > 0.75 && Dither.pick(x: x, y: y, fraction: (f - 0.75) * 4, cell: 2) ? min(band + 1, inks.count - 1) : band
        }
        for y in 0..<size.h {
            for x in 0..<size.w { c.plot(x, y, inks[band(x, y)]) }
        }
        // Joints: gaps grow by a third each board away from the crown.
        var gap = 5.0, y = Double(size.h - 1) - gap
        while y > 0 {
            let row = Int(y)
            for x in 0..<size.w { if let ink = c.ink(at: x, row) { c.plot(x, row, ink.darker()) } }
            gap *= 1.33
            y -= gap
        }
        DecorArt.drawBeams(&c) { y in min(Int(Double(size.h - 1 - y) / Double(step) + 0.125), inks.count - 1) }
        return SpriteAsset("decor.ceiling", c, anchor: .zero)
    }

    /// A picture rail: a lit top edge over a shadowed lip.
    public static func rail(width: Int) -> SpriteAsset {
        var c = PixelCanvas(width: width, height: 3, fill: .neutral8)
        c.hline(x: 0, y: 0, length: width, .neutral9)
        c.hline(x: 0, y: 2, length: width, .neutral7)
        return SpriteAsset("decor.rail", c, anchor: .zero)
    }

    // MARK: Lamp light

    /// The bright core of the lamp's pool inside the pool rect.
    public static func lampPoolCore(_ pool: ArtRect) -> ArtRect {
        ArtRect(pool.x + pool.w / 5, pool.y + pool.h / 5, pool.w * 3 / 5, pool.h * 3 / 5)
    }

    /// The warm centre of the lamp's pool, painted over the desk where the light is brightest: highlights turn
    /// `e8c170` toward the middle and the grain warms to `de9e41`; transparent elsewhere. Canvas-placed at the
    /// pool rect.
    public static func lampPool(_ layout: SceneLayout) -> SpriteAsset {
        let pool = layout.rect(CoreLayout.lampPool)
        let desk = layout.rect(CoreLayout.deskTop)
        var c = PixelCanvas(width: pool.w, height: pool.h, artOrigin: pool.origin)
        let core = lampPoolCore(pool)
        let cx = Double(core.x) + Double(core.w) / 2, cy = Double(core.y) + Double(core.h) / 2
        for y in pool.minY..<pool.maxY {
            for x in pool.minX..<pool.maxX where desk.contains(ArtPoint(x, y)) {
                let dx = (Double(x) + 0.5 - cx) / (Double(core.w) / 2), dy = (Double(y) + 0.5 - cy) / (Double(core.h) / 2)
                let n = (dx * dx + dy * dy).squareRoot()
                guard n < 0.8 else { continue }
                let under = Ink(palette: Apollo.index(of: deskSurface.pixel(x - desk.x, y - desk.y)) ?? 0)
                let hot = n < 0.45 || Dither.pick(x: x, y: y, fraction: (0.8 - n) / 0.35, cell: 2)
                switch under {
                case Role.deskHighlight: c.plot(x - pool.x, y - pool.y, .walnut5)
                case Role.desk where hot: c.plot(x - pool.x, y - pool.y, .walnut5)
                case Role.deskEdge where n < 0.6: c.plot(x - pool.x, y - pool.y, .walnut4)
                default: break
                }
            }
        }
        return SpriteAsset("glow.lampPool", c, anchor: .zero)
    }

    /// The bloom round the lamp's bulb on the wall behind it (canvas px and ink): `e8c170` within 4 px of the
    /// bulb, `de9e41` out to 8, the boundary dithered in 2×2 cells.
    public static func lampHaloPixels(_ layout: SceneLayout) -> [(point: ArtPoint, ink: Ink)] {
        let b = layout.rect(PropArt.lampBulbRect)
        let cx = Double(b.x) + Double(b.w) / 2, cy = Double(b.y) + Double(b.h) / 2
        var out: [(point: ArtPoint, ink: Ink)] = []
        for y in (b.y - 9)...(b.maxY + 9) {
            for x in (b.x - 9)...(b.maxX + 9) {
                let d = ((Double(x) + 0.5 - cx) * (Double(x) + 0.5 - cx) + (Double(y) + 0.5 - cy) * (Double(y) + 0.5 - cy)).squareRoot()
                if d <= 4 || (d <= 5.5 && Dither.pick(x: x, y: y, fraction: (5.5 - d) / 1.5, cell: 2)) {
                    out.append((ArtPoint(x, y), .walnut5))
                } else if d <= 7 || (d <= 8.5 && Dither.pick(x: x, y: y, fraction: (8.5 - d) / 1.5, cell: 2)) {
                    out.append((ArtPoint(x, y), .walnut4))
                }
            }
        }
        return out
    }

    /// The bulb's bloom as a sprite (behind the lamp), canvas-placed at `lampHaloOrigin(_:)`.
    public static func lampHalo(_ layout: SceneLayout) -> SpriteAsset {
        let px = lampHaloPixels(layout)
        let b = bounds(of: px.map(\.point))
        var c = PixelCanvas(width: b.w, height: b.h)
        for p in px { c.plot(p.point.x - b.x, p.point.y - b.y, p.ink) }
        return SpriteAsset("glow.lampHalo", c, anchor: .zero)
    }

    /// The canvas origin of `lampHalo(_:)`.
    public static func lampHaloOrigin(_ layout: SceneLayout) -> ArtPoint {
        bounds(of: lampHaloPixels(layout).map(\.point)).origin
    }

    static func bounds(of points: [ArtPoint]) -> ArtRect {
        points.reduce(ArtRect.zero) { $0.union(ArtRect($1.x, $1.y, 1, 1)) }
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

    /// The mullion's two columns (window-local x).
    static var mullionX: ClosedRange<Int> { (glass.x + glass.w / 2 - 1)...(glass.x + glass.w / 2) }

    /// The blind cord and its tassel hanging below the bottom rail at `railY` (window-local px).
    static func cordPixels(railY: Int) -> [ArtPoint] {
        let cord = glass.x - 1 + glass.w + 2 - 6
        return (0..<14).map { ArtPoint(cord, railY + 3 + $0) }
            + (0..<4).flatMap { dy in (-1...1).map { ArtPoint(cord + $0, railY + 17 + dy) } }
    }

    /// Where the bottom rail of blinds pulled down to `bottom` starts (window-local y).
    static func railY(bottom: Int) -> Int {
        glass.y + 3 + 3 * max(0, (bottom - glass.y - 3) / 3)
    }

    /// The pixels where the sky shows through the glass (window-local): the sky rect without the mullion and
    /// the blind cord. These are what glow after dark.
    public static func skyPixels() -> [ArtPoint] {
        let sky = skyRect(in: ArtRect(0, 0, CoreLayout.window.w, CoreLayout.window.h))
        let cord = Set(cordPixels(railY: railY(bottom: blindsBottom)))
        var out: [ArtPoint] = []
        for y in sky.minY..<sky.maxY {
            for x in sky.minX..<sky.maxX where !mullionX.contains(x) && !cord.contains(ArtPoint(x, y)) {
                out.append(ArtPoint(x, y))
            }
        }
        return out
    }

    /// The whole window for a sky variant at `minuteOfDay`.
    public static func window(sky: SkyVariant, minuteOfDay: Int, blindsDown: Int? = nil) -> SpriteAsset {
        let r = CoreLayout.window
        var c = PixelCanvas(width: r.w, height: r.h)
        let skyArea = ArtRect(glass.x, glass.y, glass.w, glass.h)
        c.blit(skyImage(sky, size: skyArea.size, minuteOfDay: minuteOfDay), at: skyArea.origin)

        // Mullion and a glass glint.
        let mx = mullionX.lowerBound
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
        let y = railY(bottom: bottom)
        for sy in stride(from: glass.y + 3, to: y, by: 3) {
            c.hline(x: x0 + 1, y: sy, length: w - 2, .neutral9)
            c.hline(x: x0 + 1, y: sy + 1, length: w - 2, .neutral8)
            c.hline(x: x0 + 1, y: sy + 2, length: w - 2, .neutral7)
        }
        c.fill(ArtRect(x0, y, w, 3), .neutral8)
        c.hline(x: x0, y: y, length: w, .neutral9)
        c.hline(x: x0, y: y + 2, length: w, .neutral6)
        // Ladder strings and the pull cord with its tassel.
        for lx in [x0 + 12, x0 + w - 13] { c.vline(x: lx, y: glass.y + 3, length: y - glass.y - 3, .neutral8) }
        let cord = cordPixels(railY: y)
        for p in cord.prefix(14) { c.plot(p, .neutral6) }
        for p in cord.dropFirst(14) { c.plot(p, .neutral7) }
        c.plot(cord[14], .neutral9)
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
        case .ceiling: RoomArt.ceiling(d.rect.size)
        case .crown: RoomArt.crown(width: d.rect.w)
        case .rail: RoomArt.rail(width: d.rect.w)
        case .pendant: pendant(d.rect.size, lit: lit)
        case .hangingPlant: hangingPlant(d.rect.size)
        // MARK: w6-polish
        case .upperShelf: upperShelf(d.rect.size)
        case .gallery: gallery(d.rect.size)
        case .ceilingLamp: ceilingLamp(d.rect.size, lit: lit)
        case .wallHanging: wallHanging(d.rect.size)
        }
    }

    /// The pendant's bulb (sprite-local), emissive when the room light is on in the dark.
    public static func pendantBulb(in size: ArtSize) -> ArtRect { ArtRect(size.w / 2 - 3, size.h - 3, 6, 3) }

    /// The cord both hanging pieces hang on.
    static let cordInk = Ink.neutral4

    /// A mustard enamel pendant lamp on a cord.
    public static func pendant(_ size: ArtSize, lit: Bool) -> SpriteAsset {
        var c = PixelCanvas(width: size.w, height: size.h)
        let cx = size.w / 2
        c.fill(ArtRect(cx - 3, 0, 6, 2), .neutral7)
        c.vline(x: cx, y: 2, length: size.h - 14, cordInk)
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
        c.vline(x: cx, y: 2, length: potTop - 14, cordInk)
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
        // MARK: w6-polish
        // An opaque terracotta pot (a white one read as see-through against the wall; Errata 26), cradled by the cords.
        let pot = ArtRect(cx - 6, potTop, 12, 9)
        c.roundedRectFill(pot, radius: 2, .red1)
        c.fill(pot.insetBy(1, 1), .red3)
        c.hline(x: pot.x, y: pot.y, length: pot.w, .red4)
        c.hline(x: pot.x + 1, y: pot.y + 1, length: pot.w - 2, .red2)
        c.vline(x: pot.x + 2, y: pot.y + 2, length: pot.h - 4, .red4)
        c.vline(x: pot.maxX - 3, y: pot.y + 2, length: pot.h - 3, .red2)
        for dx in [-4, 4] { c.vline(x: cx + dx, y: pot.y + 1, length: pot.h - 2, .oak4) }
        c.hline(x: pot.x + 1, y: pot.maxY - 3, length: pot.w - 2, .oak4)
        return SpriteAsset("decor.hangingPlant", c, anchor: .zero)
    }

    /// Floating shelf: books, a framed photo and a trailing pothos over the edge.
    public static func shelf(_ size: ArtSize) -> SpriteAsset {
        let w = size.w
        var c = PixelCanvas(width: w, height: size.h)
        let boardY = 22
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
        // Brackets under both ends, in front of the trailing vines.
        for x in [5, w - 21] {
            c.fill(ArtRect(x, boardY + 4, 3, 7), .neutral3)
            c.vline(x: x, y: boardY + 4, length: 7, .neutral5)
            c.hline(x: x, y: boardY + 4, length: 3, .neutral5)
        }
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
        // The print is drawn in its own clipped card, so the arches stop at the card's edge.
        c.drawing(at: art.origin, size: art.size) { a in
            a.fill(a.bounds, .oak5)
            let cx = a.width / 2, base = a.height - 4
            for (i, ink) in [Ink.red4, .walnut4, .blue3, .green3].enumerated() {
                let rr = a.width / 2 - 1 - i * 2
                guard rr > 1 else { break }
                a.ellipseFill(ArtRect(cx - rr, base - rr, rr * 2, rr * 2), ink)
            }
            let s = max(2, a.width / 2 - 9)
            a.ellipseFill(ArtRect(cx - s, base - s, s * 2, s * 2), .oak5)
            a.fill(ArtRect(0, base, a.width, a.height - base), .oak5)
            a.ellipseFill(ArtRect(cx - 3, 3, 6, 6), .walnut4)
            a.hline(x: 2, y: a.height - 2, length: a.width - 4, .oak3)
        }
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

    /// The floor plant's basket inside its sprite.
    public static func floorPlantPot(_ size: ArtSize) -> ArtRect {
        ArtRect(size.w / 2 - 10, size.h - 16, 21, 16)
    }

    /// A fiddle-leaf fig in a woven basket, standing on the floor line: violin-shaped leaves with a pale midrib,
    /// outlined only on their shadow side.
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
        // Leaves: (centre dx, top y as a fraction of 92, flip), back to front; denser toward the top.
        let spots: [(Int, Int, Bool)] = [
            (-2, 2, true), (5, 5, false), (-9, 9, true), (9, 11, false), (0, 12, false), (-13, 18, true),
            (12, 20, false), (-4, 22, true), (5, 26, false), (-11, 30, true), (11, 33, false), (-2, 35, true),
            (6, 41, false), (-10, 44, true), (12, 47, false), (-3, 50, true), (8, 56, false), (-9, 60, true),
            (3, 64, false),
        ]
        for (i, s) in spots.enumerated() {
            let x = cx + s.0 * w / 38 - 3, y = s.1 * h / 92
            leaf(&leaves, at: ArtPoint(x, y), dark: i % 3 == 1, flipped: s.2)
        }
        var c = PixelCanvas(width: w, height: h)
        c.blit(leaves.buffer, at: .zero)
        // Woven basket.
        let pot = floorPlantPot(size)
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

    /// One 7×10 fiddle leaf (broad tip, waist, narrow base) with an `a8ca58` midrib and a `25562e` edge on
    /// the shadow (right and bottom) side; `flipped` mirrors the shape for leaves left of the trunk.
    static func leaf(_ c: inout PixelCanvas, at o: ArtPoint, dark: Bool, flipped: Bool) {
        let rows = [".#####.", "#######", "#######", ".######", ".#####.", "..#####", "..####.", "..###..", "...#...",
                    "...#..."]
        func mx(_ x: Int) -> Int { flipped ? 6 - x : x }
        var l = PixelCanvas(width: 7, height: rows.count)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" { l.plot(mx(x), y, dark ? .green2 : .green3) }
        }
        for y in 1..<8 { l.plot(mx(y < 5 ? 3 : 4 - (y - 5) / 2), y, .green4) }
        for y in 0..<l.height {
            if let x = (0..<7).last(where: { l.ink(at: $0, y)?.isClear == false }) { l.plot(x, y, .green1) }
        }
        for x in 0..<7 {
            if let y = (0..<l.height).last(where: { l.ink(at: x, $0)?.isClear == false }) { l.plot(x, y, .green1) }
        }
        if let x = (0..<7).first(where: { l.ink(at: $0, 1)?.isClear == false }) { l.plot(x, 1, dark ? .green3 : .green4) }
        c.blit(l.buffer, at: o)
    }
}

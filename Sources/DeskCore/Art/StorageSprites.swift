/// Containers (DESIGN §2.2 E3, E5): the walnut monitor riser with two mini drawers and a cubby, and the grey
/// pedestal cabinet with three drawers. Drawer art is parameterized by the open amount `p` (0…travel): the
/// front slides down `p` rows and the drawer's interior shows in the `p` rows it uncovers.
public enum StorageArt {
    // MARK: Riser

    /// Local geometry inside the 160×22 riser.
    static let riserTopH = 6
    static var riserDrawerLLocal: ArtRect { CoreLayout.riserDrawerL.offsetBy(-CoreLayout.riser.x, -CoreLayout.riser.y) }
    static var riserDrawerRLocal: ArtRect { CoreLayout.riserDrawerR.offsetBy(-CoreLayout.riser.x, -CoreLayout.riser.y) }
    static var riserCubbyLocal: ArtRect { CoreLayout.riserCubby.offsetBy(-CoreLayout.riser.x, -CoreLayout.riser.y) }

    /// The riser frame: top face, front with dark drawer openings, and the cubby (drawer fronts are separate).
    public static func riser(cubbyContents: PixelBuffer? = nil) -> SpriteAsset {
        let r = CoreLayout.riser
        var c = PixelCanvas(width: r.w, height: r.h)
        // Top face.
        c.fill(ArtRect(0, 0, r.w, riserTopH), .walnut3)
        c.hline(x: 1, y: 0, length: r.w - 2, .walnut2)
        c.hline(x: 1, y: 1, length: r.w - 2, .walnut3)
        c.hline(x: 0, y: riserTopH - 1, length: r.w, .walnut4)
        for i in 0..<9 {
            let y = 2 + ArtKit.noise(i, 0, seed: 41, 3), x = 6 + ArtKit.noise(i, 1, seed: 41, r.w - 40)
            c.hline(x: x, y: y, length: 10 + ArtKit.noise(i, 2, seed: 41, 20), i % 3 == 0 ? .walnut4 : .walnut2)
        }
        // Front face.
        let front = ArtRect(0, riserTopH, r.w, r.h - riserTopH)
        c.fill(front, .walnut2)
        c.hline(x: 0, y: r.h - 2, length: r.w, .walnut1)
        c.hline(x: 0, y: r.h - 1, length: r.w, .walnut0)
        c.vline(x: 0, y: 0, length: r.h, .walnut1)
        c.vline(x: 1, y: riserTopH, length: r.h - riserTopH - 2, .walnut3)
        c.vline(x: r.w - 1, y: 0, length: r.h, .walnut0)
        c.plot(0, 0, .clear)
        c.plot(r.w - 1, 0, .clear)
        for opening in [riserDrawerLLocal, riserDrawerRLocal] {
            c.fill(opening.insetBy(-1, -1), .walnut0)
            c.fill(opening, .neutral1)
        }
        // Cubby: an open slot, deep shadow at the back, lit floor lip.
        let cb = riserCubbyLocal
        c.fill(cb.insetBy(-1, -1), .walnut0)
        c.fill(cb, .walnut0)
        c.fill(ArtRect(cb.x, cb.y, cb.w, 3), .neutral1)
        c.fill(ArtRect(cb.x, cb.maxY - 3, cb.w, 3), .walnut1)
        c.hline(x: cb.x, y: cb.maxY - 1, length: cb.w, .walnut2)
        c.vline(x: cb.x, y: cb.y + 2, length: cb.h - 3, .walnut1)
        if let cubbyContents {
            c.blit(cubbyContents.cropped(to: ArtRect(0, 0, cb.w, cb.h)), at: cb.origin)
        }
        c.hline(x: cb.x - 1, y: cb.maxY, length: cb.w + 2, .walnut3)
        return SpriteAsset("riser", c, anchor: ArtPoint(r.w / 2, r.h), hitRects: [
            "drawerL": riserDrawerLLocal, "cubby": cb, "drawerR": riserDrawerRLocal,
        ])
    }

    /// A riser drawer front (56×12) pulled out by `p` rows: interior in the top `p` rows, then the front.
    /// `jammed` stuffs paper poking over the front's top edge. `contents` (interior px) is cropped to what shows.
    public static func riserDrawer(p: Int, jammed: Bool = false, contents: PixelBuffer? = nil) -> SpriteAsset {
        let size = CoreLayout.riserDrawerL.size
        let travel = CoreLayout.riserTravel
        let open = min(max(p, 0), travel)
        var c = PixelCanvas(width: size.w, height: size.h + travel)
        drawInterior(&c, ArtRect(0, 0, size.w, open), wood: true, contents: contents)
        let f = ArtRect(0, open, size.w, size.h)
        c.fill(f, .walnut2)
        c.hline(x: f.x, y: f.y, length: f.w, .walnut4)
        c.hline(x: f.x, y: f.y + 1, length: f.w, .walnut3)
        c.hline(x: f.x, y: f.maxY - 1, length: f.w, .walnut1)
        c.vline(x: f.x, y: f.y, length: f.h, .walnut3)
        c.vline(x: f.maxX - 1, y: f.y + 1, length: f.h - 1, .walnut1)
        // Brass bar pull.
        let hd = Anchors.handle(of: ArtRect(0, 0, size.w, size.h), width: 12).offsetBy(0, open)
        c.fill(ArtRect(hd.x, hd.y + 1, hd.w, 3), .walnut0)
        c.hline(x: hd.x + 1, y: hd.y + 1, length: hd.w - 2, .walnut5)
        c.hline(x: hd.x + 1, y: hd.y + 2, length: hd.w - 2, .walnut4)
        c.plot(hd.x + 1, hd.y + 2, .walnut5)
        c.hline(x: hd.x + 2, y: hd.y + 4, length: hd.w - 4, .walnut1)
        if jammed { drawPaperPoking(&c, frontTop: open, width: size.w) }
        let name = "riser.drawer.p\(open)" + (jammed ? ".jammed" : "")
        return SpriteAsset(name, c, anchor: .zero, hitRects: ["front": f, "handle": hd])
    }

    /// The inside of a drawer box seen from above, `r` = the uncovered rows.
    static func drawInterior(_ c: inout PixelCanvas, _ r: ArtRect, wood: Bool, contents: PixelBuffer?) {
        guard r.h > 0 else { return }
        let (floor, wallLit, wallDark, back): (Ink, Ink, Ink, Ink) = wood
            ? (.walnut1, .walnut3, .walnut0, .walnut0)
            : (.neutral3, .neutral6, .neutral2, .neutral1)
        c.fill(r, floor)
        c.hline(x: r.x, y: r.y, length: r.w, back)
        if let contents {
            c.blit(contents.cropped(to: ArtRect(0, max(0, contents.height - r.h + 1), r.w - 4, r.h - 1)),
                   at: ArtPoint(r.x + 2, r.y + 1))
        }
        c.fill(ArtRect(r.x, r.y, 2, r.h), wallLit)
        c.vline(x: r.x + 1, y: r.y, length: r.h, wood ? .walnut2 : .neutral5)
        c.fill(ArtRect(r.maxX - 2, r.y, 2, r.h), wallDark)
        if r.h >= 2 { c.hline(x: r.x + 2, y: r.y + 1, length: r.w - 4, wood ? .walnut0 : .neutral2) }
    }

    /// Sheets of paper sticking up over a jammed drawer's front.
    static func drawPaperPoking(_ c: inout PixelCanvas, frontTop: Int, width: Int) {
        let y = frontTop
        for (i, x) in [5, 12, 20, 31, 38, 47].enumerated() where x + 6 < width {
            let up = 2 + (i % 3)
            let w = 5 + (i % 2) * 2
            c.fill(ArtRect(x, y - up, w, up), .neutral9)
            c.hline(x: x, y: y - up, length: w, .neutral8)
            c.plot(x + w - 1, y - up, .neutral7)
            if i % 2 == 0 { c.hline(x: x + 1, y: y - up + 1, length: w - 2, .neutral7) }
        }
    }

    // MARK: Cabinet

    /// The cabinet sprite starts 2 rows above `CoreLayout.cabinet` (its top face shows under the desk).
    public static let cabinetTopFace = 2
    public static var cabinetSpriteOrigin: ArtPoint {
        ArtPoint(CoreLayout.cabinet.x, CoreLayout.cabinet.y - cabinetTopFace)
    }

    /// The pedestal cabinet with each drawer pulled out by `p[i]` (top, middle, file). `jammed[i]` adds paper.
    public static func cabinet(p: [Int] = [0, 0, 0], jammed: [Bool] = [false, false, false]) -> SpriteAsset {
        let r = CoreLayout.cabinet
        let maxTravel = CoreLayout.cabinetTravels.max()!
        let top = cabinetTopFace
        var c = PixelCanvas(width: r.w, height: top + r.h + maxTravel)
        // Carcass.
        let body = ArtRect(0, top, r.w, r.h)
        c.fill(ArtRect(0, 0, r.w, top), .neutral8)
        c.hline(x: 1, y: 0, length: r.w - 2, .neutral9)
        c.fill(body, .neutral3)
        c.vline(x: 0, y: 0, length: top + r.h - CoreLayout.cabinetPlinth, .neutral5)
        c.vline(x: r.w - 1, y: 0, length: top + r.h - CoreLayout.cabinetPlinth, .neutral4)
        // Plinth with casters.
        let plinthY = top + r.h - CoreLayout.cabinetPlinth
        c.fill(ArtRect(1, plinthY, r.w - 2, CoreLayout.cabinetPlinth - 3), .neutral3)
        c.hline(x: 1, y: plinthY, length: r.w - 2, .neutral4)
        for x in [3, r.w - 10] {
            c.fill(ArtRect(x + 2, plinthY + 2, 3, 1), .neutral2)
            c.ellipseFill(ArtRect(x, plinthY + 3, 7, 3), .neutral1)
            c.plot(x + 2, plinthY + 3, .neutral5)
        }
        // Drawers, bottom first so a pulled-out upper drawer covers the one below it.
        for i in stride(from: 2, through: 0, by: -1) {
            let front = CoreLayout.cabinetFront(i).offsetBy(-r.x, -r.y + top)
            let open = min(max(i < p.count ? p[i] : 0, 0), CoreLayout.cabinetTravels[i])
            drawCabinetDrawer(&c, front: front, open: open, index: i, jammed: i < jammed.count && jammed[i])
        }
        // The desk's shadow on the top of the cabinet.
        for y in 0..<(top + 5) {
            for x in 0..<r.w where Dither.pick(x: x, y: y, fraction: 1 - Double(y) / Double(top + 5)) {
                if let ink = c.ink(at: x, y), !ink.isClear { c.plot(x, y, ink.darker()) }
            }
        }
        var hits: [String: ArtRect] = [:]
        for (i, name) in Anchors.cabinetDrawerNames.enumerated() {
            let front = CoreLayout.cabinetFront(i).offsetBy(-r.x, -r.y + top)
            hits[name] = front
            hits["\(name).handle"] = Anchors.cabinetHandle(of: front)
        }
        let name = "cabinet" + (p.contains { $0 > 0 } ? ".p\(p.map(String.init).joined(separator: "-"))" : "")
            + (jammed.contains(true) ? ".jammed" : "")
        return SpriteAsset(name, c, anchor: ArtPoint(r.w / 2, top + r.h), hitRects: hits)
    }

    static func drawCabinetDrawer(_ c: inout PixelCanvas, front f0: ArtRect, open: Int, index: Int, jammed: Bool) {
        if open > 0 {
            drawInterior(&c, ArtRect(f0.x + 2, f0.y, f0.w - 4, open), wood: false, contents: nil)
            if index == 2 {
                // Hanging-folder rails and a few tabs.
                for (k, ink) in [Ink.blue3, .green3, .walnut4, .red4].enumerated() where 2 + k * 3 < open + 1 {
                    let tab = folderTab(ink).image
                    c.blit(tab.cropped(to: ArtRect(0, 0, tab.width, min(tab.height, open))),
                           at: ArtPoint(f0.x + 8 + k * 16, f0.y + max(0, open - tab.height - 1)))
                }
            }
        }
        let f = f0.offsetBy(0, open)
        c.fill(f, .neutral7)
        c.hline(x: f.x, y: f.y, length: f.w, .neutral4)
        c.hline(x: f.x + 1, y: f.y + 1, length: f.w - 2, .neutral9)
        c.hline(x: f.x + 1, y: f.y + 2, length: f.w - 2, .neutral8)
        c.hline(x: f.x, y: f.maxY - 2, length: f.w, .neutral6)
        c.hline(x: f.x, y: f.maxY - 1, length: f.w, .neutral4)
        c.vline(x: f.x, y: f.y, length: f.h, .neutral5)
        c.vline(x: f.x + 1, y: f.y + 1, length: f.h - 2, .neutral8)
        c.vline(x: f.maxX - 1, y: f.y, length: f.h, .neutral4)
        c.vline(x: f.maxX - 2, y: f.y + 1, length: f.h - 2, .neutral6)
        // Recessed pull: dark slot over a lit lip.
        let hd = Anchors.cabinetHandle(of: f)
        c.fill(ArtRect(hd.x, hd.y, hd.w, 2), .neutral2)
        c.hline(x: hd.x + 1, y: hd.y, length: hd.w - 2, .neutral1)
        c.hline(x: hd.x, y: hd.y + 2, length: hd.w, .neutral9)
        c.plot(hd.x - 1, hd.y, .neutral5)
        c.plot(hd.maxX, hd.y, .neutral5)
        if index == 2 {
            // Label holder on the file drawer.
            let lb = ArtRect(f.midX - 7, hd.y + 7, 14, 7)
            c.stroke(lb, .neutral5)
            c.fill(lb.insetBy(1, 1), .neutral9)
            c.hline(x: lb.x + 2, y: lb.y + 2, length: 8, .neutral6)
            c.hline(x: lb.x + 2, y: lb.y + 4, length: 5, .neutral7)
        }
        if jammed { drawPaperPoking(&c, frontTop: f.y, width: f.w) }
    }

    /// A hanging-folder tab in a kind colour (7×5).
    public static func folderTab(_ ink: Ink) -> SpriteAsset {
        var c = PixelCanvas(width: 7, height: 5)
        c.fill(ArtRect(0, 0, 7, 3), ink)
        c.hline(x: 0, y: 0, length: 7, ink.lighter())
        c.hline(x: 1, y: 1, length: 4, .neutral9)
        c.fill(ArtRect(0, 3, 7, 2), .neutral8)
        c.vline(x: 6, y: 0, length: 5, ink.darker())
        return SpriteAsset("cabinet.folderTab", c, anchor: .zero)
    }

    /// Paper edges seen in a drawer opened just a crack (peek).
    public static func paperEdges(width: Int, rows: Int) -> SpriteAsset {
        var c = PixelCanvas(width: width, height: max(1, rows))
        for y in 0..<max(1, rows) {
            c.hline(x: 2, y: y, length: width - 4, y % 2 == 0 ? .neutral9 : .neutral7)
            c.plot(2 + ArtKit.noise(y, 0, seed: 3, width - 6), y, .neutral8)
        }
        return SpriteAsset("drawer.paperEdges", c, anchor: .zero)
    }
}

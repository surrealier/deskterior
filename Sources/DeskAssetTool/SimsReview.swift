import DeskCore
import DeskPixels
import Foundation

// `deskterior-assets sims-review --out DIR`: the M6/M7 sims and machines rendered into the room for review (×3
// nearest): drawer open / slam / jam sequences with their contents, the interiors at rest, the chair block,
// ballistic arcs over the basket, the chair roll, the pen cup tip and spill, the phone flip and the basket heap.

enum SimsReview {
    static let dt: Float = 1.0 / 60
    static let layout = LayoutSolver.solve(display: DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2,
                                                                    topInsetPt: 33))
    static let font = PixelFont.galmuri9

    // MARK: Fixtures

    static let kinds: [FileKind] = [.pdf, .image, .folder, .doc, .text, .zip, .code, .audio, .video, .app, .screenshot,
                                    .dmg, .unknown]
    static let names = ["report.pdf", "IMG_0412.png", "Projects", "Letter.docx", "notes.txt", "backup.zip",
                        "main.swift", "song.mp3", "clip.mov", "Deskterior.app", "Screenshot 1.png", "Xcode.dmg",
                        "보고서 final.pdf", "Taxes 2025", "budget.xlsx", "receipt.pdf", "cat.jpg", "todo.txt",
                        "Archive", "minutes.doc", "deck.key", "draft.md", "invoice.pdf", "photo.heic"]

    static func items(_ n: Int, offset: Int = 0) -> [InteriorRaster.Item] {
        (0..<n).map { i in
            let k = (i + offset) % names.count
            return InteriorRaster.Item(kind: kinds[k % kinds.count], name: names[k],
                                       seed: SplitMix64.mix(UInt64(k) &+ 0x51A5))
        }
    }

    // MARK: Room composition

    /// One sprite to place: placement id (replacing the room's own, or new), layer, sprite, core top-left.
    struct Put {
        var id: String
        var layer: RoomLayer
        var sprite: SpriteAsset
        var core: ArtPoint
    }

    /// The day room with `puts` replacing (or added to) its placements, in canvas px.
    static func room(_ puts: [Put], state: RoomState = RoomState(time: WallTime(hour: 10, minute: 0))) -> PixelBuffer {
        let ids = Set(puts.map(\.id))
        var placements = RoomPlan.placements(layout, state).filter { !ids.contains($0.id) }
        for p in puts { placements.append(RoomPlacement(p.id, p.layer, p.sprite, at: layout.point(p.core))) }
        return RoomPlan.compose(layout.canvas, placements)
    }

    /// `b` cropped to a core rect.
    static func crop(_ b: PixelBuffer, _ core: ArtRect) -> PixelBuffer {
        b.cropped(to: layout.rect(core))
    }

    /// Tiles with labels under them, `columns` across.
    static func sheet(_ tiles: [(PixelBuffer, String)], columns: Int) -> PixelBuffer {
        guard let first = tiles.first?.0 else { return PixelBuffer(width: 1, height: 1) }
        let labelH = 13, pad = 2
        let fw = tiles.map(\.0.width).max() ?? first.width, fh = tiles.map(\.0.height).max() ?? first.height
        let cw = fw + 2 * pad, ch = fh + labelH + 2 * pad
        let rows = (tiles.count + columns - 1) / columns
        var out = PixelBuffer(width: columns * cw, height: rows * ch, fill: Ink.neutral1.color)
        for (k, (img, label)) in tiles.enumerated() {
            let o = ArtPoint((k % columns) * cw + pad, (k / columns) * ch + pad)
            out.blit(img, at: o, alphaTest: false)
            if let text = font?.render(label, color: Ink.neutral9.color) {
                out.blit(text.cropped(to: ArtRect(0, 0, min(text.width, fw), text.height)), at: ArtPoint(o.x, o.y + fh + 1))
            }
        }
        return out
    }

    static func describe(_ events: [DrawerSim.Event]) -> String {
        events.compactMap { e -> String? in
            switch e {
            case let .slam(s): "SLAM \(Int(s))"
            case .latch: "latch"
            case let .stuffed(s): "stuffed \(Int(s))"
            case let .jamThud(s): "BOING \(Int(s))"
            case let .hitStop(s): "stop \(Int(s))"
            case let .hitChair(s): "THUNK \(Int(s))"
            case .chompSwallow: "swallow"
            case let .settled(p): "rest p\(Int(p))"
            }
        }.joined(separator: " ")
    }

    // MARK: Drawers

    /// A riser-drawer run: `drive` is called each frame with the frame index and returns nothing; tiles every
    /// `every` frames over `frames` frames.
    static func riserRun(
        count: Int, p: Float, frames: Int, every: Int, drive: (Int, inout DrawerSim) -> Void
    ) -> [(PixelBuffer, String)] {
        let id = ContainerID.riserLeft
        let its = items(count)
        var sim = DrawerSim(id, p: p, count: count)
        var jostle = ContentJostle(homes: InteriorRaster.jostleHomes(id, items: its), bounds: InteriorRaster.baseBounds(id),
                                   seed: 7)
        var tiles: [(PixelBuffer, String)] = []
        var pending: [DrawerSim.Event] = []
        for f in 0..<frames {
            drive(f, &sim)
            pending += sim.step(dt)
            jostle.step(drawerAcceleration: sim.acceleration, dt)
            if f % every == 0 || f == frames - 1 {
                let drawer = InteriorRaster.riserDrawer(id, p: sim.pixel, items: its, offsets: jostle.pixelOffsets)
                let img = room([Put(id: "riser.drawerL", layer: .deskBack, sprite: drawer, core: CoreLayout.riserDrawerL.origin)])
                let label = "f\(f) p\(String(format: "%.1f", sim.p)) " + describe(pending)
                tiles.append((crop(img, ArtRect(182, 150, 92, 34)), label))
                pending = []
            }
        }
        return tiles
    }

    static func drawerSequences() -> [(String, PixelBuffer)] {
        // Drag open: the handle follows the pointer down 14 px over 8 frames, held, released.
        let open = riserRun(count: 6, p: 0, frames: 36, every: 3) { f, sim in
            if f == 0 { sim.beginDrag() }
            if f < 10 { sim.drag(to: Float(min(f, 8)) * 1.75) }
            if f == 10 { sim.endDrag() }
        }
        // Flick shut: from open, the pointer jumps 20 px up in two frames and lets go at 450 px/s.
        let slam = riserRun(count: 6, p: 10, frames: 30, every: 2) { f, sim in
            if f == 0 { sim.beginDrag() }
            if f == 1 { sim.drag(to: 0) }
            if f == 2 { sim.drag(to: -10) }
            if f == 3 { sim.endDrag(releaseVelocity: -450) }
        }
        // Jammed (14 items): the same flick bounces back off the gap.
        let jam = riserRun(count: 14, p: 10, frames: 36, every: 3) { f, sim in
            if f == 0 { sim.beginDrag() }
            if f == 1 { sim.drag(to: 0) }
            if f == 2 { sim.drag(to: -10) }
            if f == 3 { sim.endDrag(releaseVelocity: -450) }
        }
        // Click toggle, then a chomp.
        let toggle = riserRun(count: 3, p: 0, frames: 60, every: 4) { f, sim in
            if f == 0 { sim.toggle() }
            if f == 30 { sim.toggle() }
            if f == 44 { sim.chomp() }
        }
        return [("drawer-open", sheet(open, columns: 4)), ("drawer-slam", sheet(slam, columns: 4)),
                ("drawer-jam", sheet(jam, columns: 4)), ("drawer-toggle-chomp", sheet(toggle, columns: 4))]
    }

    /// Riser drawers and cubby at rest for several fills and openings.
    static func riserStates() -> PixelBuffer {
        var tiles: [(PixelBuffer, String)] = []
        for (n, p) in [(1, 10), (4, 10), (8, 10), (12, 10), (14, 10), (5, 3), (5, 6), (10, 2), (14, 6)] {
            let its = items(n, offset: n)
            let left = InteriorRaster.riserDrawer(.riserLeft, p: p, items: its)
            let right = InteriorRaster.riserDrawer(.riserRight, p: n > 8 ? 2 : 0, items: [])
            let riser = StorageArt.riser(cubbyContents: InteriorRaster.cubby(items(n, offset: 3)))
            let img = room([
                Put(id: "riser", layer: .deskBack, sprite: riser, core: CoreLayout.riser.origin),
                Put(id: "riser.drawerL", layer: .deskBack, sprite: left, core: CoreLayout.riserDrawerL.origin),
                Put(id: "riser.drawerR", layer: .deskBack, sprite: right, core: CoreLayout.riserDrawerR.origin),
            ])
            tiles.append((crop(img, ArtRect(180, 148, 170, 36)), "n\(n) p\(p) cubby\(n)"))
        }
        return sheet(tiles, columns: 3)
    }

    /// Cabinet interiors at rest.
    static func cabinetStates() -> PixelBuffer {
        var tiles: [(PixelBuffer, String)] = []
        let cases: [([Int], [Int], String)] = [
            ([12, 0, 0], [5, 0, 0], "top 5"), ([12, 0, 0], [8, 0, 0], "top 8"), ([0, 14, 0], [0, 12, 0], "middle 12"),
            ([0, 14, 0], [0, 18, 0], "middle 18"), ([0, 0, 18], [0, 0, 6], "file 6"), ([0, 0, 18], [0, 0, 20], "file 20"),
            ([0, 0, 18], [0, 0, 0], "file empty"), ([6, 0, 0], [14, 0, 0], "top jammed"), ([12, 14, 18], [6, 9, 12], "all open"),
            ([0, 0, 5], [0, 0, 8], "file peek"),
        ]
        for (p, n, label) in cases {
            let its = (0..<3).map { items(n[$0], offset: 5 * $0) }
            let cab = InteriorRaster.cabinet(p: p, items: its)
            let img = room([Put(id: "cabinet", layer: .underDesk, sprite: cab, core: StorageArt.cabinetSpriteOrigin)])
            tiles.append((crop(img, ArtRect(384, 238, 96, 84)), label))
        }
        return sheet(tiles, columns: 5)
    }

    /// The chair in front of the cabinet blocks the top drawer; the thunk pushes it aside and the next pull opens.
    static func chairBlock() -> PixelBuffer {
        let id = ContainerID.cabinetTop
        let its = items(6, offset: 2)
        var drawer = DrawerSim(id, p: 0, count: its.count)
        var jostle = ContentJostle(homes: InteriorRaster.jostleHomes(id, items: its), bounds: InteriorRaster.baseBounds(id))
        var chair = RollerSim(x: 380, facing: 0)
        var tiles: [(PixelBuffer, String)] = []
        var pending: [String] = []
        for f in 0..<150 {
            drawer.setOpenLimit(DrawerSim.cabinetOpenLimit(travel: drawer.travel, chairX: chair.x))
            if f == 0 || f == 100 { drawer.beginDrag() }
            if (0..<14).contains(f) || (100..<114).contains(f) { drawer.drag(to: Float(f % 100) * 1.5) }
            if f == 14 || f == 114 { drawer.endDrag() }
            if f == 30 { drawer.close() }
            for e in drawer.step(dt) {
                if case let .hitChair(s) = e {
                    chair.pushedByDrawer()
                    pending.append("THUNK \(Int(s))")
                }
                if case let .settled(p) = e { pending.append("rest p\(Int(p))") }
            }
            jostle.step(drawerAcceleration: drawer.acceleration, dt)
            for e in chair.step(dt) { if case let .settled(x, _) = e { pending.append("chair x\(Int(x))") } }
            if f % 10 == 0 {
                let cab = InteriorRaster.cabinet(p: [drawer.pixel, 0, 0], items: [its, [], []], offsets: [jostle.pixelOffsets])
                let img = room([
                    Put(id: "cabinet", layer: .underDesk, sprite: cab, core: StorageArt.cabinetSpriteOrigin),
                    Put(id: "chair", layer: .chair, sprite: PropArt.chair(chair.chairFacing),
                        core: ArtPoint(chair.pixelX, CoreLayout.chair.y)),
                ])
                tiles.append((crop(img, ArtRect(296, 228, 192, 92)), "f\(f) p\(drawer.pixel) x\(chair.pixelX) " + pending.joined(separator: " ")))
                pending = []
            }
        }
        return sheet(tiles, columns: 3)
    }

    // MARK: Ballistics

    static func plot(_ img: inout PixelBuffer, _ toss: Ballistics.Toss, _ ink: Ink) {
        let o = layout.coreOrigin
        for p in toss.screenPath(fps: 240) { img.set(p.x + o.x, p.y + o.y, ink.color) }
        let e = DeskProjection.snap(toss.screenPoint(at: toss.duration))
        for d in -2...2 {
            img.set(e.x + o.x + d, e.y + o.y, ink.color)
            img.set(e.x + o.x, e.y + o.y + d, ink.color)
        }
    }

    static func kindInk(_ k: Ballistics.Kind) -> Ink {
        switch k {
        case .swish: .green4
        case .rimIn: .walnut5
        case .rimOut: .red5
        case .miss: .purple4
        }
    }

    /// Finds one toss of each kind from a carry release over the floor left of the chair, then plots them with a
    /// drop straight above the basket, two desk-edge push-offs and a fling onto the desk.
    static func ballistics() -> [(String, PixelBuffer)] {
        var found: [Ballistics.Kind: Ballistics.Toss] = [:]
        let release = SIMD2<Float>(150, 236)
        search: for vy in stride(from: -150, through: -500, by: -25) {
            for vx in stride(from: -100, through: -600, by: -20) {
                let (p, v) = Ballistics.release(at: release, velocity: SIMD2(Float(vx), Float(vy)))
                let t = Ballistics.toss(from: p, velocity: v)
                if case .desk = t.landing { continue }
                if found[t.kind] == nil { found[t.kind] = t }
                if found.count == 4 { break search }
            }
        }
        var img = room([])
        var labels: [String] = []
        for k in [Ballistics.Kind.swish, .rimIn, .rimOut, .miss] {
            guard let t = found[k] else { continue }
            plot(&img, t, kindInk(k))
            labels.append("\(k.rawValue) \(landingText(t.landing)) rim\(t.rimHits)")
        }
        let drop = Ballistics.toss(from: Ballistics.release(at: SIMD2(64, 250), velocity: .zero).position, velocity: .zero)
        plot(&img, drop, .blue5)
        labels.append("drop \(drop.kind.rawValue)")
        let push1 = Ballistics.pushOff(at: SIMD2(66, 0), velocity: SIMD2(-20, -60))
        plot(&img, push1, .blue4)
        labels.append("push \(push1.kind.rawValue)")
        let push2 = Ballistics.pushOff(at: SIMD2(120, 0), velocity: SIMD2(80, -90))
        plot(&img, push2, .red4)
        labels.append("push \(push2.kind.rawValue)")
        let (fp, fv) = Ballistics.release(at: SIMD2(150, 120), velocity: SIMD2(380, -200))
        let fling = Ballistics.toss(from: fp, velocity: fv)
        plot(&img, fling, .purple5)
        labels.append("fling \(landingText(fling.landing))")
        let wide = crop(img, ArtRect(0, 100, 280, 220))
        let zoom = crop(img, ArtRect(20, 200, 140, 120))
        print("ballistics: " + labels.joined(separator: " · "))
        return [("ballistics", sheet([(wide, labels.prefix(4).joined(separator: " · "))], columns: 1)),
                ("ballistics-basket", sheet([(zoom, labels.dropFirst(4).joined(separator: " · "))], columns: 1))]
    }

    static func landingText(_ l: Ballistics.Landing) -> String {
        switch l {
        case .basket: "basket"
        case let .desk(p): "desk(\(Int(p.x)),\(Int(p.y)))"
        case let .floor(x): "floor x\(Int(x))"
        }
    }

    // MARK: Chair, pen cup, phone, basket

    static func chairRoll() -> PixelBuffer {
        var chair = RollerSim(x: 196, facing: 0)
        var tiles: [(PixelBuffer, String)] = []
        var pending: [String] = []
        chair.beginDrag(pointerX: 230)
        for f in 0..<160 {
            if f < 6 { chair.drag(pointerX: 230 - Float(f) * 6) }
            if f == 6 { chair.endDrag(releaseVelocity: 1100) }
            for e in chair.step(dt) {
                switch e {
                case let .bump(s, side): pending.append("bump\(side > 0 ? "R" : "L") \(Int(s))")
                case let .blockedByDrawer(s): pending.append("block \(Int(s))")
                case let .settled(x, facing): pending.append("rest x\(Int(x)) f\(facing)")
                }
            }
            if f % 8 == 0 || !chair.needsFrames {
                let img = room([Put(id: "chair", layer: .chair, sprite: PropArt.chair(chair.chairFacing),
                                    core: ArtPoint(chair.pixelX, CoreLayout.chair.y))])
                tiles.append((crop(img, ArtRect(40, 222, 472, 98)), "f\(f) x\(chair.pixelX) v\(Int(chair.v)) face\(chair.facing) "
                    + pending.joined(separator: " ")))
                pending = []
                if !chair.needsFrames { break }
            }
        }
        return sheet(tiles, columns: 2)
    }

    static func penCup() -> [(String, PixelBuffer)] {
        let its = items(5, offset: 4)
        var tiles: [(PixelBuffer, String)] = []
        for right in [true, false] {
            var cup = PenCupMachine(PenCupState(state: "upright", pos: SIMD2(250, 70)))
            var log = cup.release(velocity: SIMD2(right ? 520 : -520, 0), count: its.count).map { "\($0)" }
            for f in 0..<44 {
                if f == 24 { log += cup.standUp().map { "\($0)" } }
                log += cup.step(dt).map { "\($0)" }
                if f % 3 == 0 && (f < 21 || f >= 24) {
                    let s = InteriorRaster.penCup(cup.pose, mirrored: cup.mirrored, items: its)
                    let x = Int(cup.position.x) - 7 + (cup.isUpright ? 0 : (right ? -2 : -12))
                    let y = DeskProjection.standard.projectToPixel(SIMD3(cup.position.x, cup.position.y, 0)).y - 22
                    let img = room([Put(id: "pencup", layer: .deskFront, sprite: s, core: ArtPoint(x, y))])
                    tiles.append((crop(img, ArtRect(200, 160, 100, 70)), "f\(f) \(cup.pose)"))
                }
            }
            print("pencup \(right ? "right" : "left"): " + log.joined(separator: " "))
        }
        // Spill spots from three places, both ways.
        var img = room([Put(id: "pencup", layer: .deskFront, sprite: SpriteAsset("none", PixelBuffer(width: 1, height: 1)),
                            core: .zero)])
        let o = layout.coreOrigin
        var notes: [String] = []
        for (pos, right) in [(SIMD2<Float>(367, 120), true), (SIMD2<Float>(367, 120), false), (SIMD2<Float>(250, 70), true),
                             (SIMD2<Float>(470, 30), true), (SIMD2<Float>(40, 20), false)] {
            let spills = PenCupMachine.spill(count: 6, from: pos, right: right, seed: 42)
            let cup = PropArt.penCup(.lying(right: right)).image
            let c0 = DeskProjection.standard.projectToPixel(SIMD3(pos.x, pos.y, 0))
            img.blit(cup, at: ArtPoint(c0.x + o.x - (right ? 9 : 19), c0.y + o.y - 22))
            for (s, item) in zip(spills, its + its) {
                switch s.landing {
                case let .desk(p):
                    let q = DeskProjection.standard.projectToPixel(SIMD3(p.x, p.y, 0))
                    img.blit(KindIcons.icon(InteriorRaster.iconKind(item.kind)).image, at: ArtPoint(q.x + o.x - 8, q.y + o.y - 15))
                case let .floor(x):
                    img.blit(KindIcons.icon(InteriorRaster.iconKind(item.kind)).image,
                             at: ArtPoint(Int(x) + o.x - 8, CoreLayout.floorY + o.y - 16))
                    notes.append("floor x\(Int(x))")
                case .basket:
                    notes.append("basket")
                }
            }
        }
        return [("pencup-tip", sheet(tiles, columns: 7)),
                ("pencup-spill", sheet([(crop(img, ArtRect(0, 100, 512, 220)), "spills " + notes.joined(separator: " "))],
                                       columns: 1))]
    }

    static func phone() -> PixelBuffer {
        var m = PhoneMachine()
        let minis = InteriorRaster.phoneMinis(items(6, offset: 1))
        var tiles: [(PixelBuffer, String)] = []
        var log = m.flip().map { "\($0)" }
        var last: PropArt.PhoneFace?
        for f in 0..<40 {
            if f == 20 { log += m.flip().map { "\($0)" } }
            if m.face != last {
                last = m.face
                let s = PropArt.phoneStand(face: m.face, minis: m.showsContents ? minis : [])
                let img = room([Put(id: "phone", layer: .deskBack, sprite: s, core: CoreLayout.phone.origin)])
                tiles.append((crop(img, ArtRect(376, 138, 32, 38)), "f\(f) \(m.face)"))
            }
            log += m.step(dt).map { "\($0)" }
        }
        print("phone: " + log.joined(separator: " "))
        return sheet(tiles, columns: 6)
    }

    static func wastebasket() -> PixelBuffer {
        var tiles: [(PixelBuffer, String)] = []
        for n in [0, 5, 10, 11, 16, 24] {
            let s = InteriorRaster.wastebasket(items(n))
            let img = room([
                Put(id: "wastebasket.back", layer: .underDesk, sprite: s,
                    core: ArtPoint(CoreLayout.wastebasket.x, CoreLayout.wastebasket.y - InteriorRaster.heapRise)),
                Put(id: "wastebasket.front", layer: .underDesk, sprite: SpriteAsset("none", PixelBuffer(width: 1, height: 1)),
                    core: .zero),
            ])
            tiles.append((crop(img, ArtRect(20, 236, 90, 84)), "n\(n)" + (n >= WastebasketMachine.aboveRimCount ? " heaped" : "")))
        }
        // Tipped right: the spill spots as floor tokens (the tipped basket has no art yet).
        for right in [true, false] {
            let spots = WastebasketMachine.spillSpots(count: 12, right: right)
            var img = room([])
            let o = layout.coreOrigin
            for (x, item) in zip(spots, items(12)) {
                img.blit(KindIcons.icon(InteriorRaster.iconKind(item.kind)).image, at: ArtPoint(x + o.x, CoreLayout.floorY + o.y - 16))
            }
            tiles.append((crop(img, ArtRect(0, 236, 300, 84)), "tipped \(right ? "right" : "left") 12"))
        }
        return sheet(tiles, columns: 3)
    }

    // MARK: Run

    static func run(outDir: URL) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var out: [(String, PixelBuffer)] = drawerSequences()
        out.append(("riser-states", riserStates()))
        out.append(("cabinet-states", cabinetStates()))
        out.append(("cabinet-chair-block", chairBlock()))
        out += ballistics()
        out.append(("chair-roll", chairRoll()))
        out += penCup()
        out.append(("phone-flip", phone()))
        out.append(("wastebasket", wastebasket()))
        for (name, b) in out { try write(b, "\(name).png", in: outDir, scale: 3) }
    }
}

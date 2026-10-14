import DeskPixels
import Foundation
import simd
import Testing
@testable import DeskCore

/// Wave-6 polish in DeskCore (Errata 26).
@Suite("Core polish (wave 6)")
struct PolishCoreTests {
    static func folders(_ n: Int) -> [InteriorRaster.Item] {
        (0..<n).map { InteriorRaster.Item(kind: .text, name: "Folder \($0)", seed: UInt64($0)) }
    }

    /// Rows of folder `i`'s tab that answer the pointer across at least half its width (below the back edge's
    /// shadow row).
    static func strip(_ i: Int, of items: [InteriorRaster.Item]) -> Int {
        let rects = InteriorRaster.itemRects(.cabinetFile, items: items)
        let r = rects[i]
        var rows = 0
        for y in max(1, r.minY)..<r.maxY {
            let answering = (r.minX..<r.maxX).filter {
                InteriorRaster.item(at: ArtPoint($0, y), .cabinetFile, items: items) == i
            }.count
            if answering * 2 >= r.w { rows += 1 }
        }
        return rows
    }

    @Test("Every folder in the file drawer keeps a pick strip 2 rows deep up to 25 folders, 1 at the hard cap of 26")
    func fileDrawerStrips() {
        let cap = ContainerID.cabinetFile.spec.hardCap
        #expect(cap == 26)
        for n in 1...cap {
            let items = Self.folders(n)
            let size = InteriorRaster.contentSize(.cabinetFile)
            for i in 0..<n {
                // 26 folders take six rows of tabs in the drawer's eight rows of depth.
                let least = n == cap ? 1 : 2
                let s = Self.strip(i, of: items)
                #expect(s >= least, "\(n) folders: folder \(i) answers on \(s) rows")
            }
            for p in InteriorRaster.homes(.cabinetFile, items: items) {
                #expect(p.y >= Int(InteriorRaster.baseBounds(.cabinetFile).lowerBound) && p.y < size.h)
            }
        }
    }

    @Test("A crowded file drawer stands its folders in rows of five, the last nearest the front")
    func fileDrawerRows() {
        let items = Self.folders(20)
        let homes = InteriorRaster.homes(.cabinetFile, items: items)
        // Each row of five takes all five tab slots.
        for row in stride(from: 0, to: 20, by: 5) {
            #expect(Set(homes[row..<row + 5].map(\.x)).count == 5)
            #expect(Set(homes[row..<row + 5].map(\.y)).count == 1)
        }
        #expect(homes.last!.y == InteriorRaster.contentSize(.cabinetFile).h - 1)
        #expect(zip(homes, homes.dropFirst()).allSatisfy { $0.y <= $1.y }, "back to front by index")
        // Up to fourteen folders still fan one by one, as before.
        let fan = InteriorRaster.homes(.cabinetFile, items: Self.folders(14))
        #expect(Set(fan.map(\.y)).count > 5)
    }
}

extension PolishCoreTests {
    /// Review sheet (only with `DESKTERIOR_REVIEW_DIR`): the open file drawer's contents for 10–26 folders, ×6.
    @Test("Review: crowded file drawers", .enabled(if: !(ProcessInfo.processInfo.environment["DESKTERIOR_REVIEW_DIR"] ?? "").isEmpty))
    func reviewFileDrawer() throws {
        let counts = [10, 14, 15, 18, 20, 22, 24, 26]
        let size = InteriorRaster.contentSize(.cabinetFile)
        var sheet = PixelCanvas(width: counts.count * (size.w + 4) + 4, height: size.h + 8, fill: .neutral1)
        for (k, n) in counts.enumerated() {
            let kinds: [FileKind] = [.folder, .text, .pdf, .image, .code, .zip]
            let items = (0..<n).map { InteriorRaster.Item(kind: kinds[$0 % kinds.count], name: "N\($0)", seed: UInt64($0)) }
            let b = InteriorRaster.drawerContents(.cabinetFile, items: items, opening: 18)
            sheet.blit(b, at: ArtPoint(4 + k * (size.w + 4), 4))
        }
        let dir = ProcessInfo.processInfo.environment["DESKTERIOR_REVIEW_DIR"]!
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try PNGCodec.encode(sheet.buffer.scaledNearest(6)).write(to: URL(fileURLWithPath: dir + "/file-drawer.png"))
    }
}

// MARK: Turned keyboard

extension PolishCoreTests {
    static let upright = PropArt.keyboard().image

    @Test("Unturned, the keyboard is the upright sprite; any turn keeps every key and nearly all of its face")
    func turnedKeyboardKeepsItsFace() {
        let zero = TurnedKeyboard(Self.upright, degrees: 0)
        #expect(zero.image == Self.upright && zero.offset == .zero)
        let w = Self.upright.width
        let face = (0..<TurnedKeyboard.faceRows).flatMap { y in (0..<w).map { (x: $0, y: y) } }
            .filter { Self.upright[$0.x, $0.y].a != 0 }
        for degrees in [-170, -120, -60, -45, -30, -15, -7, -2, 2, 7, 14, 15, 30, 45, 60, 90, 135, 180] {
            let t = TurnedKeyboard(Self.upright, degrees: degrees)
            #expect(t.image.pixels.allSatisfy { $0.a == 0 || Apollo.index(of: $0) != nil })
            // The turns a mat on this desk can take (a small mat fits at about 30°); further round, the long axis
            // foreshortens to half in the 2:1 view, and keys narrower than a pixel there merge.
            guard abs(degrees) <= 30 || abs(abs(degrees) - 180) <= 30 else { continue }
            let shown = Set(t.source.filter { $0 >= 0 })
            #expect(Double(shown.count) >= 0.85 * Double(face.count), "\(degrees)°: \(shown.count) of \(face.count)")
            // Every key keeps its face (its cap rows; where two rows' stairs miss, the row above keeps its side over
            // the first of them).
            for key in PropArt.keyboardKeys {
                let face = (key.rect.minY..<(key.rect.minY + 2)).flatMap { y in
                    (key.rect.minX..<key.rect.maxX).map { Int32(y * w + $0) }
                }
                #expect(face.contains { shown.contains($0) }, "\(degrees)°: key \(key.row),\(key.col) is gone")
            }
        }
    }

    /// The image pixels showing upright pixel `s` (`y · width + x`).
    static func shows(_ t: TurnedKeyboard, _ rows: Range<Int>, _ cols: Range<Int>) -> [ArtPoint] {
        let w = upright.width
        return t.source.indices.compactMap { i in
            let s = Int(t.source[i])
            guard s >= 0, rows.contains(s / w), cols.contains(s % w) else { return nil }
            return ArtPoint(i % t.image.width, i / t.image.width)
        }
    }

    @Test("At the turns a mat takes, keys sit level as a whole: no key splits across a stair, Esc and Enter stay solid")
    func turnedKeysAreLevel() {
        for degrees in Array(5...30) + Array(-30 ... -5) {
            let t = TurnedKeyboard(Self.upright, degrees: degrees)
            let slope = abs(tan(Double(degrees) * .pi / 180) / 2)
            for key in PropArt.keyboardKeys {
                // A key the slope raises by under a pixel along it: each of its rows in one image row (column by
                // column its lowest showing; a row left open above it between two rows' stairs repeats its cap).
                guard Double(key.rect.w) * slope < 1 else { continue }
                for y in key.rect.minY..<key.rect.maxY {
                    let pts = Self.shows(t, y..<(y + 1), key.rect.minX..<key.rect.maxX)
                    let lowest = Dictionary(grouping: pts, by: \.x).mapValues { $0.map(\.y).max()! }
                    let ys = Set(lowest.values)
                    #expect(ys.count <= 1, "\(degrees)°: key \(key.row),\(key.col) row \(y) on rows \(ys.sorted())")
                }
            }
            // Every key is a solid block, level or sloping: column by column its cap, face and side rows lie one under
            // the other, its shade only under it (no lit or shaded pixel off its body).
            for key in PropArt.keyboardKeys {
                var rowsAt: [Int: [Int: Int]] = [:]
                for y in key.rect.minY..<key.rect.maxY {
                    for p in Self.shows(t, y..<(y + 1), key.rect.minX..<key.rect.maxX) {
                        rowsAt[p.x, default: [:]][y] = max(rowsAt[p.x]?[y] ?? .min, p.y)
                    }
                }
                for (x, rows) in rowsAt {
                    for (y, vy) in rows {
                        guard let below = rows[y + 1] else { continue }
                        #expect(below == vy + 1, "\(degrees)° key \(key.row),\(key.col) at x \(x)")
                    }
                }
            }
            // Esc, level at these turns: its two red rows over its dark red side, one 4×3 block.
            let esc = PropArt.keyboardKeys.first { $0.row == 0 && $0.col == 0 }!.rect
            let pts = Self.shows(t, esc.minY..<esc.maxY, esc.minX..<esc.maxX)
            let xs = pts.map(\.x), ys = pts.map(\.y)
            if Double(esc.w) * slope < 1 {
                #expect(xs.max()! - xs.min()! < esc.w && ys.max()! - ys.min()! < esc.h, "\(degrees)°: Esc \(pts)")
            }
            // No stray pixel: every opaque pixel touches another on two sides at least.
            let img = t.image
            var spurs: [ArtPoint] = []
            for y in 0..<img.height {
                for x in 0..<img.width where img[x, y].a != 0 {
                    let n = [(1, 0), (-1, 0), (0, 1), (0, -1)].filter { img.pixel(x + $0.0, y + $0.1).a != 0 }.count
                    if n <= 1 { spurs.append(ArtPoint(x, y)) }
                }
            }
            #expect(spurs.isEmpty, "\(degrees)°: spurs at \(spurs)")
        }
    }

    @Test("A turned keyboard keeps its centre and turns the right way; its keys answer where they are drawn")
    func turnedKeyboardGeometry() {
        let c = TurnedKeyboard.centre
        for degrees in [-30, -15, 15, 30] {
            let t = TurnedKeyboard(Self.upright, degrees: degrees)
            let rect = ArtRect(origin: t.offset, size: t.image.size)
            #expect(rect.contains(c), "\(degrees)°")
            // The right end goes back (up) for a counterclockwise turn: compare where Esc and Enter's rows land.
            let left = t.source.firstIndex(of: Int32(6 * Self.upright.width + 1))!
            let right = t.source.firstIndex(of: Int32(6 * Self.upright.width + Self.upright.width - 2))!
            let (ly, ry) = (left / t.image.width, right / t.image.width)
            #expect(degrees > 0 ? ry < ly : ry > ly, "\(degrees)°: left row \(ly), right row \(ry)")
            // Every key's centre pixel, wherever it lands, is that key.
            for key in PropArt.keyboardKeys {
                let s = Int32((key.rect.minY + 1) * Self.upright.width + key.rect.minX + key.rect.w / 2)
                guard let i = t.source.firstIndex(of: s) else { continue }
                let hit = t.key(at: ArtPoint(i % t.image.width, i / t.image.width))
                #expect(hit?.row == key.row && hit?.col == key.col, "\(degrees)° key \(key.row),\(key.col)")
            }
        }
    }

    /// Review sheets (only with `DESKTERIOR_REVIEW_DIR`): the keyboard at the turns a mat takes and past them, on felt,
    /// ×3 and ×8.
    @Test("Review: the turned keyboard", .enabled(if: !(ProcessInfo.processInfo.environment["DESKTERIOR_REVIEW_DIR"] ?? "").isEmpty))
    func reviewTurnedKeyboard() throws {
        let angles = [0, 4, 5, 6, 7, 8, 9, 10, 12, 14, 15, 16, 18, 20, 22, 25, 28, 30,
                      -5, -6, -7, -8, -10, -12, -15, -18, -20, -25, -30, 45, 90, 180]
        let cols = 6, cell = ArtSize(140, 64)
        let rows = (angles.count + cols - 1) / cols
        var sheet = PixelCanvas(width: cols * cell.w, height: rows * cell.h, fill: .blue1)
        for (k, d) in angles.enumerated() {
            let t = TurnedKeyboard(Self.upright, degrees: d)
            let o = ArtPoint((k % cols) * cell.w + 22, (k / cols) * cell.h + 25)
            sheet.blit(t.image, at: ArtPoint(o.x + t.offset.x, o.y + t.offset.y))
            Digits.draw(String(abs(d)), at: ArtPoint((k % cols) * cell.w + 3, (k / cols) * cell.h + 3), d < 0 ? .red4 : .neutral9,
                        into: &sheet)
        }
        let dir = ProcessInfo.processInfo.environment["DESKTERIOR_REVIEW_DIR"]!
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try PNGCodec.encode(sheet.buffer.scaledNearest(3)).write(to: URL(fileURLWithPath: dir + "/turned-keyboard.png"))
        try PNGCodec.encode(sheet.buffer.cropped(to: ArtRect(0, 0, 3 * cell.w, rows * cell.h)).scaledNearest(8))
            .write(to: URL(fileURLWithPath: dir + "/turned-keyboard-zoom-a.png"))
        let right = sheet.buffer.cropped(to: ArtRect(3 * cell.w, 0, 3 * cell.w, rows * cell.h))
        try PNGCodec.encode(right.scaledNearest(8)).write(to: URL(fileURLWithPath: dir + "/turned-keyboard-zoom-b.png"))
    }
}

// MARK: The mat after a peek

extension PolishCoreTests {
    /// Particles off their flat place (> 0.6 px) or off their floor (> 0.3 px).
    static func disturbed(_ c: ClothSim) -> Int {
        let frame = c.matFrame()
        return (0..<c.count).filter { i in
            let f = frame.point(c.uv[i]), p = c.parts[i].x
            let off = ((p.x - f.x) * (p.x - f.x) + (p.y - f.y) * (p.y - f.y)).squareRoot()
            return off > 0.6 || p.z - c.parts[i].floorOffset > 0.3
        }.count
    }

    @Test("Peek Under lays the cloth back exactly where it lay: no ridge, no lifted hem, also after a tall stack is taken out")
    func peekLeavesNoRidge() {
        for takeOut in [false, true] {
            var cloth = ClothSim()
            cloth.setKeyboard(MatState().keyboardFootprint)
            var s = ClothScene(cloth, piles: [PileInput(id: 0, position: SIMD2(331, 30), count: 5)])
            s.frames(300)
            #expect(Self.disturbed(s.cloth) == 0)
            s.cloth.peekUnder(SIMD2(316, 16))
            s.frames(40)
            if takeOut { s.piles = [] }
            s.frames(400)
            #expect(s.cloth.isAsleep && !s.cloth.isScriptRunning)
            #expect(ClothMetrics.maxCrease(s.cloth) < 0.3, "take out \(takeOut): crease \(ClothMetrics.maxCrease(s.cloth))")
            #expect(Self.disturbed(s.cloth) == 0, "take out \(takeOut)")
        }
    }

    @Test("A crease the mat had before a peek is still there after it (O10)")
    func peekKeepsCreases() {
        var cloth = ClothFixtures.wrinkled()
        let w = ClothMetrics.wrinkle(cloth), crease = ClothMetrics.maxCrease(cloth)
        #expect(crease > 1.5)
        let before = cloth.positions
        cloth.peekUnder(SIMD2(300, 10))
        ClothFixtures.run(&cloth, 400)
        #expect(!cloth.isScriptRunning)
        #expect(ClothMetrics.wrinkle(cloth) > w * 0.8 && ClothMetrics.maxCrease(cloth) > crease * 0.8)
        let moved = zip(before, cloth.positions).filter { a, b in simd_length(a - b) > 0.5 }.count
        #expect(moved == 0, "\(moved) particles away from where they lay")
    }
}

// MARK: Tall walls

extension PolishCoreTests {
    @Test("A portrait wall: less ceiling, a short shelf left of the middle, prints right of it, the room light above")
    func tallWallDecor() throws {
        let layout = LayoutSolver.solve(display: pixelGridDesignTable[8].display())
        let crown = try #require(layout.decor(.crown).first).rect
        let wallAbove = layout.coreOrigin.y - max(layout.visible.minY, 0)
        #expect(layout.coreOrigin.y - crown.y == LayoutSolver.wallHeight(wallAbove))
        #expect(crown.y <= 260, "the ceiling no longer fills the top \(crown.y) rows")
        let shelf = try #require(layout.decor(.upperShelf).first).rect
        let gallery = try #require(layout.decor(.gallery).first).rect
        let lamp = try #require(layout.decor(.ceilingLamp).first).rect
        let painting = try #require(layout.decor(.painting).first).rect
        #expect(lamp.maxY < crown.y && lamp.midX == layout.canvas.w / 2 && lamp.size == ArtSize(56, 16))
        // Errata 26: a grouped shelf, not a rail across the wall; the prints beside it and higher; clear of the
        // painting by 32 rows; neither stacked over the monitor's middle.
        #expect(shelf.w <= 200 && shelf.maxX < layout.x(264) && gallery.minX > shelf.maxX + 16)
        #expect(gallery.minY < shelf.minY && gallery.maxY < shelf.maxY)
        #expect(painting.minY - shelf.maxY >= LayoutSolver.paintingClearance)
        #expect(crown.maxY < gallery.minY && crown.maxY < shelf.minY)
        for hung in layout.decor(.pendant) + layout.decor(.hangingPlant) {
            #expect(!hung.rect.intersects(gallery) && !hung.rect.intersects(shelf), "\(hung)")
        }
        // The hanging plant is off the shelf's column.
        let plant = try #require(layout.decor(.hangingPlant).first).rect
        #expect(plant.minX > shelf.maxX)
        // Clear of every interactive rect.
        for d in [shelf, gallery, lamp] {
            for name in Anchors.interactive { #expect(!(layout.anchors[name]?.intersects(d) ?? false), "\(name)") }
        }
        // Medium and landscape walls are as they were: no upper shelf, prints or ceiling lamp.
        for row in pixelGridDesignTable.dropLast() {
            let kinds = Set(LayoutSolver.solve(display: row.display()).decor.map(\.kind))
            #expect(kinds.isDisjoint(with: [.upperShelf, .gallery, .ceilingLamp]), "\(row.name)")
        }
    }

    @Test("The ceiling lamp lights with the room light after dark: its glass only")
    func ceilingLampLight() throws {
        let layout = LayoutSolver.solve(display: pixelGridDesignTable[8].display())
        let lamp = try #require(layout.decor(.ceilingLamp).first).rect
        let glass = DecorArt.ceilingLampGlass(in: lamp.size).map { ArtPoint(lamp.x + $0.x, lamp.y + $0.y) }
        let night = TimeOfDay(phase: .night, roomLightOn: true)
        let lit = LightMask.room(layout, lights: RoomLightState(), time: night)
        #expect(glass.allSatisfy { lit.level($0.x, $0.y) == 7 })
        #expect(lit.level(lamp.x - 2, lamp.y) < 7)
        let dark = LightMask.room(layout, lights: RoomLightState(roomLightOn: false),
                                  time: TimeOfDay(phase: .night, roomLightOn: false))
        #expect(glass.allSatisfy { dark.level($0.x, $0.y) < 7 })
    }
}

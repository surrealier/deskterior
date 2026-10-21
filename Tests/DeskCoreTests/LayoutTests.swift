import Testing
@testable import DeskCore

@Suite("Layout")
struct LayoutTests {
    @Test("Every anchor sits inside the visible band (§1.2 table × Dock variants)",
          arguments: pixelGridDesignTable, PixelGridDock.allCases)
    func anchorsVisible(_ row: PixelGridTableRow, _ dock: PixelGridDock) {
        let layout = LayoutSolver.solve(display: row.display(dock: dock))
        for name in layout.anchors.names where name != "floor" {
            let r = layout.anchors[name]!
            #expect(layout.visible.contains(r), "\(row.name) \(dock): \(name) \(r) outside \(layout.visible)")
        }
    }

    @Test("Interactive rects do not overlap except where the composition intends it")
    func interactiveOverlaps() {
        let a = Anchors.core
        let names = Anchors.interactive
        for (i, x) in names.enumerated() {
            for y in names[(i + 1)...] where a[x]!.intersects(a[y]!) {
                #expect(Anchors.overlapIsIntended(x, y), "\(x) \(a[x]!) overlaps \(y) \(a[y]!)")
            }
        }
        // The intended overlaps really are overlaps (so the list stays honest).
        for pair in Anchors.intendedOverlaps {
            #expect(a[pair[0]]!.intersects(a[pair[1]]!), "\(pair) no longer overlap")
        }
    }

    @Test("Named anchors used by hit-testing and demo scripts exist")
    func requiredAnchors() {
        for name in [
            "monitor.power", "monitor.screen", "monitor.input", "monitor.led", "riser.drawerL.handle",
            "riser.drawerR.handle", "riser.cubby", "cabinet.top.handle", "cabinet.top.front", "cabinet.middle.handle",
            "cabinet.file.handle", "mat.default", "mat.edge.e", "wastebasket.mouth", "phone", "pencup.mouth",
            "lamp.switch", "room.switch", "clock", "keyboard", "brush", "chair", "apron", "hub",
        ] {
            #expect(Anchors.core[name] != nil, "missing anchor \(name)")
        }
        #expect(Anchors.core.point("monitor.power") == ArtPoint(350, 135))
    }

    @Test("Handles sit inside their drawer fronts; cabinet fronts stack to the plinth")
    func handlesInsideFronts() {
        let a = Anchors.core
        for d in ["riser.drawerL", "riser.drawerR"] {
            #expect(a[d]!.contains(a["\(d).handle"]!))
        }
        var y = CoreLayout.cabinet.y
        for (i, name) in Anchors.cabinetDrawerNames.enumerated() {
            let front = a["cabinet.\(name)"]!
            #expect(front.y == y && front.h == CoreLayout.cabinetFrontHeights[i])
            #expect(front.contains(a["cabinet.\(name).handle"]!))
            y = front.maxY
        }
        #expect(y + CoreLayout.cabinetPlinth == CoreLayout.cabinet.maxY)
        #expect(CoreLayout.cabinet.maxY == CoreLayout.floorY)
    }

    @Test("Canvas anchors are the core table moved to the core origin")
    func canvasAnchors() {
        let layout = LayoutSolver.solve(display: pixelGridDesignTable[0].display(dock: .hidden))
        let o = layout.coreOrigin
        // The grid puts the floor line on the screen's bottom edge; the core rises to show some floor.
        #expect(layout.floorLift == LayoutSolver.minFloorMargin - 1)
        #expect(o == ArtPoint(38, 70 - layout.floorLift))
        #expect(layout.anchors["monitor.screen"] == CoreLayout.screen.offsetBy(o.x, o.y))
        #expect(layout.floorY == o.y + 312)
        #expect(layout.rect(CoreLayout.window) == CoreLayout.window.offsetBy(o.x, o.y))
    }

    @Test("Decor stays on the canvas, below the menu bar, and clear of the core's wall pieces",
          arguments: pixelGridDesignTable, PixelGridDock.allCases)
    func decorPlacement(_ row: PixelGridTableRow, _ dock: PixelGridDock) {
        let layout = LayoutSolver.solve(display: row.display(dock: dock))
        let canvas = ArtRect(0, 0, layout.canvas.w, layout.canvas.h)
        let core = [CoreLayout.window, CoreLayout.clock, CoreLayout.calendar, CoreLayout.monitorBody, CoreLayout.roomSwitch,
                    CoreLayout.lampHead, CoreLayout.phone, CoreLayout.driveHub, CoreLayout.deskTop].map(layout.rect)
        for d in layout.decor {
            #expect(canvas.contains(d.rect), "\(d) off canvas")
            let hangsFromCeiling: Set<WallDecor.Kind> = [.ceiling, .crown, .pendant, .hangingPlant]
            if !hangsFromCeiling.contains(d.kind) { #expect(d.rect.minY >= layout.visible.minY, "\(d) behind the menu bar") }
            if d.kind == .floorPlant { continue }
            for r in core where d.kind != .stringLights || r.minY < d.rect.maxY {
                #expect(!d.rect.intersects(r), "\(row.name) \(dock): \(d) overlaps \(r)")
            }
        }
        // Every display gets the shelf; this Mac also gets string lights, a print and a pegboard.
        #expect(!layout.decor(.shelf).isEmpty)
    }

    // MARK: memos (0.3.0)

    /// Widgets in the margins and over the screen, so the core nudges left and right of centre.
    static let avoidSets: [[ArtRect]] = [
        [], [ArtRect(0, 0, 90, 90)], [ArtRect(500, 0, 140, 140)], [ArtRect(280, 60, 40, 30)], [ArtRect(160, 60, 40, 30)],
    ]

    @Test("The partition and its pieces are visible and no decor meets it, on every display, Dock and widget nudge",
          arguments: pixelGridDesignTable, PixelGridDock.allCases)
    func partitionClearOfDecor(_ row: PixelGridTableRow, _ dock: PixelGridDock) {
        for avoid in Self.avoidSets {
            let layout = LayoutSolver.solve(display: row.display(dock: dock), avoid: avoid)
            for name in ["partition", "partition.tower", "partition.post", "partition.cube", "partition.pad",
                         "partition.clips", "partition.dday", "partition.clipLight", "calendar"] {
                #expect(layout.visible.contains(layout.anchors[name]!), "\(row.name) \(dock) \(avoid): \(name)")
            }
            let parts = [CoreLayout.partitionLow, CoreLayout.partitionTower, CoreLayout.partitionClipLight]
                + CoreLayout.partitionClamps
            for d in layout.decor where ![.ceiling, .crown].contains(d.kind) {
                for part in parts {
                    #expect(!d.rect.intersects(layout.rect(part)), "\(row.name) \(dock) \(avoid): \(d) meets \(part)")
                }
            }
        }
    }

    @Test("The partition's rects: inside the core, clear of the wall pieces, on the desk's back edge")
    func partitionRects() {
        typealias L = CoreLayout
        let core = ArtRect(0, 0, L.size.w, L.size.h)
        for r in [L.partition, L.partitionLow, L.partitionTower, L.partitionClipLight, L.partitionLampWash]
            + L.partitionClamps {
            #expect(core.contains(r), "\(r)")
        }
        #expect(L.partitionLow.maxY == L.deskBackY && L.partitionLow.minX == L.deskTop.minX
            && L.partitionLow.maxX == L.deskTop.maxX)
        #expect(L.partitionTower.maxY == L.partitionLow.minY && L.partitionTower.minX == L.monitorBody.maxX)
        for wall in [L.window, L.roomSwitch, L.clock, L.calendar] {
            for part in [L.partitionLow, L.partitionTower, L.partitionClipLight] { #expect(!wall.intersects(part)) }
        }
        #expect(L.partitionClipLight.contains(L.partitionClipBulb))
        #expect(L.partitionClipWash.contains(L.partitionClipWashClip) && L.partitionClipWashClip.contains(L.partitionTower))
        #expect(L.partitionLow.contains(L.partitionLampWashClip))
        // Nothing new is critical: a widget may cover the partition (§1.2), so putting things away never nudges.
        for r in LayoutSolver.criticalCoreRects { #expect(!r.intersects(L.partitionTower)) }
        #expect(LayoutSolver.criticalCoreRects.count == 7)
    }

    @Test("Hiding put-away decor keeps the grid, the anchors and the lift; it is idempotent")
    func hidingDecor() {
        for row in pixelGridDesignTable {
            let layout = LayoutSolver.solve(display: row.display())
            let kinds = StowCatalog.decorKinds(hiddenBy: [.wallShelf, .stringLights, .wallArt, .floorPlant, .pegboard])
            let hidden = layout.hiding(kinds)
            #expect(hidden.grid == layout.grid && hidden.anchors == layout.anchors && hidden.floorLift == layout.floorLift)
            #expect(hidden.decor.allSatisfy { !kinds.contains($0.kind) })
            #expect(hidden.decor == layout.decor.filter { !kinds.contains($0.kind) })
            #expect(hidden.hiding(kinds) == hidden)
        }
    }

    // MARK: picture frame (0.4.0)

    @Test("Every display and Dock gets exactly one framed print, 32×40: the photo's slot (Erratum 33)",
          arguments: pixelGridDesignTable, PixelGridDock.allCases)
    func frameSlot(_ row: PixelGridTableRow, _ dock: PixelGridDock) {
        let layout = LayoutSolver.solve(display: row.display(dock: dock))
        let frames = layout.decor(.frame)
        #expect(frames.count == 1, "\(row.name) \(dock): \(frames.count) frames")
        for f in frames {
            #expect(f.rect.size == ArtSize(32, 40), "\(row.name) \(dock): \(f.rect)")
            #expect(DecorArt.photoWindow(in: f.rect.size).size == FramePhoto.size)
        }
    }

    @Test("This Mac (Dock hidden): the margins fill with decor")
    func thisMacDecor() {
        let layout = LayoutSolver.solve(display: pixelGridDesignTable[0].display(dock: .hidden))
        let kinds = Set(layout.decor.map(\.kind))
        #expect(kinds == [.stringLights, .shelf, .frame, .pegboard, .floorPlant])
    }

    @Test("Tall walls get a painting and crown moulding")
    func portraitDecor() {
        let layout = LayoutSolver.solve(display: pixelGridDesignTable[8].display())
        let kinds = Set(layout.decor.map(\.kind))
        #expect(kinds.isSuperset(of: [.ceiling, .crown, .painting, .stringLights, .shelf, .pendant, .hangingPlant]))
        let painting = layout.decor(.painting)[0].rect
        #expect(painting.maxY <= layout.coreOrigin.y)
    }

    @Test("Widget nudge: a widget over the screen moves the core by 8-px steps until it clears")
    func widgetNudge() {
        let display = pixelGridDesignTable[1].display()   // 1280x832: 64 px of slack each side
        let base = LayoutSolver.solve(display: display)
        #expect(base.grid.nudge == 0 && !base.avoidUnresolved)
        let screen = base.anchors["monitor.screen"]!
        let widget = ArtRect(screen.maxX - 20, screen.y, 40, 30)
        let nudged = LayoutSolver.solve(display: display, avoid: [widget])
        #expect(!nudged.avoidUnresolved)
        #expect(nudged.grid.nudge % LayoutSolver.nudgeStep == 0 && nudged.grid.nudge != 0)
        for core in LayoutSolver.criticalCoreRects {
            #expect(!nudged.rect(core).intersects(widget))
        }
        // A widget too wide to dodge leaves the core centred and asks for the tip.
        let wall = ArtRect(0, screen.y, nudged.canvas.w, 10)
        let stuck = LayoutSolver.solve(display: display, avoid: [wall])
        #expect(stuck.avoidUnresolved && stuck.grid.nudge == 0)
    }

    @Test("Device rects convert to the art pixels they touch")
    func deviceToArt() {
        let grid = PixelGrid(display: pixelGridDesignTable[0].display(dock: .hidden))
        // Widgets on this Mac: 180×180 pt at (8, 45) pt → device px ×2.
        let r = LayoutSolver.artRect(coveringDevice: DeviceRect(16, 90, 360, 360), grid: grid)
        #expect(r == ArtRect(3, 18, 73, 73))
    }
}

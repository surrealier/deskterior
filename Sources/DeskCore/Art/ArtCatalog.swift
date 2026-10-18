/// Every sprite the room uses, grouped for contact sheets and the catalog test (each state and frame set).
public enum ArtCatalog {
    public struct Section: Sendable {
        public let title: String
        public let sprites: [SpriteAsset]
    }

    public static func sections() -> [Section] {
        [room(), decor(), monitor(), storage(), props(), icons(), fx(), partition()]
    }

    /// All sprites, in section order.
    public static func all() -> [SpriteAsset] {
        sections().flatMap(\.sprites)
    }

    static func room() -> Section {
        var s: [SpriteAsset] = [RoomArt.roomSwitch(on: true), RoomArt.roomSwitch(on: false)]
        for (h, m) in [(10, 0), (22, 0), (3, 47), (18, 30)] {
            s.append(RoomArt.clock(hour: h, minute: m).renamed("clock.\(h).\(m)"))
        }
        s.append(RoomArt.calendar(WallTime(year: 2026, month: 10, day: 14, hour: 10, minute: 0)))
        s.append(RoomArt.calendar(WallTime(year: 2026, month: 8, day: 31, hour: 10, minute: 0)).renamed("calendar.aug"))
        for sky in SkyVariant.allCases { s.append(WindowArt.window(sky: sky, minuteOfDay: 600)) }
        s.append(RoomArt.deskFront())
        let layout = LayoutSolver.solve(display: DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2, topInsetPt: 33))
        s.append(RoomArt.lampHalo(layout))
        s.append(RoomArt.lampPool(layout))
        return Section(title: "room", sprites: s)
    }

    static func decor() -> Section {
        let lights = ArtRect(0, 0, 160, 14)
        return Section(title: "decor", sprites: [
            RoomArt.stringLights(lights, lit: false), RoomArt.stringLights(lights, lit: true),
            DecorArt.shelf(ArtSize(92, 36)), DecorArt.shelf(ArtSize(60, 36)).renamed("decor.shelf.narrow"),
            DecorArt.frame(ArtSize(32, 40)), DecorArt.pegboard(ArtSize(40, 44)), DecorArt.painting(ArtSize(112, 64)),
            DecorArt.floorPlant(ArtSize(38, 92)), RoomArt.crown(width: 64),
            DecorArt.pendant(ArtSize(24, 60), lit: false), DecorArt.pendant(ArtSize(24, 60), lit: true),
            DecorArt.hangingPlant(ArtSize(32, 90)), RoomArt.ceiling(ArtSize(64, 48)), RoomArt.rail(width: 64),
            DecorArt.painting(ArtSize(48, 30)).renamed("decor.painting.small"),
            // MARK: w6-polish
            DecorArt.upperShelf(ArtSize(180, 44)), DecorArt.gallery(ArtSize(168, 96)),
            DecorArt.ceilingLamp(ArtSize(56, 16), lit: false), DecorArt.ceilingLamp(ArtSize(56, 16), lit: true),
            DecorArt.wallHanging(ArtSize(90, 200)),
            RoomArt.ceiling(ArtSize(160, 96)).renamed("decor.ceiling.beams"),
        ])
    }

    static func monitor() -> Section {
        let wall = MonitorArt.deskOSWallpaper()
        return Section(title: "monitor", sprites: [
            MonitorArt.body(), MonitorArt.stand(),
            MonitorArt.powerButton(pressed: false), MonitorArt.powerButton(pressed: true),
            MonitorArt.inputButton(pressed: false), MonitorArt.inputButton(pressed: true),
            SpriteAsset("screen.deskOS", frames: SkyVariant.allCases.map { MonitorArt.deskOSWallpaper(sky: $0) }, anchor: .zero),
            SpriteAsset("screen.off", MonitorArt.screenOff(), anchor: .zero),
            SpriteAsset("screen.powerOff", frames: MonitorArt.powerOffFrames(from: wall), anchor: .zero),
            SpriteAsset("screen.powerOn", frames: MonitorArt.powerOnFrames(to: wall), anchor: .zero),
            MonitorArt.noSignalLogo(),
            SpriteAsset("screen.noSignal", MonitorArt.noSignalScreen(), anchor: .zero),
            SpriteAsset("screen.static", frames: MonitorArt.staticFrames(), anchor: .zero),
            MonitorArt.led(.on), MonitorArt.led(.amber), MonitorArt.led(.off),
            MonitorArt.pageDots(count: 1, current: 0), MonitorArt.pageDots(count: 4, current: 2),
            SpriteAsset("badge.+3", Digits.badge("+3"), anchor: .zero),
        ])
    }

    static func storage() -> Section {
        var s: [SpriteAsset] = [StorageArt.riser()]
        for p in [0, 3, 6, 10] { s.append(StorageArt.riserDrawer(p: p)) }
        s.append(StorageArt.riserDrawer(p: 4, jammed: true))
        s.append(StorageArt.cabinet())
        s.append(StorageArt.cabinet(p: [12, 0, 0]))
        s.append(StorageArt.cabinet(p: [0, 14, 0]))
        s.append(StorageArt.cabinet(p: [0, 0, 18]))
        s.append(StorageArt.cabinet(p: [4, 0, 0], jammed: [true, false, false]))
        s.append(StorageArt.folderTab(.blue3))
        s.append(StorageArt.paperEdges(width: 56, rows: 3))
        return Section(title: "storage", sprites: s)
    }

    static func props() -> Section {
        let pens: [Ink] = [.red3, .blue3, .green3, .walnut4]
        var s: [SpriteAsset] = [PropArt.lamp(on: false), PropArt.lamp(on: true), PropArt.plant()]
        s.append(PropArt.penCup())
        s.append(PropArt.penCup(pens: pens))
        for i in 0..<3 { s.append(PropArt.penCup(.tipping(i))) }
        s.append(PropArt.penCup(.lying(right: true)))
        s.append(PropArt.penCup(.lying(right: false)))
        s.append(PropArt.pen(.red3))
        let minis = IconKind.allCases.prefix(5).map { KindIcons.mini($0).image }
        s.append(SpriteAsset("phone.flip", frames: PropArt.PhoneFace.allCases.map { PropArt.phoneStand(face: $0).image }))
        s.append(PropArt.phoneStand(face: .up, minis: Array(minis)).renamed("phone.up.minis"))
        s.append(PropArt.driveHub())
        for k in PropArt.DriveKind.allCases { s.append(PropArt.drive(k)) }
        s.append(PropArt.brush())
        s.append(PropArt.keyboard())
        s.append(PropArt.keyboard(pressed: (row: 1, col: 3)))
        for f in PropArt.ChairFacing.allCases { s.append(PropArt.chair(f)) }
        s.append(PropArt.wastebasketBack())
        s.append(PropArt.wastebasketFront())
        for v in 0..<3 { s.append(PropArt.paperBall(v)) }
        return Section(title: "props", sprites: s)
    }

    static func icons() -> Section {
        var s: [SpriteAsset] = []
        for size in [16, 12] { for k in IconKind.allCases { s.append(KindIcons.icon(k, size: size)) } }
        s.append(KindIcons.aliasOverlay())
        s.append(KindIcons.tagStripe(.red4))
        for k in IconKind.allCases { s.append(KindIcons.mini(k)) }
        return Section(title: "icons", sprites: s)
    }

    static func fx() -> Section {
        var s: [SpriteAsset] = [FXArt.dustPuff(), FXArt.sparkle(), FXArt.squash(KindIcons.icon(.folder).image)]
        for p in FXArt.Pop.allCases { s.append(FXArt.pop(p)) }
        s.append(FXArt.stickyNote())
        s.append(SpriteAsset("digits", Digits.render("0123456789+-", .neutral9), anchor: .zero))
        s.append(SpriteAsset("letters", Digits.render("ABCDEFGHIJKLMNOPRSTUVWY", .neutral9), anchor: .zero))
        return Section(title: "fx", sprites: s)
    }

    // MARK: memos (0.3.0)
    /// The desk partition and what hangs on it (Erratum 31), the sealed riser and the marked calendar (Erratum 30).
    static func partition() -> Section {
        let sunday = WallTime(year: 2026, month: 10, day: 18, hour: 10, minute: 0)
        let saturday = WallTime(year: 2026, month: 10, day: 24, hour: 10, minute: 0)
        let tuesday = WallTime(year: 2026, month: 12, day: 1, hour: 10, minute: 0)
        var s: [SpriteAsset] = [PartitionArt.panel(), PartitionArt.cube()]
        s.append(PartitionArt.dailyPad(sunday, written: false))
        s.append(PartitionArt.dailyPad(saturday, written: true))
        s.append(PartitionArt.dailyPad(tuesday, written: true))
        s.append(SpriteAsset("partition.padPeel", frames: (0..<3).map { PartitionArt.padPeel($0).image }, anchor: .zero))
        s.append(PartitionArt.clipsRail())
        s.append(PartitionArt.clipCard(image: false))
        s.append(PartitionArt.clipCard(image: true))
        for days in [12, 3, 0, -3, 999] { s.append(PartitionArt.dDayCard(days: days)) }
        s.append(PartitionArt.clipLight(on: false))
        s.append(PartitionArt.clipLight(on: true))
        for c in NoteColour.allCases {
            s.append(PartitionArt.notePaper(c, dated: false, pinned: false))
            s.append(PartitionArt.notePaper(c, dated: true, pinned: true))
        }
        for c in NoteColour.allCases {
            for f in 0..<4 { s.append(PartitionArt.noteCrumple(c, frame: f)) }
        }
        s.append(StorageArt.riser(sealed: true))
        let marks: [Int: CalendarMark] = [3: .memo, 9: .note, 18: .memo, 21: [.memo, .note], 30: .dDay]
        s.append(RoomArt.calendar(sunday, marks: marks).renamed("calendar.marks"))
        s.append(RoomArt.calendar(WallTime(year: 2026, month: 8, day: 31, hour: 10, minute: 0), marks: [5: .note, 22: .dDay])
            .renamed("calendar.marks.aug"))
        return Section(title: "partition", sprites: s)
    }
}

// MARK: - The room's arrangement

/// Scene layers back to front (DESIGN §1.3).
public enum RoomLayer: Int, CaseIterable, Comparable, Sendable {
    case backdrop, deskBack, deskSurface, deskFront, apron, underDesk, chair, fx, carry, ui

    public static func < (a: RoomLayer, b: RoomLayer) -> Bool { a.rawValue < b.rawValue }
}

/// What the room shows at one moment (the parts M3 draws statically; later milestones animate them).
public struct RoomState: Equatable, Sendable {
    public var time: WallTime
    public var lightsMode: LightsMode
    public var lights: RoomLightState
    public var riserOpen: [Int]
    public var cabinetOpen: [Int]
    public var chairX: Int
    public var chairFacing: PropArt.ChairFacing
    // MARK: tidy and memos (0.3.0)
    /// Objects put away (Erratum 30): their placements are skipped.
    public var stowed: Set<StowID> = []
    /// The wall calendar's marks for the month shown, by day (Erratum 31).
    public var calendarMarks: [Int: CalendarMark] = [:]
    /// Today's page has text (the pad shows scribbles).
    public var padWritten = false
    /// Days to the D-Day (negative after it); nil while none is set.
    public var dDayDays: Int?

    public init(
        time: WallTime, lightsMode: LightsMode = .auto, lights: RoomLightState = RoomLightState(),
        riserOpen: [Int] = [0, 0], cabinetOpen: [Int] = [0, 0, 0], chairX: Int = CoreLayout.chair.x,
        chairFacing: PropArt.ChairFacing = .back
    ) {
        self.time = time
        self.lightsMode = lightsMode
        self.lights = lights
        self.riserOpen = riserOpen
        self.cabinetOpen = cabinetOpen
        self.chairX = chairX
        self.chairFacing = chairFacing
    }

    /// The lights a mode implies (Lamp Only forces the room light off and the lamp on).
    public var effectiveLights: RoomLightState { lights.applying(lightsMode) }

    public var timeOfDay: TimeOfDay {
        TimeOfDay(time, mode: lightsMode, roomLightOn: effectiveLights.roomLightOn)
    }

    /// The sky follows the phase (forced phases show their own sky).
    public var sky: SkyVariant { timeOfDay.sky }
}

/// One sprite placed in the room (canvas px).
public struct RoomPlacement: Equatable, Sendable {
    /// Stable id ("monitor.body", "riser.drawerL", …); elements own the ids with their prefix.
    public let id: String
    public let layer: RoomLayer
    public let sprite: SpriteAsset
    public let frame: Int
    /// Canvas top-left.
    public let origin: ArtPoint

    public init(_ id: String, _ layer: RoomLayer, _ sprite: SpriteAsset, at origin: ArtPoint, frame: Int = 0) {
        self.id = id
        self.layer = layer
        self.sprite = sprite
        self.frame = frame
        self.origin = origin
    }

    public var rect: ArtRect { ArtRect(origin: origin, size: sprite.size) }
    public var image: PixelBuffer { sprite.frames[min(frame, sprite.frames.count - 1)] }
}

/// The static arrangement of the room: every sprite, its layer and canvas position, for a layout and state.
/// DeskScene's elements place exactly these; `compose` renders them on the CPU (contact sheets, tests).
public enum RoomPlan {
    /// Placement ids whose sprites depend on `RoomState` (the rest only depend on the layout).
    public static let stateDependentIDs: Set<String> = [
        "decor", "glow.lampHalo", "glow.lampPool", "window", "clock", "calendar", "room.switch", "riser.drawerL",
        "riser.drawerR", "monitor.screen", "monitor.led", "lamp", "phone", "cabinet", "chair",
    ]
    /// Painted light that belongs to the room's backdrop (never hit-tested as an object).
    public static let glowIDs: Set<String> = ["glow.lampHalo", "glow.lampPool"]
    /// Ids that change from minute to minute within one light phase.
    public static let minuteIDs: Set<String> = ["window", "clock", "calendar"]
    // MARK: memos (0.3.0)
    /// Ids that follow the memos (the calendar's marks, the pad's page, the D-Day card).
    public static let memoIDs: Set<String> = ["calendar", "partition.pad", "partition.dday"]

    /// The placements, back to front. With `only`, builds just those ids ("decor" stands for every decor piece).
    public static func placements(_ layout: SceneLayout, _ state: RoomState, only: Set<String>? = nil) -> [RoomPlacement] {
        var out: [RoomPlacement] = []
        let lights = state.effectiveLights
        let tod = state.timeOfDay
        func wanted(_ id: String) -> Bool { only.map { $0.contains(id) } ?? true }
        func add(_ id: String, _ layer: RoomLayer, _ sprite: @autoclosure () -> SpriteAsset, core: ArtPoint) {
            guard wanted(id) else { return }
            out.append(RoomPlacement(id, layer, sprite(), at: layout.point(core)))
        }

        if wanted("backdrop") {
            out.append(RoomPlacement("backdrop", .backdrop, SpriteAsset("backdrop", RoomArt.backdrop(layout), anchor: .zero),
                                     at: .zero))
        }
        // The lamp's bloom and the warm centre of its pool, when the room is dark enough (blank otherwise, so
        // a refresh replaces them).
        let glowing = lights.lampOn && RoomArt.lampGlows(tod)
        if wanted("glow.lampPool") {
            out.append(glowing
                ? RoomPlacement("glow.lampPool", .backdrop, RoomArt.lampPool(layout), at: layout.rect(CoreLayout.lampPool).origin)
                : RoomPlacement("glow.lampPool", .backdrop, blank("glow.lampPool.off"), at: .zero))
        }
        if wanted("decor") {
            for (i, d) in layout.decor.enumerated() {
                let lit = switch d.kind {
                case .pendant, .ceilingLamp: tod.isDark && lights.roomLightOn
                case .stringLights: RoomArt.stringLightsLit(tod)
                default: tod.isDark
                }
                out.append(RoomPlacement("decor.\(d.kind.rawValue).\(i)", .backdrop, DecorArt.sprite(d, lit: lit),
                                         at: d.rect.origin))
            }
        }
        add("window", .backdrop, WindowArt.window(sky: state.sky, minuteOfDay: state.time.minuteOfDay),
            core: CoreLayout.window.origin)
        add("clock", .backdrop, RoomArt.clock(hour: state.time.hour, minute: state.time.minute), core: CoreLayout.clock.origin)
        add("calendar", .backdrop, RoomArt.calendar(state.time), core: CoreLayout.calendar.origin)
        add("room.switch", .backdrop, RoomArt.roomSwitch(on: lights.roomLightOn), core: CoreLayout.roomSwitch.origin)

        add("plant", .deskBack, PropArt.plant(), core: CoreLayout.plant.origin)
        add("riser", .deskBack, StorageArt.riser(), core: CoreLayout.riser.origin)
        add("riser.drawerL", .deskBack, StorageArt.riserDrawer(p: state.riserOpen.first ?? 0), core: CoreLayout.riserDrawerL.origin)
        add("riser.drawerR", .deskBack, StorageArt.riserDrawer(p: state.riserOpen.dropFirst().first ?? 0),
            core: CoreLayout.riserDrawerR.origin)
        add("monitor.stand", .deskBack, MonitorArt.stand(), core: MonitorArt.standRect.origin)
        add("monitor.body", .deskBack, MonitorArt.body(), core: CoreLayout.monitorBody.origin)
        add("monitor.screen", .deskBack,
            lights.monitorOn
                ? SpriteAsset("screen.deskOS.\(state.sky.rawValue)", MonitorArt.deskOSWallpaper(sky: state.sky), anchor: .zero)
                : SpriteAsset("screen.off", MonitorArt.screenOff(), anchor: .zero),
            core: CoreLayout.screen.origin)
        add("monitor.led", .deskBack, MonitorArt.led(lights.monitorOn ? .on : .off), core: CoreLayout.led.origin)
        add("monitor.pageDots", .deskBack, MonitorArt.pageDots(count: 1, current: 0), core: CoreLayout.pageDots.origin)
        // The bulb's bloom spills out of the shade's mouth over the monitor's edge, behind the lamp itself.
        if wanted("glow.lampHalo") {
            out.append(glowing
                ? RoomPlacement("glow.lampHalo", .deskBack, RoomArt.lampHalo(layout), at: RoomArt.lampHaloOrigin(layout))
                : RoomPlacement("glow.lampHalo", .deskBack, blank("glow.lampHalo.off"), at: .zero))
        }
        add("lamp", .deskBack, PropArt.lamp(on: lights.lampOn), core: PropArt.lampRect.origin)
        add("phone", .deskBack, PropArt.phoneStand(faceUp: lights.phoneFaceUp), core: CoreLayout.phone.origin)
        add("hub", .deskBack, PropArt.driveHub(), core: CoreLayout.driveHub.origin)

        // The desk-surface layer is the scene's desk mat (it takes this slot); the bare room shows only the keyboard's
        // contact shadow here.
        add("mat.keyboardShadow", .deskSurface, RoomArt.keyboardShadow(), core: CoreLayout.keyboard.origin)

        add("keyboard", .deskFront, PropArt.keyboard(), core: CoreLayout.keyboard.origin)
        add("brush", .deskFront, PropArt.brush(), core: CoreLayout.brush.origin)
        add("pencup", .deskFront, PropArt.penCupOnDesk(), core: CoreLayout.penCup.origin)

        add("desk.front", .apron, RoomArt.deskFront(), core: CoreLayout.apron.origin)

        add("cabinet", .underDesk, StorageArt.cabinet(p: state.cabinetOpen), core: StorageArt.cabinetSpriteOrigin)
        add("wastebasket.back", .underDesk, PropArt.wastebasketBack(), core: CoreLayout.wastebasket.origin)
        add("wastebasket.front", .underDesk, PropArt.wastebasketFront(), core: CoreLayout.wastebasket.origin)

        add("chair", .chair, PropArt.chair(state.chairFacing), core: ArtPoint(state.chairX, CoreLayout.chair.y))
        return out
    }

    /// A 1×1 transparent stand-in for a placement that shows nothing right now.
    static func blank(_ name: String) -> SpriteAsset {
        SpriteAsset(name, PixelBuffer(width: 1, height: 1), anchor: .zero)
    }

    /// The unlit room on the CPU, back to front (stable within a layer).
    public static func compose(_ layout: SceneLayout, _ state: RoomState) -> PixelBuffer {
        compose(layout.canvas, placements(layout, state))
    }

    public static func compose(_ canvas: ArtSize, _ placements: [RoomPlacement]) -> PixelBuffer {
        var out = PixelBuffer(width: canvas.w, height: canvas.h, fill: Ink.neutral1.color)
        let ordered = placements.enumerated().sorted { ($0.element.layer, $0.offset) < ($1.element.layer, $1.offset) }
        for (_, p) in ordered { out.blit(p.image, at: p.origin) }
        return out
    }

    /// The lit room (CPU twin of the GPU lit pass).
    public static func render(_ layout: SceneLayout, _ state: RoomState) -> PixelBuffer {
        let tod = state.timeOfDay
        let mask = LightMask.room(layout, lights: state.effectiveLights, time: tod)
        return mask.apply(to: compose(layout, state), ambient: tod.ambient)
    }
}

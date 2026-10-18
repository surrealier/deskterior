/// Named anchor rects ("monitor.power", "cabinet.top.handle", "mat.edge.e", …) for hit-testing and demo
/// scripts (DESIGN §4.11). `Anchors.core` is in core px; `SceneLayout.anchors` is the same table in canvas px.
public struct Anchors: Hashable, Sendable {
    private var table: [String: ArtRect]

    public init(_ table: [String: ArtRect] = [:]) {
        self.table = table
    }

    public subscript(_ name: String) -> ArtRect? {
        get { table[name] }
        set { table[name] = newValue }
    }

    /// The anchor's centre point (where scripted clicks land).
    public func point(_ name: String) -> ArtPoint? {
        table[name]?.center
    }

    /// Every anchor name, sorted.
    public var names: [String] { table.keys.sorted() }

    public var count: Int { table.count }

    /// The whole table moved by `(dx, dy)`.
    public func offsetBy(_ dx: Int, _ dy: Int) -> Anchors {
        Anchors(table.mapValues { $0.offsetBy(dx, dy) })
    }

    /// Anchor names whose rects contain `p`.
    public func names(containing p: ArtPoint) -> [String] {
        names.filter { table[$0]!.contains(p) }
    }

    // MARK: The core table

    /// Every named anchor in core px.
    public static let core: Anchors = {
        typealias L = CoreLayout
        var a: [String: ArtRect] = [
            "window": L.window,
            "room.switch": L.roomSwitch,
            "clock": L.clock,
            "calendar": L.calendar,

            "monitor": L.monitorBody,
            "monitor.screen": L.screen,
            "monitor.chin": L.chin,
            "monitor.input": L.input,
            "monitor.pageDots": L.pageDots,
            "monitor.led": L.led,
            "monitor.power": L.powerHit,
            "monitor.neck": L.neck,

            "riser": L.riser,
            "riser.drawerL": L.riserDrawerL,
            "riser.drawerL.front": L.riserDrawerL,
            "riser.drawerL.handle": handle(of: L.riserDrawerL, width: 12),
            "riser.cubby": L.riserCubby,
            "riser.drawerR": L.riserDrawerR,
            "riser.drawerR.front": L.riserDrawerR,
            "riser.drawerR.handle": handle(of: L.riserDrawerR, width: 12),

            "lamp": L.lampBase.union(L.lampHead),
            "lamp.base": L.lampBase,
            "lamp.switch": L.lampSwitch,
            "lamp.head": L.lampHead,
            "plant": L.plant,
            "pencup": L.penCup,
            "pencup.mouth": ArtRect(L.penCup.x, L.penCup.y, L.penCup.w, 5),
            "phone": L.phone,
            "phone.screen": ArtRect(L.phone.x + 2, L.phone.y + 1, 12, 21),
            "hub": L.driveHub,

            "desk.top": L.deskTop,
            "mat.default": L.matDefault,
            "mat.edge.n": ArtRect(L.matDefault.x, L.matDefault.y, L.matDefault.w, 3),
            "mat.edge.s": ArtRect(L.matDefault.x, L.matDefault.maxY - 3, L.matDefault.w, 3),
            "mat.edge.w": ArtRect(L.matDefault.x, L.matDefault.y, 4, L.matDefault.h),
            "mat.edge.e": ArtRect(L.matDefault.maxX - 4, L.matDefault.y, 4, L.matDefault.h),
            "keyboard": L.keyboard,
            "brush": L.brush,
            "apron": L.apron,

            "chair": L.chair,
            "cabinet": L.cabinet,
            "wastebasket": L.wastebasket,
            "wastebasket.mouth": L.wastebasketMouth,
            "floor": ArtRect(0, L.floorY, L.size.w, L.size.h - L.floorY),

            // MARK: memos (0.3.0): the desk partition (Erratum 31); the right post is a bare target (menus, demos).
            "partition": L.partition,
            "partition.tower": L.partitionTowerFelt,
            "partition.post": ArtRect(496, 112, 4, 56),
            "partition.cube": L.partitionCube,
            "partition.pad": L.partitionPad,
            "partition.clips": L.partitionClips,
            "partition.dday": L.partitionDDay,
            "partition.clipLight": L.partitionClipLight,
        ]
        for (i, name) in cabinetDrawerNames.enumerated() {
            let front = L.cabinetFront(i)
            a["cabinet.\(name)"] = front
            a["cabinet.\(name).front"] = front
            a["cabinet.\(name).handle"] = cabinetHandle(of: front)
        }
        return Anchors(a)
    }()

    /// Cabinet drawers top → bottom, as anchor names use them.
    public static let cabinetDrawerNames = ["top", "middle", "file"]

    /// Click targets that must not overlap each other (apart from `intendedOverlaps`).
    public static let interactive: [String] = [
        "room.switch", "clock", "monitor.screen", "monitor.input", "monitor.pageDots", "monitor.power",
        "riser.drawerL", "riser.cubby", "riser.drawerR", "lamp.base", "lamp.head", "plant", "pencup", "phone",
        "hub", "mat.default", "keyboard", "brush", "apron", "chair", "cabinet.top", "cabinet.middle",
        "cabinet.file", "wastebasket.mouth",
        // MARK: memos (0.3.0)
        "partition.cube", "partition.pad", "partition.clips", "partition.dday", "partition.clipLight", "calendar",
    ]

    /// Overlaps between interactive anchors that the composition intends (unordered pairs).
    public static let intendedOverlaps: Set<[String]> = [
        ["keyboard", "mat.default"],   // the keyboard weighs the mat down
        ["apron", "chair"],            // the pushed-in chair's backrest covers the apron
    ]

    /// Whether `a` and `b` may overlap.
    public static func overlapIsIntended(_ a: String, _ b: String) -> Bool {
        intendedOverlaps.contains([a, b].sorted())
    }

    /// The handle on a riser drawer front: centred, 3 px tall, two rows below the top edge.
    public static func handle(of front: ArtRect, width: Int) -> ArtRect {
        ArtRect(front.midX - width / 2, front.y + front.h / 2 - 2, width, 4)
    }

    /// The pull bar on a cabinet drawer front.
    public static func cabinetHandle(of front: ArtRect) -> ArtRect {
        ArtRect(front.midX - 12, front.y + 4, 24, 4)
    }
}

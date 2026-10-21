/// Everything that can be put away (Erratum 30). Order is the menus' and the Arrange Desk window's order.
public enum StowID: String, Codable, CaseIterable, Sendable, Comparable {
    case riserDrawers, cabinet, phoneStand, plant, partition, dailyPad, memoClips, clipLight, dDayCard
    case wallShelf, pegboard, stringLights, floorPlant, wallArt

    public static func < (a: StowID, b: StowID) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// One row of `StowCatalog`: what putting an object away takes out of the room.
public struct StowSpec: Sendable, Equatable {
    /// The Arrange Desk window's sections.
    public enum Group: String, Sendable, CaseIterable { case storage, desk, partition, wall }

    public let id: StowID
    public let group: Group
    /// The object's name in English (menus fill it into `%T` templates, so `L10n.tr` translates it).
    public let title: String
    /// The hiding places it holds; an away container holds no token (`DeskState.violations`).
    public let containers: [ContainerID]
    /// `.partition` for the partition's add-ons: they are out only while it is.
    public let parent: StowID?
    /// Its back-strip footprint in `DeskPlanePhysics.footprints(stowed:)` ("plant", "phone").
    public let footprint: String?
    /// Core x span it stands on along the floor line (`FloorLine.furniture(basket:stowed:)`).
    public let floorSpan: Range<Int>?
    /// What a desk knock wobbles.
    public let wobbler: DeskKnock.Wobbler?
    /// Wall decor it hides (`SceneLayout.hiding(_:)`).
    public let decorKinds: Set<WallDecor.Kind>
    /// The anchor its dust puff plays at and VoiceOver points to; nil for decor.
    public let anchor: String?

    init(_ id: StowID, _ group: Group, _ title: String, containers: [ContainerID] = [], parent: StowID? = nil,
         footprint: String? = nil, floorSpan: Range<Int>? = nil, wobbler: DeskKnock.Wobbler? = nil,
         decorKinds: Set<WallDecor.Kind> = [], anchor: String? = nil) {
        self.id = id
        self.group = group
        self.title = title
        self.containers = containers
        self.parent = parent
        self.footprint = footprint
        self.floorSpan = floorSpan
        self.wobbler = wobbler
        self.decorKinds = decorKinds
        self.anchor = anchor
    }
}

/// The one table of what can be put away (Erratum 30). Menus, the reducer, `RoomPlan`, physics and the Arrange
/// Desk window all read it. Not stowable, on purpose: the pen cup, the wastebasket, the mat and keyboard, the lamp,
/// the monitor, desk, clock, room switch, window and calendar, the chair, the brush, the drive hub, and the
/// ceiling, crown, rail, pendant and ceiling lamp.
public enum StowCatalog {
    public static func spec(_ id: StowID) -> StowSpec { table[id]! }

    private static let table: [StowID: StowSpec] = Dictionary(
        uniqueKeysWithValues: StowID.allCases.map { ($0, make($0)) }
    )

    private static func make(_ id: StowID) -> StowSpec {
        switch id {
        case .riserDrawers:
            // The riser itself stays (the monitor stands on it), drawn sealed.
            StowSpec(id, .storage, "Riser Drawers", containers: [.riserLeft, .riserRight, .riserCubby], anchor: "riser")
        case .cabinet:
            StowSpec(id, .storage, "Cabinet", containers: [.cabinetTop, .cabinetMiddle, .cabinetFile],
                     floorSpan: CoreLayout.cabinet.minX..<CoreLayout.cabinet.maxX, anchor: "cabinet")
        case .phoneStand:
            StowSpec(id, .desk, "Phone Stand", containers: [.phone], footprint: "phone", wobbler: .phone,
                     anchor: "phone")
        case .plant:
            StowSpec(id, .desk, "Plant", footprint: "plant", wobbler: .plant, anchor: "plant")
        case .partition:
            StowSpec(id, .partition, "Desk Partition", anchor: "partition")
        case .dailyPad:
            StowSpec(id, .partition, "Daily Memo Pad", parent: .partition, anchor: "partition.pad")
        case .memoClips:
            StowSpec(id, .partition, "Memo Clips", containers: [.memoClips], parent: .partition,
                     anchor: "partition.clips")
        case .clipLight:
            StowSpec(id, .partition, "Clip Light", parent: .partition, anchor: "partition.clipLight")
        case .dDayCard:
            StowSpec(id, .partition, "D-Day Card", parent: .partition, anchor: "partition.dday")
        case .wallShelf:
            StowSpec(id, .wall, "Wall Shelf", decorKinds: [.shelf, .frame])
        case .pegboard:
            StowSpec(id, .wall, "Pegboard", decorKinds: [.pegboard])
        case .stringLights:
            StowSpec(id, .wall, "String Lights", decorKinds: [.stringLights])
        case .floorPlant:
            StowSpec(id, .wall, "Floor Plant", decorKinds: [.floorPlant])
        case .wallArt:
            StowSpec(id, .wall, "Wall Art", decorKinds: [.painting, .upperShelf, .gallery, .wallHanging, .hangingPlant])
        }
    }

    /// The object whose hiding place `c` is; nil for the pen cup and the wastebasket.
    public static func owner(of c: ContainerID) -> StowID? {
        StowID.allCases.first { spec($0).containers.contains(c) }
    }

    /// The wall decor hidden while `stowed` is put away.
    public static func decorKinds(hiddenBy stowed: Set<StowID>) -> Set<WallDecor.Kind> {
        stowed.reduce(into: []) { $0.formUnion(spec($1).decorKinds) }
    }

    /// Object menus that append "Put Away" centrally: "riser" → `.riserDrawers`, "cabinet", "phone" →
    /// `.phoneStand`, "plant", and "frame" → `.wallShelf` (Erratum 33).
    public static func stowID(forElement element: String) -> StowID? {
        switch element {
        case "riser": .riserDrawers
        case "cabinet": .cabinet
        case "phone": .phoneStand
        case "plant": .plant
        case "frame": .wallShelf // MARK: picture frame (0.4.0): the framed print is in the Wall Shelf group (Erratum 30)
        default: nil
        }
    }

    /// The add-ons that come and go with `id` (the partition's four).
    public static func children(of id: StowID) -> [StowID] {
        StowID.allCases.filter { spec($0).parent == id }
    }

    /// `id` and every object it needs out (an add-on's partition), innermost first.
    static func lineage(of id: StowID) -> [StowID] {
        var out = [id]
        while let p = spec(out.last!).parent { out.append(p) }
        return out
    }

    /// Whether `id` is in the room while `stowed` is put away: neither it nor what it hangs on is.
    public static func isOut(_ id: StowID, stowed: Set<StowID>) -> Bool {
        lineage(of: id).allSatisfy { !stowed.contains($0) }
    }

    /// Whether the hiding place `c` belongs to an object that is put away while `stowed` is.
    public static func isAway(_ c: ContainerID, stowed: Set<StowID>) -> Bool {
        owner(of: c).map { !isOut($0, stowed: stowed) } ?? false
    }

    /// `stowed` without every object (and its partition) whose hiding places are among `occupied`: no file ever
    /// stays inside a put-away place, so a layout that has one there brings its place back (`adoptLayout`, sanitize).
    /// Nothing else changes, so nothing becomes visible: drawers stay shut, the phone keeps its face.
    public static func bringingBack(_ occupied: Set<ContainerID>, from stowed: Set<StowID>) -> Set<StowID> {
        var out = stowed
        for c in occupied where isAway(c, stowed: out) {
            if let owner = owner(of: c) { out.subtract(lineage(of: owner)) }
        }
        return out
    }

    /// Piles, floor tokens and notes resting where `id` stands (demo `clear:` and make-room): piles whose body meets
    /// its footprint (and the pen cup standing there), floor tokens on its floor span, and notes that would not rest
    /// validly with it out.
    public static func blockers(of id: StowID, in s: DeskState) -> Int {
        let row = spec(id)
        var n = 0
        if let name = row.footprint, let f = DeskPlanePhysics.footprints(stowed: [])[name] {
            n += s.piles.values.filter {
                DeskPlaneRect.centred(at: $0, size: DeskPlanePhysics.pileSize).intersects(f)
            }.count
            if PenCupMachine(s.penCup, stowed: s.stowed).footprint.intersects(f) { n += 1 }
        }
        if let span = row.floorSpan {
            let half = FloorLine.tokenWidth / 2
            n += s.tokens.keys {
                if case let .floor(x) = $0 { span.overlaps((x - half)..<(x + half)) } else { false }
            }.count
        }
        if row.footprint != nil || lineage(of: id).contains(.partition) {
            var back = s
            back.stowed.subtract(lineage(of: id))
            n += s.memos.notes.values.filter { !PartitionLayout.isValidRest($0.pos, in: back) }.count
        }
        return n
    }
}

extension DeskState {
    /// The object is in the room: not put away, and neither is what it hangs on (an add-on's partition).
    public func isOut(_ id: StowID) -> Bool {
        StowCatalog.isOut(id, stowed: stowed)
    }

    /// The container belongs to an object that is put away.
    public func isAway(_ c: ContainerID) -> Bool {
        StowCatalog.isAway(c, stowed: stowed)
    }

    /// The tokens in the object's containers and its add-ons', in container order.
    public func tokensInside(_ id: StowID) -> [TokenKey] {
        let ids = [id] + StowCatalog.children(of: id)
        return ids.flatMap { StowCatalog.spec($0).containers }.sorted().flatMap { tokens.members(of: $0) }
    }

    /// Brings back every put-away object whose hiding places hold tokens (`StowCatalog.bringingBack`).
    public mutating func bringBackOccupied() {
        let occupied = Set(ContainerID.allCases.filter { tokens.count(in: $0) > 0 })
        stowed = StowCatalog.bringingBack(occupied, from: stowed)
    }
}

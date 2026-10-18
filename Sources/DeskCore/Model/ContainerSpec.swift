/// How a container hides what is inside it.
public enum Concealment: String, Sendable, Codable {
    /// Contents are invisible until it is opened (drawers, face-down phone).
    case hidden
    /// Dim silhouettes, names on hover (cubby).
    case partial
    /// Shown only as anonymous shapes (pen caps, crumpled balls).
    case anonymized
    /// Not a hiding place: files in it stay in sight (the memo clips' cards, Erratum 31).
    case shown
}

/// Capacity rules for one container (DESIGN §2.2). Past `capacity` a container shows that it is full (a
/// drawer rests ajar); at `hardCap` further drops bonk.
public struct ContainerSpec: Sendable, Equatable {
    public let capacity: Int
    public let hardCap: Int
    public let concealment: Concealment
    /// Drawer travel in art px (fully open), nil for containers without a rail.
    public let travel: Float?

    public init(capacity: Int, hardCap: Int, concealment: Concealment, travel: Float? = nil) {
        precondition(capacity > 0 && hardCap >= capacity, "invalid container spec")
        self.capacity = capacity
        self.hardCap = hardCap
        self.concealment = concealment
        self.travel = travel
    }

    /// Riser drawers: capacity 8, jammed at 14, travel 10 (E3).
    public static let riserDrawer = ContainerSpec(capacity: 8, hardCap: 14, concealment: .hidden, travel: 10)
    /// Riser cubby: an open slot of 12 (E3).
    public static let cubby = ContainerSpec(capacity: 12, hardCap: 12, concealment: .partial)
    /// Cabinet drawers: capacity 8/12/20, hard cap = capacity + 6, travel 12/14/18 (E5).
    public static let cabinetTop = ContainerSpec(capacity: 8, hardCap: 14, concealment: .hidden, travel: 12)
    public static let cabinetMiddle = ContainerSpec(capacity: 12, hardCap: 18, concealment: .hidden, travel: 14)
    public static let cabinetFile = ContainerSpec(capacity: 20, hardCap: 26, concealment: .hidden, travel: 18)
    /// Pen cup: 6 pens; a 7th bonks (E7).
    public static let penCup = ContainerSpec(capacity: 6, hardCap: 6, concealment: .anonymized)
    /// Phone: 3×2 mini icons (E4).
    public static let phone = ContainerSpec(capacity: 6, hardCap: 6, concealment: .hidden)
    /// Wastebasket: heaps above the rim at 11, bonks at 24 (E8).
    public static let wastebasket = ContainerSpec(capacity: 24, hardCap: 24, concealment: .anonymized)
    /// Memo clips: five cards on the partition (Erratum 31).
    public static let memoClips = ContainerSpec(capacity: 5, hardCap: 5, concealment: .shown)

    public static func of(_ id: ContainerID) -> ContainerSpec {
        switch id {
        case .riserLeft, .riserRight: riserDrawer
        case .riserCubby: cubby
        case .cabinetTop: cabinetTop
        case .cabinetMiddle: cabinetMiddle
        case .cabinetFile: cabinetFile
        case .penCup: penCup
        case .phone: phone
        case .wastebasket: wastebasket
        case .memoClips: memoClips
        }
    }

    /// The resting drawer gap for `count` items: an overfull drawer rests ajar, `min(6, max(0, n − capacity))`.
    public func closedLimit(count: Int) -> Float {
        Float(min(6, max(0, count - capacity)))
    }

    /// True when `count` items jam the drawer (or fill a holder): further drops bonk.
    public func isAtHardCap(_ count: Int) -> Bool { count >= hardCap }
}

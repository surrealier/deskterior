/// The wastebasket (DESIGN §2.2 E8): hides, never deletes.
/// `upright → tipping → tipped(dir) → righting → upright`.
///
/// Balls fill the 24 heap slots (`PropArt.heapSlots`, above the rim from slot 11); a 25th bonks. Nothing ever
/// leaves on its own: only a sideways rim drag faster than `tipSpeed` (or the menu) tips it, and only reaching
/// `tipped` emits `spill` with deterministic floor spots for the balls. A click stands it back up. Swishes are
/// counted. Resting states commit through `settled` (dispatch `.basketState`).
public struct WastebasketMachine: Sendable, Equatable {
    public struct Params: Hashable, Sendable {
        /// A rim drag faster than this (px/s, sideways) tips the basket.
        public var tipSpeed: Float = 300
        /// Seconds per tipping / righting frame (three frames).
        public var frameDuration: Float = 1.0 / 12
        /// A gentle drop this close to the mouth goes in.
        public var gentleDropRadius = 12
        /// Floor token pitch and width for spilled balls (core px).
        public var spillPitch = 18
        public var tokenWidth = 16
        public var jiggleDuration: Float = 0.25

        public init() {}

        public static let standard = Params()
    }

    public enum Phase: Hashable, Sendable {
        case upright
        case tipping(elapsed: Float, right: Bool)
        case tipped(right: Bool)
        case righting(elapsed: Float, right: Bool)
    }

    public enum Event: Equatable, Sendable {
        case bonk
        case swish
        case rim
        /// Started tipping toward the right (`true`) or left.
        case tipped(right: Bool)
        /// Lying on its side: the balls uncrumple onto the floor now (`spillSpots`).
        case spill(right: Bool)
        case righted
        /// A resting state to commit (dispatch `.basketState`).
        case settled(BasketState)
    }

    public var params: Params
    public private(set) var phase: Phase
    public private(set) var swishes: Int
    /// Seconds left of a knock's heap jiggle.
    public private(set) var jiggle: Float = 0

    public static let uprightName = "upright", tippedLeftName = "tippedLeft", tippedRightName = "tippedRight"
    /// From this many balls the heap rises above the rim.
    public static let aboveRimCount = 11

    public init(_ state: BasketState = BasketState(), params: Params = .standard) {
        self.params = params
        self.swishes = max(0, state.swishes)
        switch state.state {
        case Self.tippedLeftName: phase = .tipped(right: false)
        case Self.tippedRightName: phase = .tipped(right: true)
        default: phase = .upright
        }
    }

    public var state: BasketState {
        let name: String
        switch phase {
        case .upright, .righting: name = Self.uprightName
        case let .tipping(_, right), let .tipped(right): name = right ? Self.tippedRightName : Self.tippedLeftName
        }
        return BasketState(state: name, swishes: swishes)
    }

    public var isUpright: Bool { phase == .upright }
    public var isTipped: Bool { if case .tipped = phase { true } else { false } }

    /// Tipping / righting frame 0…2 (nil at rest) and its direction.
    public var tipFrame: (frame: Int, right: Bool)? {
        switch phase {
        case let .tipping(t, right): (min(2, Int(t / params.frameDuration)), right)
        case let .righting(t, right): (2 - min(2, Int(t / params.frameDuration)), right)
        default: nil
        }
    }

    /// Heap rows shift by this (0 or −1 px) while a knock jiggles them.
    public var jiggleOffset: Int { jiggle > 0 && Int(jiggle / (1.0 / 30)) % 2 == 0 ? -1 : 0 }

    public var needsFrames: Bool {
        switch phase {
        case .tipping, .righting: true
        default: jiggle > 0
        }
    }

    /// A ball can go in: upright and below the hard cap (24).
    public func canAccept(count: Int) -> Bool { isUpright && count < ContainerSpec.wastebasket.hardCap }

    /// The top ball can be dug out.
    public func canDig(count: Int) -> Bool { isUpright && count > 0 }

    /// A release at core point `point` counts as a gentle drop into the mouth.
    public func isGentleDrop(at point: ArtPoint) -> Bool {
        let m = CoreLayout.wastebasketMouth.insetBy(-params.gentleDropRadius, -params.gentleDropRadius)
        return m.contains(point)
    }

    /// Basket-local top-left of the ball at heap position `order` (0 = bottom), as `PropArt.heapSlots` lays them.
    public static func heapSlot(_ order: Int) -> ArtPoint? {
        PropArt.heapSlots.indices.contains(order) ? PropArt.heapSlots[order] : nil
    }

    public static func isHeapedAboveRim(_ count: Int) -> Bool { count >= aboveRimCount }

    // MARK: Inputs

    /// A drop on the mouth: in when it can accept, else a bonk.
    public func drop(count: Int) -> [Event] {
        canAccept(count: count) ? [] : [.bonk]
    }

    /// A toss finished: counts a swish. A ball that would overfill bonks out instead (the caller lands it on the
    /// floor beside the basket).
    public mutating func recordToss(_ toss: Ballistics.Toss, count: Int) -> [Event] {
        guard toss.isIn else { return toss.rimHits > 0 ? [.rim] : [] }
        guard canAccept(count: count) else { return [.bonk] }
        switch toss.kind {
        case .swish:
            swishes += 1
            return [.swish, .settled(state)]
        default:
            return [.rim]
        }
    }

    /// The rim dragged sideways at `velocityX` px/s: fast enough tips it that way.
    public mutating func rimDrag(velocityX: Float) -> [Event] {
        guard isUpright, velocityX.isFinite, abs(velocityX) > params.tipSpeed else { return [] }
        return startTip(right: velocityX > 0)
    }

    /// The menu: tip it over.
    public mutating func tipOut(right: Bool = true) -> [Event] {
        guard isUpright else { return [] }
        return startTip(right: right)
    }

    /// Click on the tipped basket: it stands back up (empty: its balls are on the floor).
    public mutating func standUp() -> [Event] {
        guard case let .tipped(right) = phase else { return [] }
        phase = .righting(elapsed: 0, right: right)
        return []
    }

    /// A desk knock jiggles the heap. It never tips the basket or moves a ball out.
    public mutating func knock() -> [Event] {
        if isUpright { jiggle = params.jiggleDuration }
        return []
    }

    public mutating func sync(_ state: BasketState) {
        guard state != self.state else { return }
        self = WastebasketMachine(state, params: params)
    }

    mutating func startTip(right: Bool) -> [Event] {
        phase = .tipping(elapsed: 0, right: right)
        jiggle = 0
        return [.tipped(right: right)]
    }

    public mutating func step(_ dt: Float) -> [Event] {
        guard dt > 0 else { return [] }
        jiggle = max(0, jiggle - dt)
        let total = 3 * params.frameDuration
        switch phase {
        case .upright, .tipped:
            return []
        case let .tipping(t, right):
            let n = t + dt
            guard n >= total else {
                phase = .tipping(elapsed: n, right: right)
                return []
            }
            phase = .tipped(right: right)
            return [.spill(right: right), .settled(state)]
        case let .righting(t, right):
            let n = t + dt
            guard n >= total else {
                phase = .righting(elapsed: n, right: right)
                return []
            }
            phase = .upright
            return [.righted, .settled(state)]
        }
    }

    // MARK: Spill

    /// Floor x (core px, token left edge) for each of `count` balls tipped out toward the right (`right`) or left:
    /// a row away from the basket at `spillPitch`, squeezed to fit the floor, top ball nearest the mouth. Spots
    /// that do not fit on the tip side continue on the other side of the basket.
    public static func spillSpots(count: Int, right: Bool, params: Params = .standard) -> [Int] {
        guard count > 0 else { return [] }
        let basket = CoreLayout.wastebasket
        let floorMax = CoreLayout.size.w - params.tokenWidth
        let rightStart = basket.maxX + 2, leftStart = basket.minX - 2 - params.tokenWidth
        func row(_ start: Int, _ step: Int, _ n: Int, limit: Int) -> [Int] {
            guard n > 0 else { return [] }
            let room = abs(limit - start)
            let pitch = n > 1 ? max(1, min(params.spillPitch, room / (n - 1))) : 0
            return (0..<n).map { start + step * $0 * pitch }
        }
        let ownSide = right ? (floorMax - rightStart) : leftStart
        let fit = max(1, ownSide / params.spillPitch + 1)
        let first = min(count, fit), rest = count - first
        let main = right
            ? row(rightStart, 1, first, limit: floorMax)
            : row(leftStart, -1, first, limit: 0)
        let other = right
            ? row(leftStart, -1, rest, limit: 0)
            : row(rightStart, 1, rest, limit: floorMax)
        // Nearest first; the top ball (last in) lands nearest the mouth.
        return (main + other).map { min(max($0, 0), floorMax) }.reversed()
    }
}

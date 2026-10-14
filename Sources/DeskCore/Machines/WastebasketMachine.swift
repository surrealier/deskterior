/// The wastebasket (DESIGN §2.2 E8): hides, never deletes.
/// `upright → tipping → tipped(dir) → righting → upright`.
///
/// Balls fill the 24 heap slots (`InteriorRaster.basketSlots`, above the rim from the 11th ball); a 25th bonks.
/// Nothing ever leaves on its own: only a sustained sideways rim drag (or the menu) tips it, and only reaching
/// `tipped` emits `spill` with deterministic floor spots for the balls. A click stands it back up. Swishes are
/// counted. Resting states commit through `settled` (dispatch `.basketState`).
public struct WastebasketMachine: Sendable, Equatable {
    public struct Params: Hashable, Sendable {
        /// A rim drag tips the basket once it has gone sideways one way for `tipSamples` pointer samples in a
        /// row, each faster than `tipSpeed` (px/s) and `tipAspect` times more across than up or down, and more than
        /// `tipDistance` px across: a quick dig out of the mouth never tips it.
        public var tipSpeed: Float = 300
        public var tipSamples = 3
        public var tipAspect: Float = 3
        public var tipDistance: Float = 6
        /// Seconds per tipping / righting frame (three frames).
        public var frameDuration: Float = 1.0 / 12
        /// A gentle drop this close to the mouth goes in.
        public var gentleDropRadius = 12
        /// Floor token pitch for spilled balls (core px); squeezed down to `minSpillPitch` when the floor is short.
        public var spillPitch = 18
        public var minSpillPitch = 4
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

    /// A rim drag in progress: qualifying samples in a row, their direction and how far they went across.
    struct RimDrag: Hashable, Sendable {
        var samples = 0
        var right = false
        var distance: Float = 0
    }

    public var params: Params
    public private(set) var phase: Phase
    public private(set) var swishes: Int
    /// Seconds left of a knock's heap jiggle.
    public private(set) var jiggle: Float = 0
    var rim = RimDrag()

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

    /// Basket-local top-left of the ball at heap position `order` (0 = bottom), as `InteriorRaster.basketSlots`
    /// lays them.
    public static func heapSlot(_ order: Int) -> ArtPoint? {
        InteriorRaster.basketSlots.indices.contains(order) ? InteriorRaster.basketSlots[order] : nil
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

    /// One pointer sample of a drag that started on the rim: `delta` core px since the last sample, over `dt`
    /// seconds. Tips the basket that way once the drag has been sideways long enough (`Params.tipSpeed`).
    public mutating func rimDrag(delta: SIMD2<Float>, dt: Float) -> [Event] {
        guard isUpright, delta.isFinite, dt.isFinite, dt > 0 else { return [] }
        let v = delta / dt
        let right = delta.x > 0
        guard abs(v.x) > params.tipSpeed, abs(v.x) > params.tipAspect * abs(v.y) else {
            rim = RimDrag()
            return []
        }
        if rim.samples > 0, rim.right != right { rim = RimDrag() }
        rim.samples += 1
        rim.right = right
        rim.distance += abs(delta.x)
        guard rim.samples >= params.tipSamples, rim.distance > params.tipDistance else { return [] }
        return startTip(right: right)
    }

    /// The rim drag ended (or turned into a dig) without tipping.
    public mutating func endRimDrag() {
        rim = RimDrag()
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
        rim = RimDrag()
        jiggle = 0
        return [.tipped(right: right)]
    }

    public mutating func step(_ dt: Float) -> [Event] {
        guard let dt = SimClock.step(dt) else { return [] }
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

    /// Where the basket lies when tipped toward the right (`right`) or left: on its side next to its upright
    /// spot, turned about its foot's corner, its mouth facing that way (core px; `InteriorRaster.wastebasketTipped`).
    public static func tippedRect(right: Bool) -> ArtRect {
        let r = CoreLayout.wastebasket
        return ArtRect(right ? r.maxX : r.minX - r.h, r.maxY - r.w, r.h, r.w)
    }

    /// Floor centres (`FloorLine`) for each of `count` balls tipped out toward the right (`right`) or left: a row
    /// out from the lying basket's mouth at `spillPitch`, stepping over the cabinet, the basket's upright spot (it
    /// stands back up there) and the spans in `avoiding` (floor tokens already there), squeezed closer when the
    /// floor is short; balls that do not fit on that side continue from the basket's other end. The top ball
    /// (last in) lands nearest the mouth.
    public static func spillSpots(
        count: Int, right: Bool, avoiding extra: [Range<Int>] = [], params: Params = .standard
    ) -> [Int] {
        guard count > 0 else { return [] }
        let lying = tippedRect(right: right), half = FloorLine.tokenWidth / 2
        let avoid = FloorLine.furniture(basket: BasketState(state: right ? tippedRightName : tippedLeftName)) + extra
        let both = lying.union(CoreLayout.wastebasket)
        let rightStart = both.maxX + 2 + half, leftStart = both.minX - 2 - half
        let dir = right ? 1 : -1
        var spots: [Int] = []
        for pitch in stride(from: params.spillPitch, through: params.minSpillPitch, by: -1) {
            let own = FloorLine.row(from: right ? rightStart : leftStart, direction: dir, pitch: pitch, count: count,
                                    avoiding: avoid)
            let other = FloorLine.row(from: right ? leftStart : rightStart, direction: -dir, pitch: pitch,
                                      count: count - own.count, avoiding: avoid)
            spots = own + other
            if spots.count == count { break }
        }
        // A floor too short even at the closest pitch: the rest stack on the last spot.
        while spots.count < count { spots.append(spots.last ?? FloorLine.freeSpot(near: Float(rightStart))) }
        return spots.reversed()
    }
}

/// Collision categories of the desk-plane Box2D world (DESIGN §12). Contacts are never tested
/// (`contactTestBitMask = 0`); zones use geometric tests.
public struct PhysicsCategory: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Static: the back wall's edge chain and the back-strip footprints (riser, lamp base, plant, phone stand,
    /// hub, the pen cup while resting).
    public static let furniture = PhysicsCategory(rawValue: 1 << 0)
    /// Uncovered desk piles.
    public static let pile = PhysicsCategory(rawValue: 1 << 1)
    /// Velocity-driven props: the brush, the pen cup while carried.
    public static let prop = PhysicsCategory(rawValue: 1 << 2)
    /// Bits 3…7 are reserved for v0.2 (laptop stand, mug, figure).
    public static let reserved = PhysicsCategory(rawValue: 0xF8)

    /// What bodies of this category collide with (furniture is static: nothing).
    public var collisionMask: PhysicsCategory {
        var m: PhysicsCategory = []
        if contains(.pile) { m.formUnion([.furniture, .pile, .prop]) }
        if contains(.prop) { m.formUnion([.furniture, .pile]) }
        return m
    }

    public static let contactTestMask: UInt32 = 0
}

/// Units, body shapes and constants of the desk-plane world (DESIGN §4.7, §12), so the scene's bodies, the
/// freezer and the watchdog agree. Desk-plane coordinates are `(x, d)` art px.
public enum DeskPlanePhysics {
    /// SpriteKit units per art px.
    public static let unitsPerArtPixel: Float = 4
    /// SpriteKit points per metre.
    public static let pointsPerMeter: Float = 150
    /// The desk plane is seen from above: no gravity.
    public static let gravity = SIMD2<Float>(0, 0)

    /// A pile's body: 14×10 plane px, inset 1 px.
    public static let pileSize = SIMD2<Float>(14, 10)
    public static let pileInset: Float = 1
    public static let pileFriction: Float = 0.3
    public static let pileRestitution: Float = 0.2
    public static let pileLinearDamping: Float = 4
    public static let pileMaxSpeed: Float = 1200
    /// The brush: 24×6 plane px, about 20× a pile's mass.
    public static let brushSize = SIMD2<Float>(24, 6)
    public static let brushMassRatio: Float = 20
    public static let propMaxSpeed: Float = 600
    /// Velocity drive for props: `v = clamp((target − pos)/dt × gain, propMaxSpeed)`.
    public static let propDriveGain: Float = 0.5

    /// Desk-plane bounds of the desk top.
    public static let desk = DeskPlaneRect(
        x: Float(CoreLayout.deskTop.minX), d: 0, width: Float(CoreLayout.deskTop.w), depth: 128
    )
    /// Depth at which back-strip footprints start.
    public static let backStripD: Float = 112

    /// Static back-strip footprints (furniture), by name, with everything out. Read through `footprints(stowed:)`.
    private static let allFootprints: [String: DeskPlaneRect] = {
        func strip(_ r: ArtRect) -> DeskPlaneRect {
            DeskPlaneRect(x: Float(r.minX), d: backStripD, width: Float(r.w), depth: desk.depth - backStripD)
        }
        return [
            "riser": strip(CoreLayout.riser), "lamp": strip(CoreLayout.lampBase), "plant": strip(CoreLayout.plant),
            "phone": strip(CoreLayout.phone), "hub": strip(CoreLayout.driveHub),
        ]
    }()

    /// The back-strip footprints (furniture) by name, without those of put-away objects (an away plant or phone
    /// stand, Erratum 30).
    public static func footprints(stowed: Set<StowID>) -> [String: DeskPlaneRect] {
        let away = Set(stowed.compactMap { StowCatalog.spec($0).footprint })
        return away.isEmpty ? allFootprints : allFootprints.filter { !away.contains($0.key) }
    }

    /// The pen cup's footprint around its desk position (`PenCupState.pos`).
    public static func penCupFootprint(at pos: SIMD2<Float>) -> DeskPlaneRect {
        let w = Float(CoreLayout.penCup.w)
        return DeskPlaneRect(x: pos.x - w / 2, d: pos.y, width: w, depth: 8)
    }

    /// The prop velocity drive toward `target`, clamped to `propMaxSpeed`.
    public static func propDrive(from position: SIMD2<Float>, to target: SIMD2<Float>, dt: Float) -> SIMD2<Float> {
        guard dt > 0, position.isFinite, target.isFinite else { return .zero }
        let v = (target - position) / dt * propDriveGain
        let speed = (v * v).sum().squareRoot()
        return speed > propMaxSpeed ? v * (propMaxSpeed / speed) : v
    }

    /// Clamps a pile velocity to `pileMaxSpeed`.
    public static func clampPileVelocity(_ v: SIMD2<Float>) -> SIMD2<Float> {
        guard v.isFinite else { return .zero }
        let speed = (v * v).sum().squareRoot()
        return speed > pileMaxSpeed ? v * (pileMaxSpeed / speed) : v
    }
}

extension DeskPlaneRect {
    /// Overlap test with another plane rect (touching edges do not overlap).
    public func intersects(_ o: DeskPlaneRect) -> Bool {
        x < o.x + o.width && o.x < x + width && d < o.d + o.depth && o.d < d + depth
    }

    /// The rect of a body of `size` centred at `centre`.
    public static func centred(at centre: SIMD2<Float>, size: SIMD2<Float>) -> DeskPlaneRect {
        DeskPlaneRect(x: centre.x - size.x / 2, d: centre.y - size.y / 2, width: size.x, depth: size.y)
    }
}

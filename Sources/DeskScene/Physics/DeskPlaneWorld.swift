import CoreGraphics
import DeskCore
import SpriteKit

/// The one Box2D world (DESIGN §4.7, §12): the desk top seen from above, run by SpriteKit's `SKPhysicsWorld` as the
/// scene updates (`SKRenderer.update(atTime:)`). Its bodies hang off `root`, an invisible node that is never moved,
/// so a body's scene position is its desk-plane point `(x, d)` × `DeskPlanePhysics.unitsPerArtPixel`.
///
/// - furniture (static): the back wall's edge, the back-strip footprints (riser, lamp base, plant, phone stand, hub),
///   the keyboard, and the pen cup while it stands;
/// - piles (dynamic, 14×10 plane px less a 1-px inset, no rotation, damping 4, friction 0.3, restitution 0.2, CCD),
///   frozen to static by the `PileFreezer`;
/// - one prop (the pen cup while carried): velocity-driven, 20× a pile's mass.
///
/// Nothing tests contacts (`contactTestBitMask = 0`); zones are geometric. Bodies are never teleported: a move to
/// somewhere else destroys the body and makes a new one.
final class DeskPlaneWorld {
    static let u = CGFloat(DeskPlanePhysics.unitsPerArtPixel)

    let root = SKNode()
    private(set) var piles: [PileID: SKNode] = [:]
    private var furniture: [String: SKNode] = [:]
    private var furnitureRects: [String: DeskPlaneRect] = [:]
    private var prop: SKNode?
    private weak var scene: SKScene?

    init() {
        root.name = "physicsRoot"
        let desk = DeskPlanePhysics.desk
        // The back wall: an edge along the desk's back, a little past its ends.
        let wall = SKNode()
        let a = Self.scenePoint([desk.x - 24, desk.d + desk.depth]), b = Self.scenePoint([desk.x + desk.width + 24, desk.d + desk.depth])
        let edge = SKPhysicsBody(edgeFrom: a, to: b)
        Self.configureFurniture(edge)
        wall.physicsBody = edge
        root.addChild(wall)
        furniture["wall"] = wall
        for (name, rect) in DeskPlanePhysics.footprints(stowed: []).sorted(by: { $0.key < $1.key }) {
            setFurniture(name, rect)
        }
        setFurniture("keyboard", Self.keyboardFootprint(nil))
    }

    /// Stops the scene's gravity (the desk plane is seen from above) once `scene` holds the world.
    func attach(to scene: SKScene?) {
        guard let scene, scene !== self.scene else { return }
        self.scene = scene
        scene.physicsWorld.gravity = .zero
        scene.physicsWorld.speed = 1
    }

    // MARK: Units

    static func scenePoint(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * u, y: CGFloat(p.y) * u)
    }

    static func planePoint(_ c: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(c.x / u), Float(c.y / u))
    }

    static func sceneVector(_ v: SIMD2<Float>) -> CGVector {
        CGVector(dx: CGFloat(v.x) * u, dy: CGFloat(v.y) * u)
    }

    static func planeVector(_ v: CGVector) -> SIMD2<Float> {
        SIMD2(Float(v.dx / u), Float(v.dy / u))
    }

    /// The keyboard's footprint on the plane (it rides on the mat: `MatState.keyboard` when the cloth moved it).
    static func keyboardFootprint(_ centre: SIMD2<Float>?) -> DeskPlaneRect {
        let w = Float(CoreLayout.keyboard.w)
        let c = centre ?? SIMD2(Float(CoreLayout.keyboard.midX), 52)
        return DeskPlaneRect(x: c.x - w / 2, d: c.y - 12, width: w, depth: 24)
    }

    // MARK: Furniture

    /// Places (or with nil removes) the static footprint `name`.
    func setFurniture(_ name: String, _ rect: DeskPlaneRect?) {
        if furnitureRects[name] == rect, rect == nil || furniture[name] != nil { return }
        furniture[name]?.removeFromParent()
        furniture[name] = nil
        furnitureRects[name] = rect
        guard let rect else { return }
        let node = SKNode()
        node.position = Self.scenePoint([rect.x + rect.width / 2, rect.d + rect.depth / 2])
        let body = SKPhysicsBody(rectangleOf: CGSize(width: CGFloat(rect.width) * Self.u, height: CGFloat(rect.depth) * Self.u))
        Self.configureFurniture(body)
        node.physicsBody = body
        root.addChild(node)
        furniture[name] = node
    }

    /// Footprints the piles keep clear of (for valid-spot searches), except the back wall.
    var obstacles: [DeskPlaneRect] {
        furnitureRects.filter { DeskPlanePhysics.footprints(stowed: [])[$0.key] == nil }.map(\.value)
    }

    static func configureFurniture(_ body: SKPhysicsBody) {
        body.isDynamic = false
        body.categoryBitMask = PhysicsCategory.furniture.rawValue
        body.collisionBitMask = PhysicsCategory.furniture.collisionMask.rawValue
        body.contactTestBitMask = PhysicsCategory.contactTestMask
        body.friction = CGFloat(DeskPlanePhysics.pileFriction)
        body.restitution = CGFloat(DeskPlanePhysics.pileRestitution)
    }

    // MARK: Piles

    /// The pile body's size: the 14×10 footprint less its inset (Box2D's skin closes most of the gap).
    static var pileBodySize: CGSize {
        let s = DeskPlanePhysics.pileSize - DeskPlanePhysics.pileInset
        return CGSize(width: CGFloat(s.x) * u, height: CGFloat(s.y) * u)
    }

    /// Makes `id`'s body at plane point `p`, moving at `velocity` (plane px/s).
    func addPile(_ id: PileID, at p: SIMD2<Float>, velocity: SIMD2<Float> = .zero, dynamic: Bool = true) {
        removePile(id)
        let node = SKNode()
        node.name = id.raw
        node.position = Self.scenePoint(p)
        let body = SKPhysicsBody(rectangleOf: Self.pileBodySize)
        body.allowsRotation = false
        body.affectedByGravity = false
        body.friction = CGFloat(DeskPlanePhysics.pileFriction)
        body.restitution = CGFloat(DeskPlanePhysics.pileRestitution)
        body.linearDamping = CGFloat(DeskPlanePhysics.pileLinearDamping)
        body.angularDamping = 1
        body.usesPreciseCollisionDetection = true
        body.categoryBitMask = PhysicsCategory.pile.rawValue
        body.collisionBitMask = PhysicsCategory.pile.collisionMask.rawValue
        body.contactTestBitMask = PhysicsCategory.contactTestMask
        body.isDynamic = dynamic
        node.physicsBody = body
        root.addChild(node)
        if dynamic { body.velocity = Self.sceneVector(DeskPlanePhysics.clampPileVelocity(velocity)) }
        piles[id] = node
    }

    func removePile(_ id: PileID) {
        piles[id]?.removeFromParent()
        piles[id] = nil
    }

    func position(of id: PileID) -> SIMD2<Float>? {
        piles[id].map { Self.planePoint($0.position) }
    }

    /// Plane velocity (zero for a frozen body).
    func velocity(of id: PileID) -> SIMD2<Float> {
        guard let b = piles[id]?.physicsBody, b.isDynamic else { return .zero }
        return Self.planeVector(b.velocity)
    }

    func setVelocity(_ id: PileID, _ v: SIMD2<Float>) {
        guard let b = piles[id]?.physicsBody, b.isDynamic else { return }
        b.velocity = Self.sceneVector(v)
    }

    func isDynamic(_ id: PileID) -> Bool { piles[id]?.physicsBody?.isDynamic ?? false }

    /// Freezes (static) or thaws (dynamic) a pile's body.
    func setDynamic(_ id: PileID, _ on: Bool) {
        guard let b = piles[id]?.physicsBody, b.isDynamic != on else { return }
        b.isDynamic = on
        if !on { b.velocity = .zero }
    }

    // MARK: Prop

    /// The pen cup lifts off its footprint and becomes the velocity-driven prop at `p` (its footprint centre).
    func beginProp(at p: SIMD2<Float>, size: SIMD2<Float>) {
        endProp()
        let node = SKNode()
        node.position = Self.scenePoint(p)
        let body = SKPhysicsBody(rectangleOf: CGSize(width: CGFloat(size.x) * Self.u, height: CGFloat(size.y) * Self.u))
        let pileMass = SKPhysicsBody(rectangleOf: Self.pileBodySize).mass
        body.allowsRotation = false
        body.affectedByGravity = false
        body.linearDamping = 0
        body.friction = 0
        body.restitution = 0
        body.usesPreciseCollisionDetection = true
        body.categoryBitMask = PhysicsCategory.prop.rawValue
        body.collisionBitMask = PhysicsCategory.prop.collisionMask.rawValue
        body.contactTestBitMask = PhysicsCategory.contactTestMask
        node.physicsBody = body
        body.mass = pileMass * CGFloat(DeskPlanePhysics.brushMassRatio)
        root.addChild(node)
        prop = node
    }

    var propPosition: SIMD2<Float>? { prop.map { Self.planePoint($0.position) } }

    /// Drives the prop toward `target` this step (`DeskPlanePhysics.propDrive`).
    func driveProp(toward target: SIMD2<Float>, dt: Float) {
        guard let node = prop, let body = node.physicsBody else { return }
        body.velocity = Self.sceneVector(DeskPlanePhysics.propDrive(from: Self.planePoint(node.position), to: target, dt: dt))
    }

    func endProp() {
        prop?.removeFromParent()
        prop = nil
    }

    var hasProp: Bool { prop != nil }
}

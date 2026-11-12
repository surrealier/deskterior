import DeskCore
import Foundation

// SpriteKit's physics for Deskterior's one world (docs/WINDOWS.md, WP3; DESIGN §4.7, §12): the desk top seen from
// above, gravity off, every dynamic body an axis-aligned box that never rotates, the obstacles static boxes and one
// edge (the back wall). That narrow case is solved here directly instead of through Box2D:
//
// - each step runs `substeps` sub-steps of velocity damping (Box2D's `v /= 1 + h·damping`), motion, then contact
//   resolution: overlapping pairs are pushed apart along the axis of least overlap (by inverse mass) and their
//   closing velocity is removed with restitution (the larger of the two) and Coulomb friction (√(μa·μb));
// - a body is affected by a contact when its `collisionBitMask` meets the other's `categoryBitMask` (SpriteKit's
//   rule); static bodies are never moved;
// - an edge is crossed only by a body that already straddled it, so a fast body cannot tunnel through the wall.
//
// Positions live on the nodes (scene units, y up); bodies are attached to the scene's world when their node is in
// the scene and detached when it leaves. Exact trajectories differ from SpriteKit's Box2D; the scene code relies
// only on what the tests check on both: piles stop, stay on the desk, never overlap furniture or each other for long.

@MainActor
public final class SKPhysicsBody {
    enum Shape {
        case box(CGSize)
        case edge(CGPoint, CGPoint)
    }

    let shape: Shape
    weak var node: SKNode?
    weak var world: SKPhysicsWorld?

    public var isDynamic = true
    public var allowsRotation = true
    public var affectedByGravity = true
    public var friction: CGFloat = 0.2
    public var restitution: CGFloat = 0.2
    public var linearDamping: CGFloat = 0.1
    public var angularDamping: CGFloat = 0.1
    public var usesPreciseCollisionDetection = false
    public var categoryBitMask: UInt32 = 0xFFFF_FFFF
    public var collisionBitMask: UInt32 = 0xFFFF_FFFF
    public var contactTestBitMask: UInt32 = 0
    public var velocity: CGVector = .zero

    private var explicitMass: CGFloat?

    /// A box centred on its node.
    public init(rectangleOf size: CGSize) {
        shape = .box(size)
    }

    /// A static segment in its node's coordinates.
    public init(edgeFrom a: CGPoint, to b: CGPoint) {
        shape = .edge(a, b)
        isDynamic = false
    }

    /// SpriteKit's default: density 1 over the area in square metres (150 points to the metre); settable.
    public var mass: CGFloat {
        get {
            if let explicitMass { return explicitMass }
            guard case let .box(size) = shape else { return 0 }
            return size.width * size.height / (SKPhysicsWorld.pointsPerMeter * SKPhysicsWorld.pointsPerMeter)
        }
        set { explicitMass = newValue }
    }

    func nodeMoved() {}

    func detach() {
        world?.remove(self)
    }

    var inverseMass: CGFloat { isDynamic && mass > 0 ? 1 / mass : 0 }

    /// The box's bounds in scene units, or nil for an edge.
    func bounds(at p: CGPoint) -> CGRect? {
        guard case let .box(size) = shape else { return nil }
        return CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
    }
}

@MainActor
public final class SKPhysicsWorld {
    static let pointsPerMeter: CGFloat = 150
    /// Sub-steps per step; with the scene's speed clamp (1200 art px/s) a body moves at most 2.5 art px each.
    public static let substeps = 8

    public var gravity = CGVector(dx: CGFloat(0), dy: CGFloat(-9.8))
    public var speed: CGFloat = 1

    private var bodies: [SKPhysicsBody] = []

    init() {}

    func add(_ body: SKPhysicsBody) {
        guard body.world !== self else { return }
        body.world?.remove(body)
        body.world = self
        bodies.append(body)
    }

    func remove(_ body: SKPhysicsBody) {
        guard body.world === self else { return }
        bodies.removeAll { $0 === body }
        body.world = nil
    }

    /// Bodies currently in the world (tests).
    public var bodyCount: Int { bodies.count }

    /// Advances the world by `dt` seconds (the presenter calls it once per frame, before `didSimulatePhysics`).
    public func step(_ dt: Double) {
        guard speed > 0, dt > 0 else { return }
        let live = bodies.filter { $0.node != nil && $0.node?.scene != nil }
        guard live.contains(where: \.isDynamic) else { return }
        let h = CGFloat(dt) * speed / CGFloat(Self.substeps)
        var positions = live.map { $0.node!.position }
        for _ in 0..<Self.substeps {
            for i in live.indices where live[i].isDynamic {
                let b = live[i]
                if b.affectedByGravity {
                    b.velocity.dx += gravity.dx * Self.pointsPerMeter * h
                    b.velocity.dy += gravity.dy * Self.pointsPerMeter * h
                }
                let damp = 1 / (1 + h * max(0, b.linearDamping))
                b.velocity.dx *= damp
                b.velocity.dy *= damp
                positions[i].x += b.velocity.dx * h
                positions[i].y += b.velocity.dy * h
            }
            // Two passes settle chains of contacts (a pile pushed into a pile against furniture).
            for _ in 0..<2 {
                for i in live.indices where live[i].isDynamic {
                    for j in live.indices where j != i {
                        if j < i && live[j].isDynamic { continue }      // each dynamic pair once
                        resolve(live, &positions, i, j)
                    }
                }
            }
        }
        for i in live.indices where live[i].isDynamic {
            let p = positions[i]
            if p.x.isFinite && p.y.isFinite { live[i].node!.position = p }
        }
    }

    private func affects(_ a: SKPhysicsBody, by b: SKPhysicsBody) -> Bool {
        a.collisionBitMask & b.categoryBitMask != 0
    }

    private func resolve(_ live: [SKPhysicsBody], _ positions: inout [CGPoint], _ i: Int, _ j: Int) {
        let a = live[i], b = live[j]
        let aMoves = affects(a, by: b), bMoves = b.isDynamic && affects(b, by: a)
        guard aMoves || bMoves, let ra = a.bounds(at: positions[i]) else { return }
        var normal = CGVector.zero          // from a towards b
        var depth: CGFloat = 0
        switch b.shape {
        case .box:
            guard let rb = b.bounds(at: positions[j]) else { return }
            let ox = min(ra.maxX, rb.maxX) - max(ra.minX, rb.minX)
            let oy = min(ra.maxY, rb.maxY) - max(ra.minY, rb.minY)
            guard ox > 0, oy > 0 else { return }
            if ox < oy {
                depth = ox
                normal = CGVector(dx: ra.midX < rb.midX ? 1 : -1, dy: 0)
            } else {
                depth = oy
                normal = CGVector(dx: 0, dy: ra.midY < rb.midY ? 1 : -1)
            }
        case let .edge(p0, p1):
            let origin = b.node?.position ?? .zero
            let e0 = CGPoint(x: origin.x + p0.x, y: origin.y + p0.y), e1 = CGPoint(x: origin.x + p1.x, y: origin.y + p1.y)
            guard let hit = Self.edgeContact(ra, e0, e1) else { return }
            normal = hit.normal
            depth = hit.depth
        }
        let wa = aMoves ? a.inverseMass : 0, wb = bMoves ? b.inverseMass : 0
        let total = wa + wb
        guard total > 0 else { return }
        // Push apart.
        positions[i].x -= normal.dx * depth * wa / total
        positions[i].y -= normal.dy * depth * wa / total
        if wb > 0 {
            positions[j].x += normal.dx * depth * wb / total
            positions[j].y += normal.dy * depth * wb / total
        }
        // Remove the closing velocity along the normal, with restitution and friction.
        let vb = b.isDynamic ? b.velocity : .zero
        let rvx = vb.dx - a.velocity.dx, rvy = vb.dy - a.velocity.dy
        let vn = rvx * normal.dx + rvy * normal.dy
        guard vn < 0 else { return }
        let e = max(a.restitution, b.restitution)
        let jn = -(1 + e) * vn / total
        let tx = rvx - vn * normal.dx, ty = rvy - vn * normal.dy
        let tl = (tx * tx + ty * ty).squareRoot()
        var jt: CGFloat = 0
        if tl > 1e-9 {
            let mu = (max(0, a.friction) * max(0, b.friction)).squareRoot()
            jt = max(-mu * jn, min(mu * jn, -tl / total))
        }
        let ix = jn * normal.dx + (tl > 1e-9 ? jt * tx / tl : 0)
        let iy = jn * normal.dy + (tl > 1e-9 ? jt * ty / tl : 0)
        if wa > 0 {
            a.velocity.dx -= ix * wa
            a.velocity.dy -= iy * wa
        }
        if wb > 0 {
            b.velocity.dx += ix * wb
            b.velocity.dy += iy * wb
        }
    }

    /// Contact of a box with a segment: the box straddles the segment's line within its span. The normal points
    /// from the box towards the line, and the depth is how far the box must move back to the side its centre is on.
    static func edgeContact(_ r: CGRect, _ e0: CGPoint, _ e1: CGPoint) -> (normal: CGVector, depth: CGFloat)? {
        let dx = e1.x - e0.x, dy = e1.y - e0.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0 else { return nil }
        // Unit normal of the line, and the box's extent along the segment.
        let nx = -dy / len, ny = dx / len
        let ux = dx / len, uy = dy / len
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        let along = corners.map { ($0.x - e0.x) * ux + ($0.y - e0.y) * uy }
        guard along.max()! > 0, along.min()! < len else { return nil }
        let side = corners.map { ($0.x - e0.x) * nx + ($0.y - e0.y) * ny }
        let lo = side.min()!, hi = side.max()!
        guard lo < 0, hi > 0 else { return nil }
        let centre = (r.midX - e0.x) * nx + (r.midY - e0.y) * ny
        if centre <= 0 {
            // The box is on the negative side: move it back by `hi` along −n; the normal (box → line) is +n.
            return (CGVector(dx: nx, dy: ny), hi)
        }
        return (CGVector(dx: -nx, dy: -ny), -lo)
    }
}

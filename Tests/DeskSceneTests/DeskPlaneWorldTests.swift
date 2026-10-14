import DeskCore
import Metal
import SpriteKit
import Testing
@testable import DeskScene

/// Steps a bare `DeskPlaneWorld` through `SKRenderer` (the only way SpriteKit runs its physics), one fixed frame at
/// a time, as `SceneHost` does.
@MainActor
private final class WorldRig {
    let world = DeskPlaneWorld()
    let presenter: PixelPresenter
    let scene: SKScene
    private var frame = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        presenter = try PixelPresenter(device: device, artSize: ArtSize(8, 8))
        scene = SKScene(size: CGSize(width: 2400, height: 800))
        scene.addChild(world.root)
        world.attach(to: scene)
        presenter.scene = scene
        presenter.update(atTime: 0)
    }

    func step(_ n: Int = 1) {
        for _ in 0..<n {
            frame += 1
            presenter.update(atTime: FrameClock.time(steps: frame))
        }
    }
}

@Suite("Desk-plane world (physics calibration)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct DeskPlaneWorldTests {
    @Test("Velocities are plane px/s; damping 4 stops a pile after about v/4 px; gravity plays no part")
    func unitsAndDamping() throws {
        let rig = try WorldRig()
        #expect(rig.scene.physicsWorld.gravity == .zero)
        rig.world.addPile("P1", at: [100, 40], velocity: [300, 0])
        rig.step()
        let one = try #require(rig.world.position(of: "P1"))
        // One 1/60 s step at ~300 px/s (Box2D damps before it moves): about 4.7 px.
        #expect(one.x > 104 && one.x < 105.2 && abs(one.y - 40) < 0.001, "\(one)")
        rig.step(240)
        let rest = try #require(rig.world.position(of: "P1"))
        #expect(abs(rest.x - 175) < 3, "slid v/4 = 75 px: \(rest)")
        #expect(simd_length(rig.world.velocity(of: "P1")) < 0.5)
    }

    @Test("Pressed together, piles rest one body apart: the 10-px footprint less the 1-px inset (SpriteKit adds no skin)")
    func restingGap() throws {
        // Clear of the keyboard (d 40–64) and the back strip (d ≥ 112): a pile pressed onto another one that sits
        // against the back wall.
        let rig = try WorldRig()
        rig.world.addPile("P1", at: [460, 100], velocity: [0, 200])
        rig.world.addPile("P2", at: [460, 70])
        // Held pressed (a gentle push every frame) until both are still.
        for _ in 0..<300 {
            rig.world.setVelocity("P2", [0, 30])
            rig.step()
        }
        let a = try #require(rig.world.position(of: "P1")), b = try #require(rig.world.position(of: "P2"))
        let gap = a.y - b.y
        #expect(gap >= 8.7 && gap <= 9.3, "centres \(gap) px apart (body depth 9)")
        #expect(abs(a.y - (128 - 5)) < 0.8, "P1 against the wall: \(a)")
    }

    @Test("The back wall, the back-strip footprints and the keyboard stop piles; the front and sides are open")
    func obstacles() throws {
        let rig = try WorldRig()
        rig.world.addPile("wall", at: [100, 100], velocity: [0, 800])
        rig.world.addPile("riser", at: [260, 90], velocity: [0, 800])
        rig.world.addPile("keys", at: [254, 20], velocity: [0, 600])
        rig.world.addPile("front", at: [380, 20], velocity: [0, -600])
        rig.step(240)
        let wall = try #require(rig.world.position(of: "wall")).y
        let riser = try #require(rig.world.position(of: "riser")).y
        let keys = try #require(rig.world.position(of: "keys")).y
        let front = try #require(rig.world.position(of: "front")).y
        let half = DeskPlanePhysics.pileSize.y / 2
        #expect(wall <= 128 - half + 0.6 && wall > 60, "bounced off the back wall: \(wall)")
        #expect(riser <= DeskPlanePhysics.backStripD - half + 0.6, "stopped at the riser: \(riser)")
        #expect(keys <= 40 - half + 0.6, "stopped at the keyboard: \(keys)")
        #expect(front < 0, "nothing holds a pile at the front edge: \(front)")
    }

    @Test("A frozen (static) pile does not move when hit; thawed, it does")
    func freezing() throws {
        let rig = try WorldRig()
        rig.world.addPile("P1", at: [200, 90])
        rig.world.setDynamic("P1", false)
        rig.world.addPile("P2", at: [170, 90], velocity: [500, 0])
        rig.step(120)
        #expect(rig.world.position(of: "P1") == [200, 90])
        rig.world.removePile("P2")
        rig.world.setDynamic("P1", true)
        rig.world.addPile("P3", at: [170, 90], velocity: [600, 0])
        rig.step(120)
        #expect(try #require(rig.world.position(of: "P1")).x > 210)
    }

    @Test("The carried cup is a heavy velocity-driven prop that shoves piles aside")
    func propShoves() throws {
        let rig = try WorldRig()
        rig.world.addPile("P1", at: [220, 90])
        rig.world.beginProp(at: [180, 90], size: [14, 8])
        for _ in 0..<60 {
            rig.world.driveProp(toward: [260, 90], dt: 1.0 / 60)
            rig.step()
        }
        let prop = try #require(rig.world.propPosition)
        let pile = try #require(rig.world.position(of: "P1"))
        #expect(prop.x > 250, "the prop got there: \(prop)")
        #expect(pile.x > prop.x + 9, "the pile was pushed ahead of it: \(pile)")
        rig.world.endProp()
        #expect(!rig.world.hasProp)
    }
}

@Suite("Desk-plane world (CPU)")
struct DeskPlaneWorldUnitTests {
    @Test("Plane points and vectors map to scene units 1:4 and back")
    func units() {
        let p = SIMD2<Float>(123.25, 45.5)
        #expect(DeskPlaneWorld.planePoint(DeskPlaneWorld.scenePoint(p)) == p)
        #expect(DeskPlaneWorld.scenePoint(p) == CGPoint(x: 493, y: 182))
        #expect(DeskPlaneWorld.planeVector(DeskPlaneWorld.sceneVector([10, -20])) == [10, -20])
        #expect(DeskPlaneWorld.pileBodySize == CGSize(width: 52, height: 36))
    }

    @Test("Furniture: the keyboard follows the mat's record of it; the cup's footprint comes and goes")
    func furniture() {
        let world = DeskPlaneWorld()
        #expect(world.obstacles == [DeskPlaneWorld.keyboardFootprint(nil)])
        world.setFurniture("keyboard", DeskPlaneWorld.keyboardFootprint([300, 60]))
        world.setFurniture("pencup", DeskPlanePhysics.penCupFootprint(at: [367, 120]))
        #expect(Set(world.obstacles.map(\.x)) == [252, 360])
        world.setFurniture("pencup", nil)
        #expect(world.obstacles.count == 1)
    }
}

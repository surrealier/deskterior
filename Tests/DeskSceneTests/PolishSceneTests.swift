import DeskCore
import Foundation
import Testing
@testable import DeskScene

/// Wave-6 polish in the scene (Errata 26): hover rings that follow the plant's jiggle and keep a token's light.
@Suite("Scene polish (wave 6)")
struct PolishSceneTests {
    typealias F = SceneFixture

    @Test("A lit token's hover ring keeps the light it stands in (at least the faint level); the switch's stays full")
    func tokenRingKeepsItsLight() throws {
        let (store, _, lit, _) = try DarkHitTests.setUp()
        let scene = store.scene
        let room = try #require(scene.room)
        let p = Pointer(scene: scene)
        _ = p.event(.move, lit)
        #expect(scene.hoveredHit?.token == F.key(101))
        let ring = try #require(room.hoverRing)
        let w = scene.layout!.canvas.w
        let base = room.lightMask, shown = scene.lighting.mask
        var below = 0
        for y in 0..<ring.image.height {
            for x in 0..<ring.image.width where ring.image.pixel(x, y).a != 0 {
                let px = ring.origin.x + x, py = ring.origin.y + y
                let own = base.level(px, py)
                #expect(Int(shown[py * w + px] & 7) == max(own, DarkTokenElement.ringLevel), "ring pixel (\(px), \(py))")
                if own < LightRamp.maxLevel { below += 1 }
            }
        }
        #expect(below > 0, "the token stands in the lamp's dimmer bands, and its ring does too")
        _ = p.event(.move, F.centre(scene.layout!.rect(CoreLayout.roomSwitch)))
        #expect(room.hoverRing?.level == LightRamp.maxLevel)
    }

    @Test("The plant's hover ring follows its jiggle, and comes back to the still plant's")
    func plantRingFollowsJiggle() throws {
        let scene = F.scene(F.state())
        let room = try #require(scene.room)
        let plant = try #require(scene.roomElement("plant") as? PlantElement)
        let r = scene.layout!.rect(CoreLayout.plant)
        var at: SIMD2<Float>?
        search: for y in r.minY..<r.maxY {
            for x in r.minX..<r.maxX where room.hitTest(ArtPoint(x, y))?.element == "plant" {
                at = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                break search
            }
        }
        let p = Pointer(scene: scene)
        let point = try #require(at)
        _ = p.event(.move, point)
        let still = try #require(room.hoverRing)
        p.click(point)
        #expect(plant.isJiggling)
        var rings: [PixelBuffer] = []
        while plant.isJiggling {
            let ring = try #require(room.hoverRing)
            if rings.last != ring.image { rings.append(ring.image) }
            p.frames(1)
        }
        #expect(rings.count >= 3, "a ring per jiggle frame (\(rings.count))")
        #expect(rings.contains { $0 != still.image })
        #expect(room.hoverRing == still, "the still plant's ring once the jiggle ends")
    }
}

// MARK: The keyboard on a turned mat

extension PolishSceneTests {
    /// A small mat turned 14°, centred on the keyboard's default spot (as Size ▸ Small and Rotate +15° leave it).
    static func turnedMat(particles: String? = nil) -> MatState {
        let theta = Float(14) * .pi / 180
        let size = SIMD2<Float>(150, 60), centre = SIMD2<Float>(254, 52)
        let (c, n) = (cos(theta), sin(theta))
        let half = SIMD2(size.x / 2 * c - size.y / 2 * n, size.x / 2 * n + size.y / 2 * c)
        return MatState(origin: centre - half, size: size, angle: theta, grid: [26, 11], particles: particles,
                        keyboard: centre)
    }

    @Test("On a turned mat the keyboard is drawn turned with it, keys answering where drawn; a relaunch draws it so too")
    func keyboardTurnsWithTheMat() throws {
        var s = matDesk([])
        s.mat = Self.turnedMat()
        let scene = F.scene(s)
        let room = try #require(scene.room)
        let mat = try #require(room.matElement)
        let keyboard = try #require(scene.roomElement("keyboard") as? KeyboardElement)
        let placed = try #require(room.elements.first { $0.id == "keyboard" }?.placements.first { $0.id == "keyboard" })
        #expect(placed.sprite.name == "keyboard.turned14")
        #expect(keyboard.turned?.degrees == 14)
        let turned = try #require(keyboard.turned)
        #expect(placed.sprite.frames[0] == turned.image)
        // Esc (row 0, key 0) answers where it is drawn: a click there presses it.
        let w = CoreLayout.keyboard.w
        let esc = try #require(PropArt.keyboardKeys.first { $0.row == 0 && $0.col == 0 })
        let i = try #require(turned.source.firstIndex(of: Int32((esc.rect.minY + 1) * w + esc.rect.minX + 1)))
        let at = placed.origin + ArtPoint(i % turned.image.width, i / turned.image.width)
        #expect(scene.hitTest(at)?.element == "keyboard")
        #expect(keyboard.pressKey(at: at) && keyboard.pressedKey?.row == 0 && keyboard.pressedKey?.col == 0)

        // The saved pose (every particle) brings the same keyboard back, at the same pixel.
        mat.settle()
        var saved = s
        saved.mat = mat.cloth.matState(pattern: "felt", mode: "cloth")
        #expect(saved.mat.particles != nil)
        let again = F.scene(saved)
        let back = try #require(again.room?.elements.first { $0.id == "keyboard" }?.placements.first { $0.id == "keyboard" })
        #expect(back.sprite.name == placed.sprite.name && back.origin == mat.keyboardRect?.origin)
    }

    @Test("A square mat keeps the upright keyboard sprite")
    func squareMatUpright() throws {
        let scene = F.scene(matDesk([]))
        let placed = try #require(scene.room?.elements.first { $0.id == "keyboard" }?.placements.first { $0.id == "keyboard" })
        #expect(placed.sprite == PropArt.keyboard())
    }
}

#if canImport(Metal)
import DeskCore
#if canImport(Metal)
import Metal
#endif
#if canImport(SpriteKit)
import SpriteKit
#else
import DeskStage
#endif
import Testing
@testable import DeskScene

/// The software renderer (docs/WINDOWS.md, WP2) against SpriteKit and the Metal passes, on the Mac: the same scene
/// flattened and drawn by `SoftRaster` is SpriteKit's art frame, and `SoftPost` is the lit and upscale shaders.
/// Windows then draws what the Mac draws.
@Suite("Software renderer parity", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct SoftRendererParityTests {
    let gpu: GPU
    let grid = PixelGrid(display: calibrationDisplay)

    init() throws {
        gpu = try GPU()
        TextureFactory.recordsPixels = true
    }

    /// SpriteKit's art and lit frames, and the software renderer's, for the host's current scene.
    func frames(_ host: SceneHost) throws -> (art: PixelBuffer, lit: PixelBuffer, softArt: PixelBuffer, softLit: PixelBuffer) {
        let art = try host.presenter.readArtFrame()
        let lit = try host.presenter.readLitFrame()
        let softArt = SoftRaster.composite(SceneFlattener.items(host.scene), canvas: grid.artSize, clear: host.presenter.clearColor)
        let l = host.scene.lighting
        let softLit = SoftPost.lit(softArt, mask: l.mask, ambientLevel: l.ambient.level, ambientTint: l.ambient.tint)
        return (art, lit, softArt, softLit)
    }

    @Test("The room: day, night, Lamp Only and dusk", arguments: [(10, LightsMode.auto), (22, .auto), (22, .lampOnly), (18, .auto)])
    func room(hour: Int, lights: LightsMode) throws {
        let host = try SceneHost(grid: grid, device: gpu.device)
        host.scene.clock = .fixed(WallTime(hour: hour, minute: 0))
        host.scene.lightsMode = lights
        host.scene.connect(presenter: host.presenter)
        OffscreenDriver(host: host).run(frames: 1)
        let f = try frames(host)
        #expect(f.softArt == f.art, "\(diffCount(f.softArt, f.art)) art px differ")
        #expect(f.softLit == f.lit, "\(diffCount(f.softLit, f.lit)) lit px differ")
    }

    @Test("The calibration card after a click, a hover and 30 frames")
    func calibration() throws {
        let host = try SceneHost(grid: grid, device: gpu.device)
        host.scene.setContent(.calibration)
        let swatches = host.scene.calibration!.swatchRects
        func centre(_ i: Int) -> SIMD2<Float> { SIMD2(Float(swatches[i].center.x), Float(swatches[i].center.y)) }
        host.handle(InputEvent(.down, art: centre(27), clickCount: 1))
        host.handle(InputEvent(.move, art: centre(40)))
        OffscreenDriver(host: host).run(frames: 30)
        let f = try frames(host)
        #expect(f.softArt == f.art, "\(diffCount(f.softArt, f.art)) art px differ")
        #expect(f.softLit == f.lit, "\(diffCount(f.softLit, f.lit)) lit px differ")
    }

    @Test("Sprites off the pixel grid, stretched and overlapping draw as SpriteKit draws them")
    func fractionalSprites() throws {
        let size = ArtSize(40, 30)
        var art = PixelBuffer(width: 5, height: 3)
        for y in 0..<3 { for x in 0..<5 { art[x, y] = Apollo.colors[(x + y * 5) % Apollo.count] } }
        art[2, 1] = .clear
        func sprite(_ texture: SKTexture, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, z: CGFloat, anchor: CGPoint = .zero) -> SKSpriteNode {
            let n = SKSpriteNode(texture: texture)
            n.size = CGSize(width: w, height: h)
            n.anchorPoint = anchor
            n.position = CGPoint(x: x, y: y)
            n.zPosition = z
            return n
        }
        let parent = SKNode()
        parent.position = CGPoint(x: 6, y: 2)
        parent.zPosition = 1
        let nodes: [SKNode] = [
            sprite(TextureFactory.texture(art), x: 8, y: 8, w: 20, h: 12, z: 0),                       // on the grid
            sprite(TextureFactory.texture(art), x: 30, y: 50, w: 20, h: 12, z: 2),                      // over it
            sprite(TextureFactory.dynamicTexture(art), x: 62, y: 22, w: 40, h: 24, z: 0),               // ×2
            sprite(TextureFactory.solid(Apollo.colors[3]), x: 2, y: 90, w: 60, h: 8, z: 0),              // a fill
            sprite(TextureFactory.texture(art), x: 100, y: 70, w: 20, h: 12, z: 0, anchor: CGPoint(x: 0.5, y: 0.5)),
            parent,
        ]
        parent.addChild(sprite(TextureFactory.texture(art), x: 0, y: 0, w: 20, h: 12, z: 0))
        let gpuArt = try gpu.renderScene(size: size, nodes)
        let scene = SKScene(size: ArtSpace(canvas: size).sceneSize)
        scene.anchorPoint = .zero
        for n in nodes {
            n.removeFromParent()
            scene.addChild(n)
        }
        let soft = SoftRaster.composite(SceneFlattener.items(scene), canvas: size, clear: Ink.neutral1.color)
        #expect(soft == gpuArt, "\(diffCount(soft, gpuArt)) px differ")
    }

    @Test("The lit pass: every level, tint and mask byte as the shader computes it")
    func litPass() throws {
        var rng = SplitMix64(seed: 3)
        var art = PixelBuffer(width: 64, height: 48)
        var mask = [UInt8](repeating: 0, count: art.width * art.height)
        for i in 0..<mask.count {
            // Exact Apollo colours and ±1 drifts (what blending can produce), with every mask level and tint.
            let c = Apollo.colors[Int(rng.next() % UInt64(Apollo.count))]
            let drift: UInt8 = rng.next() % 3 == 0 ? 1 : 0
            art[i % art.width, i / art.width] = RGBA8(c.r &+ drift, c.g, c.b, 255)
            mask[i] = UInt8(rng.next() % 8) | UInt8(rng.next() % 4) << 3
        }
        for level in 0...LightRamp.maxLevel {
            for tint in Tint.allCases {
                let shader = try gpu.lit(art, ambient: AmbientLight(level: level, tint: tint), mask: mask)
                let soft = SoftPost.lit(art, mask: mask, ambientLevel: level, ambientTint: tint)
                #expect(soft == shader, "level \(level) \(tint): \(diffCount(soft, shader)) px differ")
            }
        }
    }

    @Test("The upscale pass: scales, crops and shakes", arguments: [(2, 0, 0), (5, 3, 4), (3, 1, 2), (7, 6, 0)])
    func upscalePass(scale: Int, cropLeft: Int, cropTop: Int) throws {
        var rng = SplitMix64(seed: UInt64(scale))
        var lit = PixelBuffer(width: 23, height: 17)
        for y in 0..<lit.height {
            for x in 0..<lit.width { lit[x, y] = Apollo.colors[Int(rng.next() % UInt64(Apollo.count))] }
        }
        for shake in [ArtPoint.zero, ArtPoint(1, -1), ArtPoint(-2, 1)] {
            let p = UpscaleParams(scale: scale, cropLeft: cropLeft, cropTop: cropTop, shake: shake)
            let w = lit.width * scale - cropLeft, h = lit.height * scale - cropTop
            let shader = try gpu.upscale(lit, width: w, height: h, params: p)
            let soft = SoftPost.upscale(lit, width: w, height: h, scale: scale, cropLeft: cropLeft, cropTop: cropTop, shake: shake)
            #expect(soft == shader, "shake \(shake): \(diffCount(soft, shader)) px differ")
        }
    }
}
#endif

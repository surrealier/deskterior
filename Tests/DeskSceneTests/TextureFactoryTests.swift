import Metal
import SpriteKit
import Testing
@testable import DeskScene
import DeskCore

/// Pins texture orientation and colour exactness through the real `SKRenderer` path (SPIKES S5, S8).
@Suite("TextureFactory", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct TextureFactoryTests {
    let gpu: GPU

    init() throws {
        gpu = try GPU()
    }

    /// 5×3, every pixel a different palette colour: asymmetric under both flips.
    static let pattern = PixelBuffer(
        width: 5, height: 3, pixels: (0..<15).map { Apollo.colors[($0 * 3 + 1) % Apollo.count] }
    )

    func render(_ texture: SKTexture, _ size: ArtSize) throws -> PixelBuffer {
        let node = SKSpriteNode(texture: texture)
        ArtSpace(canvas: size).place(node, at: ArtRect(0, 0, size.w, size.h))
        return try gpu.renderScene(size: size, [node])
    }

    @Test("SKTexture(data:size:) reads rows in the pinned order")
    func rawDataRowOrder() throws {
        let p = Self.pattern
        let out = try render(TextureFactory.dataTexture(p.rgbaBytes, width: p.width, height: p.height), p.size)
        let expected = TextureFactory.dataRowsAreBottomUp ? p.flippedVertically() : p
        #expect(out == expected, "SpriteKit's data row order changed: flip TextureFactory.dataRowsAreBottomUp")
    }

    @Test("Dynamic (data) textures show row 0 at the top, exactly")
    func dynamicUpright() throws {
        let out = try render(TextureFactory.dynamicTexture(Self.pattern), Self.pattern.size)
        #expect(out == Self.pattern, "\(diffCount(out, Self.pattern)) px differ")
    }

    @Test("Static (CGImage) textures show row 0 at the top, exactly")
    func staticUpright() throws {
        let out = try render(TextureFactory.texture(Self.pattern), Self.pattern.size)
        #expect(out == Self.pattern, "\(diffCount(out, Self.pattern)) px differ")
    }

    @Test("Factory textures sample nearest without mipmaps")
    func filtering() {
        for t in [TextureFactory.texture(Self.pattern), TextureFactory.dynamicTexture(Self.pattern),
                  TextureFactory.solid(.white)] {
            #expect(t.filteringMode == .nearest)
            #expect(!t.usesMipmaps)
        }
    }

    @Test("A sprite placed through ArtSpace lands on its art rect; transparent texels show the backdrop")
    func placementAndAlpha() throws {
        var sprite = PixelBuffer(width: 3, height: 2, fill: Ink.red3.color)
        sprite[1, 0] = .clear
        let node = SKSpriteNode(texture: TextureFactory.texture(sprite))
        let size = ArtSize(8, 6)
        ArtSpace(canvas: size).place(node, at: ArtRect(4, 1, 3, 2))
        let backdrop = Ink.neutral1.color
        let full = SKSpriteNode(texture: TextureFactory.solid(backdrop))
        full.zPosition = -1
        ArtSpace(canvas: size).place(full, at: ArtRect(0, 0, 8, 6))
        let out = try gpu.renderScene(size: size, backdrop: backdrop, [full, node])

        var expected = PixelBuffer(width: 8, height: 6, fill: backdrop)
        expected.blit(sprite, at: ArtPoint(4, 1))
        #expect(out == expected, "\(diffCount(out, expected)) px differ")
    }

    @Test("Without a backdrop sprite the art pass shows the clear colour (SKRenderer ignores backgroundColor)")
    func clearColour() throws {
        let out = try gpu.renderScene(size: ArtSize(4, 4), backdrop: Ink.green2.color, [])
        #expect(out.pixels.allSatisfy { $0 == Ink.green2.color })
    }
}

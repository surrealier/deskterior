import DeskCore
#if canImport(SpriteKit)
#if canImport(SpriteKit)
import SpriteKit
#else
import DeskStage
#endif
#else
import DeskStage
#endif

/// A scene's sprites as `SoftRaster` draw items (docs/WINDOWS.md, WP2): every visible sprite with a texture and a
/// size, at its accumulated position and z, in depth-first order. On Windows this is the art pass; on macOS it is
/// what `SoftRasterParityTests` compares with SpriteKit's own output.
///
/// Deskterior's scenes never scale, rotate or fade a node, and the scene's anchor is `.zero`, so a sprite's
/// rectangle is its accumulated position minus `anchorPoint × size`.
enum SceneFlattener {
    static func items(_ scene: SKScene) -> [DrawItem] {
        var out: [DrawItem] = []
        var order = 0
        func visit(_ node: SKNode, x ox: Double, y oy: Double, z oz: Double) {
            guard !node.isHidden else { return }
            let x = ox + Double(node.position.x), y = oy + Double(node.position.y), z = oz + Double(node.zPosition)
            let n = order
            order += 1
            if let sprite = node as? SKSpriteNode, let texture = sprite.texture,
               sprite.size.width > 0, sprite.size.height > 0, let pixels = TextureFactory.pixels(of: texture)
            {
                let w = Double(sprite.size.width), h = Double(sprite.size.height)
                out.append(DrawItem(
                    x: x - Double(sprite.anchorPoint.x) * w, y: y - Double(sprite.anchorPoint.y) * h,
                    width: w, height: h, pixels: pixels, z: z, order: n
                ))
            }
            for child in node.children { visit(child, x: x, y: y, z: z) }
        }
        for child in scene.children { visit(child, x: 0, y: 0, z: 0) }
        return out
    }
}

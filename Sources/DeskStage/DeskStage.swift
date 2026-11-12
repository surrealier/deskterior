import DeskCore
@_exported import Foundation

// The part of SpriteKit that Deskterior's scene code uses, for platforms without SpriteKit (docs/WINDOWS.md, WP2).
// Same names and the same behaviour where the scene depends on it, so `DeskScene` builds unchanged against either:
// a node tree with positions, z and visibility; sprites with a texture, a size and an anchor; textures that keep
// their pixels; and a physics world (`Physics.swift`). Nothing draws here: `SceneFlattener` + `SoftRaster` do.
//
// Behaviour pinned by `DeskStageTests`: a sprite's anchor defaults to the centre, `SKSpriteNode(texture:)` takes the
// texture's size, adding a node that already has a parent traps, `SKTexture(data:size:)` reads rows bottom-up.

/// A 2-D vector (CoreGraphics has one; Foundation outside Apple platforms does not).
public struct CGVector: Hashable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat

    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }

    public static let zero = CGVector(dx: 0, dy: 0)
}

@MainActor
open class SKNode {
    public init() {}

    public var position: CGPoint = .zero {
        didSet { physicsBody?.nodeMoved() }
    }
    public var zPosition: CGFloat = 0
    public var isHidden = false
    /// Kept for the scene code; there are no actions to pause.
    public var isPaused = false
    public var name: String?
    public private(set) weak var parent: SKNode?
    public private(set) var children: [SKNode] = []

    public var physicsBody: SKPhysicsBody? {
        didSet {
            if oldValue !== physicsBody { oldValue?.detach() }
            physicsBody?.node = self
            attachBodies()
        }
    }

    public func addChild(_ node: SKNode) {
        precondition(node.parent == nil, "Attemped to add a SKNode which already has a parent")
        node.parent = self
        children.append(node)
        node.attachBodies()
    }

    public func removeFromParent() {
        guard let parent else { return }
        detachBodies()
        parent.children.removeAll { $0 === self }
        self.parent = nil
    }

    public func removeAllChildren() {
        for child in children {
            child.detachBodies()
            child.parent = nil
        }
        children.removeAll()
    }

    /// The node's bounds in its parent's coordinates: a point at `position` for a node with no content.
    open var frame: CGRect { CGRect(origin: position, size: .zero) }

    /// The scene this node is in, if any.
    public var scene: SKScene? {
        var node: SKNode? = self
        while let n = node {
            if let s = n as? SKScene { return s }
            node = n.parent
        }
        return nil
    }

    // MARK: Physics bookkeeping

    /// Puts this subtree's bodies into the scene's world once the subtree is in a scene.
    func attachBodies() {
        guard let world = scene?.physicsWorld else { return }
        visit { $0.physicsBody.map(world.add) }
    }

    func detachBodies() {
        visit { $0.physicsBody?.detach() }
    }

    private func visit(_ body: (SKNode) -> Void) {
        body(self)
        for child in children { child.visit(body) }
    }
}

public enum SKTextureFilteringMode: Sendable {
    case nearest, linear
}

@MainActor
public final class SKTexture {
    /// The texture's pixels, row 0 = top.
    public let pixels: PixelBuffer
    public var filteringMode: SKTextureFilteringMode = .linear
    public var usesMipmaps = false

    /// RGBA bytes in SpriteKit's order for this initializer: the first row in `data` is the bottom of the image.
    public init(data: Data, size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        let bytes = [UInt8](data)
        precondition(w >= 0 && h >= 0 && bytes.count >= w * h * 4, "texture data too short for \(w)x\(h)")
        var px = [RGBA8](repeating: .clear, count: w * h)
        for row in 0..<h {
            let src = (h - 1 - row) * w * 4
            for x in 0..<w {
                let o = src + x * 4
                px[row * w + x] = RGBA8(bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3])
            }
        }
        pixels = PixelBuffer(width: w, height: h, pixels: px)
    }

    /// A texture straight from `pixels` (row 0 = top).
    public init(pixels: PixelBuffer) {
        self.pixels = pixels
    }

    public func size() -> CGSize {
        CGSize(width: CGFloat(pixels.width), height: CGFloat(pixels.height))
    }
}

@MainActor
open class SKSpriteNode: SKNode {
    public override init() {}

    public convenience init(texture: SKTexture?) {
        self.init()
        self.texture = texture
        if let texture { size = texture.size() }
    }

    public var texture: SKTexture?
    public var size: CGSize = .zero
    public var anchorPoint = CGPoint(x: 0.5, y: 0.5)

    /// The sprite's rectangle in its parent's coordinates (no scale or rotation here).
    open override var frame: CGRect {
        CGRect(x: position.x - anchorPoint.x * size.width, y: position.y - anchorPoint.y * size.height,
               width: size.width, height: size.height)
    }
}

public enum SKSceneScaleMode: Sendable {
    case fill, aspectFill, aspectFit, resizeFill
}

@MainActor
open class SKScene: SKNode {
    public init(size: CGSize) {
        self.size = size
        super.init()
    }

    public var size: CGSize
    public var anchorPoint: CGPoint = .zero
    public var scaleMode: SKSceneScaleMode = .fill
    public let physicsWorld = SKPhysicsWorld()

    /// Called right after each physics step (`SKPhysicsWorld.step`).
    open func didSimulatePhysics() {}
}

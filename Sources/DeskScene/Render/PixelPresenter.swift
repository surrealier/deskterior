import DeskCore
import Metal
import QuartzCore
import SpriteKit

/// Renders a scene through the one pixel pipeline (DESIGN §1.1), for the window, headless runs and tests alike:
///
/// `SKRenderer` → art texture (art size) → lit pass → lit texture (art size; the canonical frame) →
/// upscale pass → drawable or offscreen target (device px).
///
/// `SKRenderer` ignores `scene.backgroundColor` (SPIKES S5), so the art pass clears to `clearColor`; scenes
/// also draw a full backdrop sprite.
public final class PixelPresenter {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    public let post: PostPass
    private let renderer: SKRenderer

    public private(set) var artSize: ArtSize
    /// SpriteKit's output (`PostPass.colorFormat`, art size).
    public private(set) var artTexture: any MTLTexture
    /// The lit frame (`PostPass.colorFormat`, art size).
    public private(set) var litTexture: any MTLTexture
    private var depthTexture: any MTLTexture
    private var maskTexture: any MTLTexture
    private var lightMask: [UInt8]

    /// Room light for the lit pass.
    public var ambient: AmbientLight = .identity
    /// Clear colour of the art pass (the scene's backdrop).
    public var clearColor: RGBA8 = .black

    public init(device: any MTLDevice, artSize: ArtSize) throws {
        guard let queue = device.makeCommandQueue() else { throw RenderError.resource("command queue") }
        queue.label = "Deskterior"
        self.device = device
        self.queue = queue
        post = try PostPass(device: device)
        renderer = SKRenderer(device: device)
        renderer.ignoresSiblingOrder = false
        self.artSize = artSize
        let t = try Self.makeTargets(device, artSize)
        (artTexture, depthTexture, litTexture, maskTexture) = (t.art, t.depth, t.lit, t.mask)
        lightMask = [UInt8](repeating: 0, count: artSize.area)
    }

    /// The scene `SKRenderer` draws (never attached to an `SKView`).
    public var scene: SKScene? {
        get { renderer.scene }
        set { renderer.scene = newValue }
    }

    /// Reallocates the art-size targets (and clears the light mask) when the canvas changes.
    public func resize(_ size: ArtSize) throws {
        guard size != artSize else { return }
        let t = try Self.makeTargets(device, size)
        (artTexture, depthTexture, litTexture, maskTexture) = (t.art, t.depth, t.lit, t.mask)
        artSize = size
        lightMask = [UInt8](repeating: 0, count: size.area)
    }

    /// Replaces the light mask: one byte per art px, row 0 = top; low 3 bits = level 0…7, bit 3 = warm tint.
    /// Uploads only when the bytes change.
    public func setLightMask(_ mask: [UInt8]) throws {
        precondition(mask.count == artSize.area, "light mask must have one byte per art px")
        guard mask != lightMask else { return }
        // A fresh texture, so a frame still in flight keeps reading the old one.
        let t = try PostPass.makeTexture(
            device: device, format: .r8Uint, width: artSize.w, height: artSize.h, usage: .shaderRead,
            cpuWritable: true
        )
        mask.withUnsafeBytes { raw in
            t.replace(
                region: MTLRegionMake2D(0, 0, artSize.w, artSize.h), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: artSize.w
            )
        }
        maskTexture = t
        lightMask = mask
    }

    /// Advances SpriteKit (actions, physics, `update(_:)`) to `time`.
    public func update(atTime time: TimeInterval) {
        renderer.update(atTime: time)
    }

    /// Encodes the art and lit passes.
    public func encodeFrame(_ cmd: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        let c = clearColor
        pass.colorAttachments[0].texture = artTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1
        )
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depthTexture
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        let viewport = CGRect(x: 0, y: 0, width: artSize.w, height: artSize.h)
        renderer.render(withViewport: viewport, commandBuffer: cmd, renderPassDescriptor: pass)
        post.encodeLit(cmd, art: artTexture, mask: maskTexture, ambient: ambient, into: litTexture)
    }

    /// Renders a frame into the layer's next drawable and presents it. False when no drawable was available.
    @discardableResult
    public func present(to layer: CAMetalLayer, params: UpscaleParams) -> Bool {
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else { return false }
        encodeFrame(cmd)
        post.encodeUpscale(cmd, lit: litTexture, params: params, into: drawable.texture)
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    /// Renders a frame offscreen (art and lit textures only); with `wait`, blocks until the GPU is done.
    public func renderOffscreen(wait: Bool = true) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        encodeFrame(cmd)
        cmd.commit()
        if wait { cmd.waitUntilCompleted() }
    }

    /// Upscales the current lit frame into a fresh `width`×`height` offscreen target and reads it back.
    public func upscaledFrame(width: Int, height: Int, params: UpscaleParams) throws -> PixelBuffer {
        let target = try PostPass.makeTexture(
            device: device, format: PostPass.colorFormat, width: width, height: height,
            usage: [.renderTarget, .shaderRead]
        )
        guard let cmd = queue.makeCommandBuffer() else { throw RenderError.resource("command buffer") }
        post.encodeUpscale(cmd, lit: litTexture, params: params, into: target)
        cmd.commit()
        return try Snapshotter.read(target, queue: queue)
    }

    /// The lit frame (waits for queued GPU work).
    public func readLitFrame() throws -> PixelBuffer {
        try Snapshotter.read(litTexture, queue: queue)
    }

    /// SpriteKit's raw output before the lit pass (waits for queued GPU work).
    public func readArtFrame() throws -> PixelBuffer {
        try Snapshotter.read(artTexture, queue: queue)
    }

    private static func makeTargets(
        _ device: any MTLDevice, _ size: ArtSize
    ) throws -> (art: any MTLTexture, depth: any MTLTexture, lit: any MTLTexture, mask: any MTLTexture) {
        let w = max(1, size.w), h = max(1, size.h)
        let art = try PostPass.makeTexture(
            device: device, format: PostPass.colorFormat, width: w, height: h, usage: [.renderTarget, .shaderRead]
        )
        art.label = "art"
        let depth = try PostPass.makeTexture(
            device: device, format: .depth32Float_stencil8, width: w, height: h, usage: .renderTarget
        )
        let lit = try PostPass.makeTexture(
            device: device, format: PostPass.colorFormat, width: w, height: h, usage: [.renderTarget, .shaderRead]
        )
        lit.label = "lit"
        let mask = try PostPass.makeTexture(
            device: device, format: .r8Uint, width: w, height: h, usage: .shaderRead, cpuWritable: true
        )
        let zeros = [UInt8](repeating: 0, count: w * h)
        zeros.withUnsafeBytes { raw in
            mask.replace(
                region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w
            )
        }
        return (art, depth, lit, mask)
    }
}

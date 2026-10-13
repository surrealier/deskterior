import DeskCore
import Metal
import SpriteKit
@testable import DeskScene

/// GPU helpers shared by the Metal-gated suites (each suite is `.enabled(if: MTLCreateSystemDefaultDevice() != nil)`).
struct GPU {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let post: PostPass

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.noDevice
        }
        self.device = device
        self.queue = queue
        post = try PostPass(device: device)
    }

    /// `b` as an `.rgba8Unorm` texture the shaders can read.
    func texture(_ b: PixelBuffer) throws -> any MTLTexture {
        let t = try PostPass.makeTexture(
            device: device, format: .rgba8Unorm, width: b.width, height: b.height, usage: .shaderRead, cpuWritable: true
        )
        b.rgbaBytes.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, b.width, b.height), mipmapLevel: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: b.width * 4)
        }
        return t
    }

    /// An `.r8Uint` light mask (row 0 = top).
    func mask(_ bytes: [UInt8], width: Int, height: Int) throws -> any MTLTexture {
        let t = try PostPass.makeTexture(
            device: device, format: .r8Uint, width: width, height: height, usage: .shaderRead, cpuWritable: true
        )
        bytes.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: width)
        }
        return t
    }

    func target(width: Int, height: Int) throws -> any MTLTexture {
        try PostPass.makeTexture(
            device: device, format: PostPass.colorFormat, width: width, height: height,
            usage: [.renderTarget, .shaderRead]
        )
    }

    /// Runs only the lit pass over `art`.
    func lit(_ art: PixelBuffer, ambient: AmbientLight, mask: [UInt8]? = nil) throws -> PixelBuffer {
        let input = try texture(art)
        let m = try self.mask(mask ?? [UInt8](repeating: 0, count: art.width * art.height),
                              width: art.width, height: art.height)
        let out = try target(width: art.width, height: art.height)
        guard let cmd = queue.makeCommandBuffer() else { throw RenderError.resource("command buffer") }
        post.encodeLit(cmd, art: input, mask: m, ambient: ambient, into: out)
        cmd.commit()
        return try Snapshotter.read(out, queue: queue)
    }

    /// Runs only the upscale pass over `lit` into a `width`×`height` target.
    func upscale(_ lit: PixelBuffer, width: Int, height: Int, params: UpscaleParams) throws -> PixelBuffer {
        let input = try texture(lit)
        let out = try target(width: width, height: height)
        guard let cmd = queue.makeCommandBuffer() else { throw RenderError.resource("command buffer") }
        post.encodeUpscale(cmd, lit: input, params: params, into: out)
        cmd.commit()
        return try Snapshotter.read(out, queue: queue)
    }

    /// Renders `nodes` in a bare scene of `size` art px through `SKRenderer`; returns the raw art frame.
    func renderScene(size: ArtSize, backdrop: RGBA8 = Ink.neutral1.color, _ nodes: [SKNode]) throws -> PixelBuffer {
        let space = ArtSpace(canvas: size)
        let scene = SKScene(size: space.sceneSize)
        scene.anchorPoint = .zero
        scene.scaleMode = .fill
        for n in nodes { scene.addChild(n) }
        let presenter = try PixelPresenter(device: device, artSize: size)
        presenter.scene = scene
        presenter.clearColor = backdrop
        presenter.update(atTime: 0)
        presenter.renderOffscreen()
        return try presenter.readArtFrame()
    }
}

/// Number of differing pixels, for readable failures.
func diffCount(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
    guard a.size == b.size else { return -1 }
    return zip(a.pixels, b.pixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
}

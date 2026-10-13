import DeskCore
import Metal

/// Room light applied by the lit pass wherever the light mask is dimmer (DESIGN §1.4).
public nonisolated struct AmbientLight: Hashable, Sendable {
    /// 0…7; 7 is the identity.
    public var level: Int
    public var tint: Tint

    public init(level: Int, tint: Tint) {
        self.level = min(max(level, 0), LightRamp.maxLevel)
        self.tint = tint
    }

    /// Full light: the lit pass changes nothing.
    public static let identity = AmbientLight(level: LightRamp.maxLevel, tint: .cool)
}

/// How the upscale pass maps device pixels to lit-frame texels:
/// `texel = floor((device + crop) / scale) − shake`, clamped to the frame.
public nonisolated struct UpscaleParams: Hashable, Sendable {
    /// `S`: device px per art px.
    public var scale: Int
    public var cropLeft: Int
    public var cropTop: Int
    /// Screen-shake offset in art px.
    public var shake: ArtPoint

    public init(scale: Int, cropLeft: Int, cropTop: Int, shake: ArtPoint = .zero) {
        self.scale = max(1, scale)
        self.cropLeft = cropLeft
        self.cropTop = cropTop
        self.shake = shake
    }

    public init(grid: PixelGrid, shake: ArtPoint = .zero) {
        self.init(scale: grid.scale, cropLeft: grid.cropLeft, cropTop: grid.cropTop, shake: shake)
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case resource(String)

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case .resource(let what): "could not create \(what)"
        }
    }
}

/// The two post passes after SpriteKit (DESIGN §1.1), compiled from MSL source at runtime (the Command Line
/// Tools have no `metal` compiler):
/// - **lit**: art texel → 64³ index LUT → palette index; `level = max(ambient, mask)`; colour from the
///   46 × 16 light ramp;
/// - **upscale**: nearest integer upscale of the lit frame into the drawable, with crop and shake.
public final class PostPass {
    public let device: any MTLDevice
    private let litPipeline: any MTLRenderPipelineState
    private let upscalePipeline: any MTLRenderPipelineState
    /// `IndexLUT.shared` as a 64³ `.r8Uint` texture.
    let lutTexture: any MTLTexture
    /// `LightRamp.shared.gpuRGBABytes` as a 46 × 16 `.rgba8Unorm` texture.
    let rampTexture: any MTLTexture

    /// Pixel format of the art, lit and output textures.
    public static let colorFormat = MTLPixelFormat.bgra8Unorm

    private static var libraries: [UInt64: any MTLLibrary] = [:]

    public init(device: any MTLDevice) throws {
        self.device = device
        let library = try Self.library(for: device)
        litPipeline = try Self.pipeline(device, library, fragment: "lit_fragment")
        upscalePipeline = try Self.pipeline(device, library, fragment: "upscale_fragment")

        let lut = MTLTextureDescriptor()
        lut.textureType = .type3D
        lut.pixelFormat = .r8Uint
        lut.width = IndexLUT.side
        lut.height = IndexLUT.side
        lut.depth = IndexLUT.side
        lut.usage = .shaderRead
        lut.storageMode = Self.cpuStorage(device)
        guard let lutTexture = device.makeTexture(descriptor: lut) else { throw RenderError.resource("LUT texture") }
        IndexLUT.shared.bytes.withUnsafeBytes { raw in
            lutTexture.replace(
                region: MTLRegionMake3D(0, 0, 0, IndexLUT.side, IndexLUT.side, IndexLUT.side), mipmapLevel: 0,
                slice: 0, withBytes: raw.baseAddress!, bytesPerRow: IndexLUT.side,
                bytesPerImage: IndexLUT.side * IndexLUT.side
            )
        }
        self.lutTexture = lutTexture

        let rampHeight = Tint.allCases.count * LightRamp.levelCount
        let ramp = try Self.makeTexture(
            device: device, format: .rgba8Unorm, width: Apollo.count, height: rampHeight,
            usage: .shaderRead, cpuWritable: true
        )
        LightRamp.shared.gpuRGBABytes.withUnsafeBytes { raw in
            ramp.replace(
                region: MTLRegionMake2D(0, 0, Apollo.count, rampHeight), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: Apollo.count * 4
            )
        }
        rampTexture = ramp
    }

    /// Encodes the lit pass: `art` (any float-readable colour texture) and `mask` (`.r8Uint`, same size) into
    /// `output` (`colorFormat`, same size).
    public func encodeLit(
        _ cmd: any MTLCommandBuffer, art: any MTLTexture, mask: any MTLTexture, ambient: AmbientLight,
        into output: any MTLTexture
    ) {
        guard let enc = makeEncoder(cmd, output, label: "lit") else { return }
        enc.setRenderPipelineState(litPipeline)
        var u: [UInt32] = [UInt32(ambient.level), UInt32(ambient.tint.rawValue)]
        enc.setFragmentTexture(art, index: 0)
        enc.setFragmentTexture(lutTexture, index: 1)
        enc.setFragmentTexture(mask, index: 2)
        enc.setFragmentTexture(rampTexture, index: 3)
        enc.setFragmentBytes(&u, length: u.count * 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Encodes the upscale pass from `lit` into all of `output` (device px).
    public func encodeUpscale(
        _ cmd: any MTLCommandBuffer, lit: any MTLTexture, params p: UpscaleParams, into output: any MTLTexture
    ) {
        guard let enc = makeEncoder(cmd, output, label: "upscale") else { return }
        enc.setRenderPipelineState(upscalePipeline)
        var u: [Int32] = [p.cropLeft, p.cropTop, p.shake.x, p.shake.y, lit.width, lit.height, p.scale, 0]
            .map { Int32(clamping: $0) }
        enc.setFragmentTexture(lit, index: 0)
        enc.setFragmentBytes(&u, length: u.count * 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func makeEncoder(
        _ cmd: any MTLCommandBuffer, _ output: any MTLTexture, label: String
    ) -> (any MTLRenderCommandEncoder)? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        enc?.label = label
        return enc
    }

    // MARK: Helpers

    /// A 2D texture; `cpuWritable` picks a storage mode that `replace(region:)` accepts, otherwise `.private`.
    public static func makeTexture(
        device: any MTLDevice, format: MTLPixelFormat, width: Int, height: Int, usage: MTLTextureUsage,
        cpuWritable: Bool = false
    ) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false
        )
        d.usage = usage
        d.storageMode = cpuWritable ? cpuStorage(device) : .private
        guard let t = device.makeTexture(descriptor: d) else {
            throw RenderError.resource("\(width)x\(height) texture")
        }
        return t
    }

    static func cpuStorage(_ device: any MTLDevice) -> MTLStorageMode {
        device.hasUnifiedMemory ? .shared : .managed
    }

    private static func library(for device: any MTLDevice) throws -> any MTLLibrary {
        if let hit = libraries[device.registryID] { return hit }
        let lib = try device.makeLibrary(source: source, options: nil)
        libraries[device.registryID] = lib
        return lib
    }

    private static func pipeline(
        _ device: any MTLDevice, _ library: any MTLLibrary, fragment: String
    ) throws -> any MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.label = fragment
        d.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = colorFormat
        return try device.makeRenderPipelineState(descriptor: d)
    }

    /// The MSL for both passes. Fragment coordinates are pixel centres, so `uint2(position.xy)` is the pixel.
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VOut { float4 position [[position]]; };

        // One triangle covering the whole target: (-1,-1), (3,-1), (-1,3).
        vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
            float2 p = float2(float((vid << 1) & 2), float(vid & 2));
            VOut o;
            o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            return o;
        }

        struct LitUniforms { uint ambientLevel; uint ambientTint; };

        fragment float4 lit_fragment(VOut in [[stage_in]],
                                     texture2d<float, access::read> art [[texture(0)]],
                                     texture3d<uint, access::read> lut [[texture(1)]],
                                     texture2d<uint, access::read> mask [[texture(2)]],
                                     texture2d<float, access::read> ramp [[texture(3)]],
                                     constant LitUniforms &u [[buffer(0)]]) {
            uint2 p = uint2(in.position.xy);
            uint3 rgb = uint3(round(saturate(art.read(p).rgb) * 255.0));
            uint index = lut.read(rgb >> 2).r;
            uint m = mask.read(p).r;
            uint maskLevel = m & 7u;
            uint level = max(u.ambientLevel, maskLevel);
            uint tint = maskLevel > u.ambientLevel ? ((m >> 3) & 1u) : u.ambientTint;
            return ramp.read(uint2(index, tint * 8u + level));
        }

        struct UpscaleUniforms { int cropLeft, cropTop, shakeX, shakeY, artW, artH, scale, pad; };

        fragment float4 upscale_fragment(VOut in [[stage_in]],
                                         texture2d<float, access::read> lit [[texture(0)]],
                                         constant UpscaleUniforms &u [[buffer(0)]]) {
            int2 p = int2(in.position.xy);
            int2 t = (p + int2(u.cropLeft, u.cropTop)) / u.scale - int2(u.shakeX, u.shakeY);
            t = clamp(t, int2(0), int2(u.artW - 1, u.artH - 1));
            return lit.read(uint2(t));
        }
        """
}

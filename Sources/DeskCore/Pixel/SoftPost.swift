/// The lit and upscale passes without a GPU (docs/WINDOWS.md, WP2): the same integer arithmetic as
/// `PostPass`'s `lit_fragment` and `upscale_fragment`, so a frame is the same pixels on every platform
/// (`SoftPostParityTests` compares the two on macOS).
public enum SoftPost {
    /// The lit frame: every art pixel mapped to its Apollo index (`IndexLUT`), raised to the brighter of the
    /// ambient level and its light-mask level, and looked up in `LightRamp` under the winning tint.
    ///
    /// `mask` is one byte per art pixel, row 0 = top: bits 0–2 the level, bits 3–4 the tint (`LightMask`).
    /// The mask's tint applies only where its level beats the ambient level (a tint above 2 counts as 2).
    public static func lit(
        _ art: PixelBuffer, mask: [UInt8], ambientLevel: Int, ambientTint: Tint, into out: inout PixelBuffer
    ) {
        precondition(mask.count == art.width * art.height, "light mask size \(mask.count) != \(art.width)x\(art.height)")
        if out.width != art.width || out.height != art.height { out = PixelBuffer(width: art.width, height: art.height) }
        let lut = IndexLUT.shared.bytes, ramp = LightRamp.shared.gpuBytes
        let ambient = UInt8(min(max(ambientLevel, 0), LightRamp.maxLevel)), ambientT = UInt8(ambientTint.rawValue)
        let colors = Apollo.colors
        let n = art.width * art.height
        art.withUnsafePixels { src in
            out.withUnsafeMutablePixels { dst in
                for i in 0..<n {
                    let c = src[i]
                    let index = Int(lut[(Int(c.b >> 2) * 64 + Int(c.g >> 2)) * 64 + Int(c.r >> 2)])
                    let m = mask[i]
                    let maskLevel = m & 7
                    let level = max(ambient, maskLevel)
                    let tint = maskLevel > ambient ? min((m >> 3) & 3, 2) : ambientT
                    let mapped = Int(ramp[(Int(tint) * LightRamp.levelCount + Int(level)) * Apollo.count + index])
                    dst[i] = colors[mapped]
                }
            }
        }
    }

    /// `lit` into a fresh buffer.
    public static func lit(_ art: PixelBuffer, mask: [UInt8], ambientLevel: Int, ambientTint: Tint) -> PixelBuffer {
        var out = PixelBuffer(width: art.width, height: art.height)
        lit(art, mask: mask, ambientLevel: ambientLevel, ambientTint: ambientTint, into: &out)
        return out
    }

    /// A `width` × `height` device frame: device pixel `p` shows lit pixel `(p + crop) / scale − shake`, clamped
    /// to the frame (integer division; `PixelGrid` keeps the crop non-negative).
    public static func upscale(
        _ lit: PixelBuffer, width: Int, height: Int, scale: Int, cropLeft: Int, cropTop: Int, shake: ArtPoint = .zero
    ) -> PixelBuffer {
        var out = PixelBuffer(width: width, height: height)
        guard lit.width > 0, lit.height > 0 else { return out }
        let s = max(1, scale)
        var columns = [Int](repeating: 0, count: width)
        for x in 0..<width { columns[x] = min(lit.width - 1, max(0, (x + cropLeft) / s - shake.x)) }
        lit.withUnsafePixels { src in
            out.withUnsafeMutablePixels { dst in
                for y in 0..<height {
                    let ty = min(lit.height - 1, max(0, (y + cropTop) / s - shake.y))
                    let srow = ty * lit.width, drow = y * width
                    for x in 0..<width { dst[drow + x] = src[srow + columns[x]] }
                }
            }
        }
        return out
    }

    /// The lit frame moved by `shake` with its edge pixels repeated: what the upscale shows at scale 1, so a
    /// presenter that scales on its own (GDI, a texture sampler) can apply the shake first.
    public static func shifted(_ lit: PixelBuffer, by shake: ArtPoint) -> PixelBuffer {
        guard shake != .zero else { return lit }
        return upscale(lit, width: lit.width, height: lit.height, scale: 1, cropLeft: 0, cropTop: 0, shake: shake)
    }
}

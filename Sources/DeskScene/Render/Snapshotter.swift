import DeskCore
import DeskPixels
import Foundation
import Metal

/// Reads rendered frames back to the CPU and encodes them as PNG artifacts.
public enum Snapshotter {
    /// Copies a `.bgra8Unorm` or `.rgba8Unorm` texture into a `PixelBuffer` (row 0 = top), after all work
    /// already committed to `queue`.
    public static func read(_ texture: any MTLTexture, queue: any MTLCommandQueue) throws -> PixelBuffer {
        let w = texture.width, h = texture.height, rowBytes = w * 4
        let swapRB: Bool
        switch texture.pixelFormat {
        case .bgra8Unorm: swapRB = true
        case .rgba8Unorm: swapRB = false
        default: throw RenderError.resource("readback of \(texture.pixelFormat)")
        }
        guard
            let buffer = queue.device.makeBuffer(length: rowBytes * h, options: .storageModeShared),
            let cmd = queue.makeCommandBuffer(),
            let blit = cmd.makeBlitCommandEncoder()
        else { throw RenderError.resource("readback buffer") }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * h
        )
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let src = buffer.contents().bindMemory(to: UInt8.self, capacity: rowBytes * h)
        var px = [RGBA8](repeating: .clear, count: w * h)
        for i in 0..<(w * h) {
            let p = src + i * 4
            px[i] = swapRB ? RGBA8(p[2], p[1], p[0], p[3]) : RGBA8(p[0], p[1], p[2], p[3])
        }
        return PixelBuffer(width: w, height: h, pixels: px)
    }

    /// PNG artifacts for one frame: `<name>.png` at art resolution and `<name>@<scale>x.png` upscaled
    /// nearest-neighbour (only the first when `scale` ≤ 1).
    public static func pngs(_ frame: PixelBuffer, name: String, scale: Int) -> [(name: String, data: Data)] {
        var out = [(name: "\(name).png", data: PNGCodec.encode(frame))]
        if scale > 1 {
            out.append((name: "\(name)@\(scale)x.png", data: PNGCodec.encode(frame.scaledNearest(scale))))
        }
        return out
    }
}

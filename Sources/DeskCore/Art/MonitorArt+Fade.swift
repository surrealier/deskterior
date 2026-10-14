/// Reduce Motion's CRT (DESIGN §2.1): a 2-frame fade at the CRT's 12 fps in place of the collapse and the bloom.
extension MonitorArt {
    /// The light levels the picture passes through, brightest first.
    static let fadeLevels = [4, 2]

    /// Power off fades `image` down to the dark glass, power on fades it up: each frame is the picture relit as the
    /// lit pass would at a lower level (`LightRamp`), so it dims through palette colours.
    public static func fadeFrames(_ image: PixelBuffer, poweringOn: Bool) -> [PixelBuffer] {
        let frames = fadeLevels.map { level in
            var out = image
            out.withUnsafeMutablePixels { px in
                for i in px.indices { px[i] = LightRamp.shared.mapColor(px[i], level: level, tint: .cool) }
            }
            return out
        }
        return poweringOn ? frames.reversed() : frames
    }
}

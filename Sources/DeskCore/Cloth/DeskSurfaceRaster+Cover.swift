/// What of the desk surface stands in front of the keyboard (Errata 26).
extension DeskSurfaceRaster {
    /// How high the keyboard's keys stand over the desk (the felt under it and the sprite's two front rows).
    public static let keyboardTop: Float = 3

    /// The last render's pixels inside `mask`'s opaque pixels (its top-left at core `origin`) whose cloth or card
    /// stands higher than `height` over the desk by more than half a pixel: in this projection height is nearness along
    /// the view ray, so they are in front of an object `height` tall lying there (a tongue turned up before the
    /// keyboard or over it, a revealed pile's card standing in front of it). Clear elsewhere; nil when there are none.
    public func cover(_ mask: PixelBuffer, at origin: ArtPoint, height: Float) -> PixelBuffer? {
        let limit = Int32(((height + 0.5) * Self.depthScale).rounded(.down))
        var out = PixelBuffer(width: mask.width, height: mask.height)
        var any = false
        for y in 0..<mask.height {
            let by = origin.y + y - Self.origin.y
            guard by >= 0, by < Self.height else { continue }
            for x in 0..<mask.width where mask[x, y].a != 0 {
                let bx = origin.x + x - Self.origin.x
                guard bx >= 0, bx < Self.width else { continue }
                let t = texels[by * Self.width + bx]
                guard t.depth != .min, t.depth > limit, image[bx, by].a != 0 else { continue }
                out[x, y] = image[bx, by]
                any = true
            }
        }
        return any ? out : nil
    }
}

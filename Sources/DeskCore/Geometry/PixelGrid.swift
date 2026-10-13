// Integer scale, canvas and coordinate mapping between device pixels and art pixels (docs/DESIGN.md §1.2).
//
// Spaces (all y-down):
// - device px: the display frame's backing pixels, origin at the frame's top-left;
// - view points: device px / backingScale (what AppKit reports, after flipping to y-down);
// - canvas art px: the whole art canvas (`artSize`), which is `scale`× larger than the frame and centred on it,
//   so `cropLeft/Top` device px of the canvas hang off the frame's left/top edges;
// - core art px: the 512×320 hand-composed scene (§1.3), placed in the canvas at `coreOrigin`.

/// A rectangle in device pixels (y-down, relative to the display frame's top-left). `maxX`/`maxY` are exclusive.
public struct DeviceRect: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// Exclusive.
    public var maxX: Int { x + w }
    /// Exclusive.
    public var maxY: Int { y + h }
    public var isEmpty: Bool { w <= 0 || h <= 0 }

    public var description: String { "[\(x),\(y) \(w)x\(h)]px" }
}

/// The user's pixel-size setting: the target canvas height `T` in art px. Smaller `T` means bigger art pixels.
public enum PixelSize: String, CaseIterable, Codable, Sendable {
    case chunky
    /// The default.
    case normal
    case fine

    /// `T`: 320 (chunky), 380 (normal), 440 (fine).
    public var targetArtHeight: Int {
        switch self {
        case .chunky: 320
        case .normal: 380
        case .fine: 440
        }
    }
}

/// One display as the grid sees it, in device (backing) pixels.
public struct DisplayGeometry: Hashable, Sendable, Codable {
    public var frameWidthPx: Int
    public var frameHeightPx: Int
    /// `NSScreen.visibleFrame` (excludes menu bar/notch and Dock), y-down, relative to the frame's top-left.
    public var visibleRectPx: DeviceRect
    /// Device px per view point (1 or 2 in practice).
    public var backingScale: Double

    public init(frameWidthPx: Int, frameHeightPx: Int, visibleRectPx: DeviceRect, backingScale: Double) {
        self.frameWidthPx = frameWidthPx
        self.frameHeightPx = frameHeightPx
        self.visibleRectPx = visibleRectPx
        self.backingScale = backingScale
    }

    /// Builds a geometry from point measurements: the frame size and the insets that `visibleFrame` removes
    /// (menu bar on top, Dock on one side). Values are converted to device px and rounded.
    public init(
        widthPt: Double, heightPt: Double, backingScale: Double,
        topInsetPt: Double = 0, bottomInsetPt: Double = 0, leftInsetPt: Double = 0, rightInsetPt: Double = 0
    ) {
        func px(_ pt: Double) -> Int { Int((pt * backingScale).rounded()) }
        let w = px(widthPt), h = px(heightPt)
        let top = px(topInsetPt), bottom = px(bottomInsetPt), left = px(leftInsetPt), right = px(rightInsetPt)
        self.init(
            frameWidthPx: w, frameHeightPx: h,
            visibleRectPx: DeviceRect(left, top, w - left - right, h - top - bottom),
            backingScale: backingScale
        )
    }
}

/// The integer art grid for one display: scale `S`, canvas size, centring crop, core placement and conversions.
///
/// ```
/// S_target = round(frameHeightPx / T)
/// S_fit    = floor(min(visibleWidthPx / 512, visibleHeightPx / 320))
/// S        = max(1, min(S_target, S_fit)), then lowered while the visible rect holds fewer than 512×320
///            *whole* art pixels (the art grid need not line up with the visible rect's edges)
/// artW = ceil(frameWidthPx / S), artH = ceil(frameHeightPx / S)
/// ```
/// The core's floor line (core y 312) sits on the visible rect's bottom edge, i.e. just above a bottom Dock;
/// core rows 312–319 are the floor strip that runs behind the Dock (decor).
public struct PixelGrid: Hashable, Sendable {
    /// The hand-composed core scene (§1.3).
    public static let coreSize = ArtSize(512, 320)
    /// Core y of the floor line: rows `0..<312` stand above it, rows `312..<320` are the floor strip.
    public static let coreFloorY = 312

    public let display: DisplayGeometry
    public let pixelSize: PixelSize
    /// Horizontal core offset (art px) requested by the caller, e.g. the widget nudge.
    public let nudge: Int

    /// `S`: device px per art px (integer, ≥ 1).
    public let scale: Int
    /// Canvas size in art px.
    public let artSize: ArtSize
    /// Device px of the canvas that hang off each frame edge (`artSize * scale − frame`, split floor/remainder).
    public let cropLeft: Int
    public let cropRight: Int
    public let cropTop: Int
    public let cropBottom: Int
    /// Canvas art pixels that are *entirely* inside the display's visible rect.
    public let visibleArtRect: ArtRect
    /// Canvas position of the core's top-left.
    public let coreOrigin: ArtPoint

    /// The core's rect in canvas art px.
    public var coreRect: ArtRect { ArtRect(origin: coreOrigin, size: Self.coreSize) }
    /// The part of the core above the floor line (every interactive element lives here).
    public var coreStageRect: ArtRect { ArtRect(coreOrigin.x, coreOrigin.y, Self.coreSize.w, Self.coreFloorY) }
    /// Canvas y of the floor line (the first floor row).
    public var floorLineY: Int { coreOrigin.y + Self.coreFloorY }
    /// Size of one art pixel in view points (e.g. 2.5 pt at S = 5 on a 2× display).
    public var pointsPerArtPx: Double { Double(scale) / display.backingScale }
    /// Canvas x of the core before the nudge and clamping.
    public var centredCoreX: Int { Self.roundHalfAwayDiv(artSize.w - Self.coreSize.w, 2) }
    /// Nudges that keep the core horizontally inside `visibleArtRect` (nil when it cannot fit at all).
    public var nudgeRange: ClosedRange<Int>? {
        let lo = visibleArtRect.minX - centredCoreX
        let hi = visibleArtRect.maxX - Self.coreSize.w - centredCoreX
        return lo <= hi ? lo...hi : nil
    }

    public init(display: DisplayGeometry, pixelSize: PixelSize = .normal, nudge: Int = 0) {
        self.display = display
        self.pixelSize = pixelSize
        self.nudge = nudge

        let fw = max(0, display.frameWidthPx), fh = max(0, display.frameHeightPx)
        // Clip the visible rect to the frame so bad inputs cannot push the core off-screen.
        let v = display.visibleRectPx
        let vx0 = min(max(v.x, 0), fw), vy0 = min(max(v.y, 0), fh)
        let vx1 = min(max(v.maxX, vx0), fw), vy1 = min(max(v.maxY, vy0), fh)

        var s = max(1, min(
            Self.targetScale(frameHeightPx: fh, pixelSize: pixelSize),
            Self.fitScale(visibleWidthPx: vx1 - vx0, visibleHeightPx: vy1 - vy0)
        ))
        var layout = Self.layout(scale: s, frameWidthPx: fw, frameHeightPx: fh, visible: (vx0, vy0, vx1, vy1))
        while s > 1 && (layout.visible.w < Self.coreSize.w || layout.visible.h < Self.coreSize.h) {
            s -= 1
            layout = Self.layout(scale: s, frameWidthPx: fw, frameHeightPx: fh, visible: (vx0, vy0, vx1, vy1))
        }
        scale = s
        let aw = layout.artSize.w
        artSize = layout.artSize
        cropLeft = layout.cropX / 2
        cropRight = layout.cropX - layout.cropX / 2
        cropTop = layout.cropY / 2
        cropBottom = layout.cropY - layout.cropY / 2
        let visible = layout.visible
        visibleArtRect = visible

        let core = Self.coreSize
        var cx = Self.roundHalfAwayDiv(aw - core.w, 2) + nudge
        if visible.w >= core.w {
            cx = min(max(cx, visible.minX), visible.maxX - core.w)
        } else {
            cx = visible.minX + Self.floorDiv(visible.w - core.w, 2)
        }
        let cy = max(visible.maxY - Self.coreFloorY, visible.minY)
        coreOrigin = ArtPoint(cx, cy)
    }

    /// `round(frameHeightPx / T)`, rounding halves up.
    public static func targetScale(frameHeightPx: Int, pixelSize: PixelSize) -> Int {
        let t = pixelSize.targetArtHeight
        return (2 * max(0, frameHeightPx) + t) / (2 * t)
    }

    /// `floor(min(visibleWidthPx / 512, visibleHeightPx / 320))`: an upper bound on `S`, before whole-pixel
    /// alignment is taken into account.
    public static func fitScale(visibleWidthPx: Int, visibleHeightPx: Int) -> Int {
        min(max(0, visibleWidthPx) / coreSize.w, max(0, visibleHeightPx) / coreSize.h)
    }

    /// Canvas, total crop and fully visible art rect at scale `s` (`visible` in frame device px, clipped).
    private static func layout(
        scale s: Int, frameWidthPx fw: Int, frameHeightPx fh: Int, visible v: (x0: Int, y0: Int, x1: Int, y1: Int)
    ) -> (artSize: ArtSize, cropX: Int, cropY: Int, visible: ArtRect) {
        let aw = ceilDiv(fw, s), ah = ceilDiv(fh, s)
        let cropX = aw * s - fw, cropY = ah * s - fh
        // Fully visible art pixels: [ceil(edge0 / S), floor(edge1 / S)) in canvas device px.
        let ax0 = ceilDiv(v.x0 + cropX / 2, s), ax1 = floorDiv(v.x1 + cropX / 2, s)
        let ay0 = ceilDiv(v.y0 + cropY / 2, s), ay1 = floorDiv(v.y1 + cropY / 2, s)
        return (ArtSize(aw, ah), cropX, cropY, ArtRect(ax0, ay0, max(0, ax1 - ax0), max(0, ay1 - ay0)))
    }

    // MARK: Conversions

    /// The canvas art pixel containing a device-pixel position (floor).
    public func artPoint(fromDevicePx p: SIMD2<Double>) -> ArtPoint {
        let s = Double(scale)
        return ArtPoint(
            Self.floorToInt((p.x + Double(cropLeft)) / s),
            Self.floorToInt((p.y + Double(cropTop)) / s)
        )
    }

    /// The canvas art pixel under a view point (y-down points; device px = points × backingScale).
    public func artPoint(fromViewPoint p: SIMD2<Double>) -> ArtPoint {
        artPoint(fromDevicePx: p * display.backingScale)
    }

    /// The device-pixel rect covered by canvas art rect `r` (may extend past the frame by the crop).
    public func deviceRect(forArt r: ArtRect) -> DeviceRect {
        DeviceRect(r.x * scale - cropLeft, r.y * scale - cropTop, r.w * scale, r.h * scale)
    }

    public func canvasPoint(fromCore p: ArtPoint) -> ArtPoint { p + coreOrigin }

    public func corePoint(fromCanvas p: ArtPoint) -> ArtPoint { p - coreOrigin }

    public func canvasRect(fromCore r: ArtRect) -> ArtRect { r.offsetBy(coreOrigin.x, coreOrigin.y) }

    // MARK: Integer helpers

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func ceilDiv(_ a: Int, _ b: Int) -> Int { -floorDiv(-a, b) }

    /// `a / b` rounded to nearest, halves away from zero (`b > 0`).
    static func roundHalfAwayDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? (2 * a + b) / (2 * b) : -((2 * -a + b) / (2 * b))
    }

    private static func floorToInt(_ v: Double) -> Int {
        guard v.isFinite else { return 0 }
        return Int(max(-1e15, min(1e15, v.rounded(.down))))
    }
}

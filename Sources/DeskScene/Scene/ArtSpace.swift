import CoreGraphics
import DeskCore
import SpriteKit

/// Conversions between canvas art space (integer px, y-down) and SpriteKit scene space (y-up, `U` units per
/// art px). The only place that flips y; every node placed through it uses `anchorPoint = .zero`.
public nonisolated struct ArtSpace: Hashable, Sendable {
    /// `U`: SpriteKit units per art pixel.
    public static let unitsPerPixel: CGFloat = 4

    /// The canvas in art px.
    public let canvas: ArtSize

    public init(canvas: ArtSize) {
        self.canvas = canvas
    }

    /// The scene size for this canvas (`canvas × U`).
    public var sceneSize: CGSize {
        CGSize(width: CGFloat(canvas.w) * Self.unitsPerPixel, height: CGFloat(canvas.h) * Self.unitsPerPixel)
    }

    /// The scene rect covering art rect `r`.
    public func sceneRect(_ r: ArtRect) -> CGRect {
        let u = Self.unitsPerPixel
        return CGRect(
            x: CGFloat(r.x) * u, y: CGFloat(canvas.h - r.maxY) * u,
            width: CGFloat(r.w) * u, height: CGFloat(r.h) * u
        )
    }

    /// The art rect covering scene rect `r`, with edges rounded to whole art px.
    public func artRect(_ r: CGRect) -> ArtRect {
        let u = Self.unitsPerPixel
        let x0 = Int((r.minX / u).rounded()), x1 = Int((r.maxX / u).rounded())
        let top = canvas.h - Int((r.maxY / u).rounded()), bottom = canvas.h - Int((r.minY / u).rounded())
        return ArtRect(x0, top, x1 - x0, bottom - top)
    }

    /// Scene point for a continuous art point.
    public func scenePoint(_ p: SIMD2<Float>) -> CGPoint {
        let u = Self.unitsPerPixel
        return CGPoint(x: CGFloat(p.x) * u, y: (CGFloat(canvas.h) - CGFloat(p.y)) * u)
    }

    /// Continuous art point for a scene point.
    public func artPoint(_ p: CGPoint) -> SIMD2<Float> {
        let u = Self.unitsPerPixel
        return SIMD2(Float(p.x / u), Float(CGFloat(canvas.h) - p.y / u))
    }

    /// Position of an `anchorPoint = .zero` node whose art top-left is `topLeft` and whose height is `height` px.
    public func position(topLeft: ArtPoint, height: Int) -> CGPoint {
        sceneRect(ArtRect(topLeft.x, topLeft.y, 0, height)).origin
    }

    /// `v` (scene units) snapped to a whole art pixel.
    public static func snap(_ v: CGFloat) -> CGFloat {
        (v / unitsPerPixel).rounded() * unitsPerPixel
    }

    /// `p` with both coordinates snapped to whole art pixels.
    public static func snap(_ p: CGPoint) -> CGPoint {
        CGPoint(x: snap(p.x), y: snap(p.y))
    }

    /// Continuous canvas art position of a view point (y-down points, as `PixelGrid.artPoint(fromViewPoint:)`
    /// takes them). Always inside the pixel that `grid.artPoint(fromViewPoint:)` returns.
    public static func canvasArtPoint(fromViewPoint p: SIMD2<Double>, grid: PixelGrid) -> SIMD2<Float> {
        let pixel = grid.artPoint(fromViewPoint: p)
        let s = Double(grid.scale)
        let exact = (p * grid.display.backingScale + SIMD2(Double(grid.cropLeft), Double(grid.cropTop))) / s
        func frac(_ v: Double, _ base: Int) -> Float {
            let f = v - Double(base)
            return f.isFinite ? Float(min(max(f, 0), 0.999)) : 0
        }
        return SIMD2(Float(pixel.x) + frac(exact.x, pixel.x), Float(pixel.y) + frac(exact.y, pixel.y))
    }
}

extension ArtSpace {
    /// Sizes and positions `node` (anchor `.zero`) to cover art rect `r`.
    @MainActor
    public func place(_ node: SKSpriteNode, at r: ArtRect) {
        let rect = sceneRect(r)
        node.anchorPoint = .zero
        node.size = rect.size
        node.position = rect.origin
    }
}

#if !canImport(Metal)
import DeskCore
import DeskStage

/// Where a presenter shows its frames on screen (docs/WINDOWS.md, WP2/WP6): a window's GDI or Direct3D surface.
@MainActor
public protocol PixelSurface: AnyObject {
    /// Shows `lit` (art size, RGBA, row 0 = top) so device pixel `p` is `lit[(p + crop) / scale]`; false when the
    /// surface could not show it (minimised, not ready).
    func present(lit: PixelBuffer, scale: Int, cropLeft: Int, cropTop: Int) -> Bool
}

/// The pixel pipeline without a GPU (DESIGN §1.1 on Windows): the scene flattened and drawn by `SoftRaster` (the
/// art frame), relit by `SoftPost.lit` (the lit frame, the canonical snapshot), then upscaled by the surface or by
/// `SoftPost.upscale` for snapshots. Same API as the Metal presenter where the scene code and the app use it.
public final class PixelPresenter {
    public private(set) var artSize: ArtSize
    /// Room light for the lit pass.
    public var ambient: AmbientLight = .identity
    /// Clear colour of the art pass (the scene's backdrop).
    public var clearColor: RGBA8 = .black
    /// The scene drawn and stepped.
    public var scene: SKScene?

    private var lightMask: [UInt8]
    private var artFrame: PixelBuffer
    private var litFrame: PixelBuffer
    private var lastTime: TimeInterval?

    public init(artSize: ArtSize) throws {
        guard artSize.w > 0, artSize.h > 0 else { throw RenderError.resource("\(artSize.w)x\(artSize.h) frame") }
        self.artSize = artSize
        lightMask = [UInt8](repeating: 0, count: artSize.area)
        artFrame = PixelBuffer(width: artSize.w, height: artSize.h)
        litFrame = PixelBuffer(width: artSize.w, height: artSize.h)
    }

    /// Reallocates the frames (and clears the light mask) when the canvas changes.
    public func resize(_ size: ArtSize) throws {
        guard size != artSize else { return }
        guard size.w > 0, size.h > 0 else { throw RenderError.resource("\(size.w)x\(size.h) frame") }
        artSize = size
        lightMask = [UInt8](repeating: 0, count: size.area)
        artFrame = PixelBuffer(width: size.w, height: size.h)
        litFrame = PixelBuffer(width: size.w, height: size.h)
    }

    /// Replaces the light mask: one byte per art px, row 0 = top (`LightMask`).
    public func setLightMask(_ mask: [UInt8]) throws {
        precondition(mask.count == artSize.area, "light mask must have one byte per art px")
        lightMask = mask
    }

    /// Advances the scene's physics to `time` and lets the scene react (`didSimulatePhysics`), as `SKRenderer`
    /// does: the first time only starts the clock.
    public func update(atTime time: TimeInterval) {
        guard let scene else { return }
        if let last = lastTime, time > last { scene.physicsWorld.step(time - last) }
        lastTime = time
        scene.didSimulatePhysics()
    }

    /// Draws the art and lit frames (synchronously; `wait` is for the Metal presenter's signature).
    public func renderOffscreen(wait: Bool = true) {
        guard let scene else {
            artFrame.fillAll(clearColor)
            SoftPost.lit(artFrame, mask: lightMask, ambientLevel: ambient.level, ambientTint: ambient.tint, into: &litFrame)
            return
        }
        SoftRaster.composite(SceneFlattener.items(scene), clear: clearColor, into: &artFrame)
        SoftPost.lit(artFrame, mask: lightMask, ambientLevel: ambient.level, ambientTint: ambient.tint, into: &litFrame)
    }

    /// Renders a frame and shows it on `surface`; false when the surface could not.
    @discardableResult
    public func present(to surface: any PixelSurface, params: UpscaleParams) -> Bool {
        renderOffscreen()
        let lit = SoftPost.shifted(litFrame, by: params.shake)
        return surface.present(lit: lit, scale: params.scale, cropLeft: params.cropLeft, cropTop: params.cropTop)
    }

    public func upscaledFrame(width: Int, height: Int, params: UpscaleParams) throws -> PixelBuffer {
        SoftPost.upscale(litFrame, width: width, height: height, scale: params.scale, cropLeft: params.cropLeft,
                         cropTop: params.cropTop, shake: params.shake)
    }

    public func readLitFrame() throws -> PixelBuffer { litFrame }

    public func readArtFrame() throws -> PixelBuffer { artFrame }
}
#endif

#if !canImport(Metal)
import DeskCore
import DeskStage
@testable import DeskScene

// Without Metal (Windows, Linux) the scene tests run on the software renderer (docs/WINDOWS.md, WP2): `GPU` and
// `MTLCreateSystemDefaultDevice()` stand for it, so the suites gated on a Metal device run unchanged and compare
// with the same goldens.

/// The software renderer's stand-in for a Metal device.
nonisolated struct SoftDevice: Sendable {}

nonisolated func MTLCreateSystemDefaultDevice() -> SoftDevice? { SoftDevice() }

extension SceneHost {
    convenience init(grid: PixelGrid, device: SoftDevice) throws {
        try self.init(grid: grid)
    }
}

extension PixelPresenter {
    convenience init(device: SoftDevice, artSize: ArtSize) throws {
        try self.init(artSize: artSize)
    }
}

/// `GPU` from `MetalTestSupport`, on `SoftPost` and `SoftRaster`.
struct GPU {
    let device = SoftDevice()

    init() throws {}

    func lit(_ art: PixelBuffer, ambient: AmbientLight, mask: [UInt8]? = nil) throws -> PixelBuffer {
        SoftPost.lit(art, mask: mask ?? [UInt8](repeating: 0, count: art.width * art.height),
                     ambientLevel: ambient.level, ambientTint: ambient.tint)
    }

    func upscale(_ lit: PixelBuffer, width: Int, height: Int, params: UpscaleParams) throws -> PixelBuffer {
        SoftPost.upscale(lit, width: width, height: height, scale: params.scale, cropLeft: params.cropLeft,
                         cropTop: params.cropTop, shake: params.shake)
    }

    /// Renders `nodes` in a bare scene of `size` art px; returns the raw art frame.
    func renderScene(size: ArtSize, backdrop: RGBA8 = Ink.neutral1.color, _ nodes: [SKNode]) throws -> PixelBuffer {
        let space = ArtSpace(canvas: size)
        let scene = SKScene(size: space.sceneSize)
        scene.anchorPoint = .zero
        scene.scaleMode = .fill
        for n in nodes { scene.addChild(n) }
        let presenter = try PixelPresenter(artSize: size)
        presenter.scene = scene
        presenter.clearColor = backdrop
        presenter.update(atTime: 0)
        presenter.renderOffscreen()
        return try presenter.readArtFrame()
    }
}
#endif

#if !canImport(AppKit)
import DeskCore
import DeskStage
@testable import DeskScene

// The AppKit pieces the loop tests attach to, as stand-ins: a view and a layer that only exist to be passed, and a
// ticker that ticks when a test says so. `isRunning`, `isTickingSlowly` and the pause logic are what they check.

struct NSRect {
    init(x: Int, y: Int, width: Int, height: Int) {}
}

final class NSView {
    init(frame: NSRect) {}
}

final class CAMetalLayer {
    init() {}
}

func CACurrentMediaTime() -> Double { FrameClock.now() }

/// A `FrameTicker` that never fires on its own.
final class ManualTicker: FrameTicker {
    var isPaused = true
    var lowPower = false
    var onTick: ((Double) -> Void)?
    func invalidate() { onTick = nil }
}

/// A `PixelSurface` that takes every frame and shows nothing.
final class NullSurface: PixelSurface {
    private(set) var frames = 0
    func present(lit: PixelBuffer, scale: Int, cropLeft: Int, cropTop: Int) -> Bool {
        frames += 1
        return true
    }
}

extension FrameLoop {
    func attach(to view: NSView) { attach(ticker: ManualTicker()) }
}

extension SceneHost {
    func attach(to view: NSView, layer: CAMetalLayer) { attach(surface: NullSurface(), ticker: ManualTicker()) }
}
#endif

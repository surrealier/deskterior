import AppKit
import DeskCore
import Metal
import QuartzCore

/// One display's scene stack: the `DeskScene`, its `PixelPresenter` and the `FrameLoop` that drives them.
/// Rebuilds for a new `PixelGrid`, routes input and decides what input does to the loop: pointer moves only
/// re-render when something changed; every other event counts as activity and wakes the loop.
public final class SceneHost: FrameLoopHost {
    public let presenter: PixelPresenter
    public let scene: DeskScene
    public let loop = FrameLoop()
    public private(set) var grid: PixelGrid
    /// Fixed steps taken.
    public private(set) var stepCount = 0
    /// Simulation time of the last step.
    public var simTime: Double { FrameClock.time(steps: stepCount) }
    /// Where frames are presented; nil when headless.
    public private(set) weak var layer: CAMetalLayer?
    /// Screen-shake offset in art px.
    public var shake = ArtPoint.zero

    public init(grid: PixelGrid, device: any MTLDevice) throws {
        self.grid = grid
        presenter = try PixelPresenter(device: device, artSize: grid.artSize)
        scene = DeskScene(grid: grid)
        presenter.scene = scene
        presenter.clearColor = scene.backdropColor
        presenter.update(atTime: 0)
        loop.host = self
    }

    /// Presents into `layer` and drives the loop from `view`'s display link.
    public func attach(to view: NSView, layer: CAMetalLayer) {
        self.layer = layer
        loop.attach(to: view)
    }

    /// Stops the display link; call before dropping the host.
    public func invalidate() {
        loop.invalidate()
        layer = nil
    }

    /// Adopts a new grid (display, scale or canvas change) and renders once.
    public func setGrid(_ newGrid: PixelGrid) throws {
        if newGrid != grid {
            try presenter.resize(newGrid.artSize)
            scene.configure(grid: newGrid)
            grid = newGrid
        }
        loop.renderOnce()
    }

    public func handle(_ event: InputEvent) {
        let changed = scene.handle(event)
        if event.kind == .move {
            if changed { loop.renderOnce() }
            return
        }
        loop.noteInput()
        loop.wake()
        if changed { loop.renderOnce() }
    }

    // MARK: FrameLoopHost

    public func frameLoopStep(_ dt: Double) {
        stepCount += 1
        scene.step(dt)
        presenter.update(atTime: simTime)
    }

    public func frameLoopRender() {
        guard let layer else { return }
        presenter.present(to: layer, params: UpscaleParams(grid: grid, shake: shake))
    }

    public var frameLoopNeedsFrames: Bool { scene.needsFrames }

    public func frameLoopForceRest() {
        scene.forceRest()
    }
}

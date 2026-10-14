import AppKit
import Foundation
import DeskCore
import Metal
import QuartzCore

/// One display's scene stack: the `DeskScene`, its `PixelPresenter` and the `FrameLoop` that drives them.
/// Rebuilds for a new `PixelGrid`, routes input and decides what input does to the loop: pointer moves only
/// re-render when something changed (the tooltip delay is a one-shot timer, not a running loop); every other
/// event counts as activity and wakes the loop.
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
    /// Screen-shake offset in art px (added to the scene's own bonk shake).
    public var shake = ArtPoint.zero
    private var inputTimer: Timer?

    public init(grid: PixelGrid, device: any MTLDevice) throws {
        self.grid = grid
        presenter = try PixelPresenter(device: device, artSize: grid.artSize)
        scene = DeskScene(grid: grid)
        scene.pointsPerArtPx = grid.pointsPerArtPx
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
        inputTimer?.invalidate()
        inputTimer = nil
        loop.invalidate()
        layer = nil
    }

    /// Adopts a new grid (display, scale or canvas change) and renders once.
    public func setGrid(_ newGrid: PixelGrid) throws {
        if newGrid != grid {
            try presenter.resize(newGrid.artSize)
            scene.configure(grid: newGrid)
            scene.pointsPerArtPx = newGrid.pointsPerArtPx
            grid = newGrid
        }
        loop.renderOnce()
    }

    public func handle(_ event: InputEvent) {
        let changed = scene.handle(event)
        scheduleInputTimer()
        if event.kind == .move {
            // Hovering may start something bounded (the AV logo's bounce); otherwise one frame at most.
            if scene.needsFrames { loop.wake() } else if changed { loop.renderOnce() }
            // MARK: harden: a slow-ticking loop (only the AV logo moves) shows a hover change now, not a tick later.
            if changed, loop.isTickingSlowly { loop.renderOnce() }
            return
        }
        loop.noteInput()
        loop.wake()
        if changed { loop.renderOnce() }
    }

    /// Routes a keyboard command (keys count as activity).
    public func handleKey(_ command: KeyCommand) {
        let changed = scene.handleKey(command)
        loop.noteInput()
        if scene.needsFrames { loop.wake() } else if changed { loop.renderOnce() }
        if changed, loop.isTickingSlowly { loop.renderOnce() }  // MARK: harden: as for a hover change
    }

    /// Drops a press or drag in progress (focus went elsewhere): a carry springs home.
    public func cancelInput() {
        guard scene.isDragging || scene.isPressing else { return }
        scene.cancelInput()
        modelChanged()
    }

    /// After a model change: run the loop if something now animates, else render one frame.
    public func modelChanged() {
        if scene.needsFrames {
            loop.wake()
            if loop.isTickingSlowly { loop.renderOnce() }  // MARK: harden: shown now, not at the next slow tick
        } else {
            loop.renderOnce()
        }
    }

    /// A one-shot timer for the router's next deadline (the tooltip), in event time (seconds since boot).
    private func scheduleInputTimer() {
        inputTimer?.invalidate()
        inputTimer = nil
        guard let due = scene.nextInputDeadline else { return }
        let delay = max(0, due - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inputTimer = nil
                if self.scene.advanceInput(to: due) { self.loop.renderOnce() }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        inputTimer = timer
    }

    // MARK: FrameLoopHost

    public func frameLoopStep(_ dt: Double) {
        stepCount += 1
        scene.step(dt)
        presenter.update(atTime: simTime)
    }

    public func frameLoopRender() {
        renders += 1  // MARK: harden
        guard let layer else { return }
        presenter.present(to: layer, params: UpscaleParams(grid: grid, shake: shake + scene.shake))
    }

    public var frameLoopNeedsFrames: Bool { scene.needsFrames }

    public var frameLoopScriptedAnimating: Bool { scene.scriptedAnimating }

    // MARK: harden
    public var frameLoopSlowFrameInterval: Double? { scene.slowFrameInterval }
    /// Frames rendered, or asked for while headless (tests).
    private(set) var renders = 0

    public func frameLoopForceRest() {
        scene.forceRest()
    }
}

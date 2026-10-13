import DeskCore

/// Steps a `SceneHost` by whole fixed frames and renders offscreen, with no window or display link
/// (`--headless`, tests). Deterministic: frame `n` always sees `simTime = n / 60`.
public final class OffscreenDriver {
    public let host: SceneHost

    public init(host: SceneHost) {
        self.host = host
    }

    /// Steps and renders `frames` frames (art and lit passes), waiting for each; with 0 frames, renders the
    /// current state once.
    public func run(frames: Int) {
        for _ in 0..<max(0, frames) {
            host.frameLoopStep(FrameClock.step)
            host.presenter.renderOffscreen(wait: true)
        }
        if frames <= 0 { host.presenter.renderOffscreen(wait: true) }
    }

    /// The last lit frame at art resolution (the canonical snapshot).
    public func snapshot() throws -> PixelBuffer {
        try host.presenter.readLitFrame()
    }

    /// The last frame as the display would show it: upscaled to the frame's device pixels, crop applied.
    public func deviceFrame() throws -> PixelBuffer {
        let d = host.grid.display
        return try host.presenter.upscaledFrame(
            width: d.frameWidthPx, height: d.frameHeightPx, params: UpscaleParams(grid: host.grid, shake: host.shake)
        )
    }
}

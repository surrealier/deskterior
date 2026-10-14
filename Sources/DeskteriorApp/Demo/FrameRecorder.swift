import DeskCore
import DeskFiles
import DeskPixels
import DeskScene
import Foundation

/// Writes every `every`-th scene frame of a demo as `frame-NNNNN.png` at art resolution, with the demo's pointer
/// drawn in (`DemoCursorArt`): `--demo-record DIR`, `--demo-record-every N` (`scripts/make-gif.sh` turns them into the
/// README's GIF). Only frames the runner steps are written; real-time waits for the mirror and icons take none, so the
/// frames play back at 60 / `every` fps of scene time. A script's `record` steps start and stop it.
final class FrameRecorder {
    let writer: ArtifactWriter
    let every: Int
    /// Writing frames now.
    var isOn: Bool
    private var stepped = 0
    /// Frames written so far.
    private(set) var written = 0
    /// The pointer's tip in canvas px; nil until the script first points somewhere.
    private var tip: ArtPoint?
    private var pressed = false
    /// Scene frames since the last press (for the click ring).
    private var sincePress: Int?

    init(writer: ArtifactWriter, every: Int, isOn: Bool) {
        self.writer = writer
        self.every = max(1, every)
        self.isOn = isOn
    }

    /// Follows an input event the runner sends: where the pointer is and whether a button is down. A right-click
    /// counts as a click (its menu is the system's and is not drawn).
    func pointerEvent(_ kind: InputEvent.Kind, at p: SIMD2<Float>) {
        guard kind != .key else { return }
        tip = ArtPoint(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
        switch kind {
        case .down:
            pressed = true
            sincePress = 0
        case .rightDown:
            pressed = false
            sincePress = 0
        case .up:
            pressed = false
        default:
            break
        }
    }

    /// After each scene frame: renders and writes it when one is due.
    func frameStepped(_ host: SceneHost) throws {
        if let n = sincePress { sincePress = n + 1 }
        guard isOn else { return }
        defer { stepped += 1 }
        guard stepped % every == 0 else { return }
        host.presenter.renderOffscreen(wait: true)
        var frame = try host.presenter.readLitFrame()
        if let tip { DemoCursorArt.stamp(into: &frame, tip: tip, pressed: pressed, sincePress: sincePress) }
        written += 1
        try writer.write(PNGCodec.encode(frame), named: String(format: "frame-%05d.png", written))
    }
}

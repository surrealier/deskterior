import DeskCore
import Foundation
import Metal
@testable import DeskScene

/// A desk scene whose actions run through the reducer (with the undo journal) and come straight back, as the app's
/// `Store` does. With a Metal device the frames go through a `SceneHost`, so SpriteKit steps the desk-plane physics
/// (`didSimulatePhysics`); without one, `frames` only step the scene (flights, machines; bodies stand still).
@MainActor
final class PhysicsStage {
    let scene: DeskScene
    let host: SceneHost?
    var state: DeskState
    var journal = UndoJournal()
    var actions: [DeskAction] = []
    var requests: [SceneRequest] = []
    var t: Double = 100

    init(_ state: DeskState, physics: Bool) throws {
        if physics {
            guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
            let host = try SceneHost(grid: PixelGrid(display: calibrationDisplay), device: device)
            self.host = host
            scene = host.scene
        } else {
            host = nil
            scene = DeskScene(grid: PixelGrid(display: calibrationDisplay))
        }
        self.state = state
        scene.clock = .fixed(WallTime(hour: 10, minute: 0))
        scene.onAction = { [unowned self] in dispatch($0) }
        scene.onRequest = { [unowned self] in requests.append($0) }
        scene.apply(state)
    }

    var hub: PhysicsHub { scene.room!.context.physics! }
    var layout: SceneLayout { scene.layout! }

    func dispatch(_ a: DeskAction) {
        actions.append(a)
        let before = state
        let effects = Reducer.reduce(&state, journal: &journal, a, ReduceEnv(now: SceneFixture.t0))
        if state != before { scene.apply(state) }
        for case let .play(id, target) in effects { scene.play(id, target) }
    }

    /// Fixed frames (with the physics when there is a host).
    func frames(_ n: Int) {
        for _ in 0..<n {
            t += 1.0 / 60
            if let host { host.frameLoopStep(FrameClock.step) } else { scene.step(FrameClock.step) }
            scene.advanceInput(to: t)
        }
    }

    /// Frames until nothing moves (at most `limit`).
    func settle(limit: Int = 1200) {
        var n = 0
        while scene.needsFrames && n < limit {
            frames(1)
            n += 1
        }
    }

    @discardableResult
    func event(_ kind: InputEvent.Kind, _ p: SIMD2<Float>, count: Int = 0, mods: InputEvent.Modifiers = []) -> Bool {
        scene.handle(InputEvent(kind, art: p, mods: mods, clickCount: count, t: t))
    }

    func click(_ p: SIMD2<Float>, count: Int = 1) {
        event(.move, p)
        for n in 1...count {
            event(.down, p, count: n)
            frames(1)
            event(.up, p, count: n)
            frames(1)
        }
    }

    /// Press at `from`, one move per frame to `to` over `steps` frames, then (unless `hold`) let go there; a
    /// `pause` of frames before letting go makes it a gentle drop (no hand velocity).
    func drag(_ from: SIMD2<Float>, _ to: SIMD2<Float>, steps: Int = 10, pause: Int = 0, hold: Bool = false) {
        event(.move, from)
        event(.down, from, count: 1)
        frames(1)
        for k in 1...steps {
            event(.drag, from + (to - from) * Float(k) / Float(steps))
            frames(1)
        }
        if pause > 0 { frames(pause) }
        if !hold {
            event(.up, to, count: 1)
            frames(1)
        }
    }

    /// The canvas point (pixel centre) of a core point.
    func point(core x: Int, _ y: Int) -> SIMD2<Float> {
        let p = layout.point(ArtPoint(x, y))
        return SIMD2(Float(p.x) + 0.5, Float(p.y) + 0.5)
    }

    func centre(_ r: ArtRect) -> SIMD2<Float> { SceneFixture.centre(r) }

    /// The token's icon centre wherever it is on show (screen, pile, floor).
    func tokenPoint(_ key: TokenKey) -> SIMD2<Float>? {
        (scene.screen?.iconRect(of: key) ?? scene.deskTokenRect(key)).map(centre)
    }

    func location(_ key: TokenKey) -> Location? { state.tokens.location(of: key) }
}

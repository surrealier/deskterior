import DeskCore
import Foundation
import Testing
@testable import DeskScene

/// E13 (M10): dragging the clock's minute hand previews another time (phase, sky, window, light follow live) and the
/// hands spring back over 0.5 s on release (at once with Reduce Motion).
@Suite("Wall clock preview")
struct ClockTests {
    typealias F = SceneFixture

    /// The canvas point at `minute` on the clock face, `radius` px from the pivot.
    static func face(_ scene: DeskScene, minute: Double, radius: Double = 9) -> SIMD2<Float> {
        let r = scene.layout!.rect(CoreLayout.clock)
        let a = minute / 60 * 2 * .pi
        return SIMD2(Float(Double(r.x) + 14 + sin(a) * radius), Float(Double(r.y) + 14 - cos(a) * radius))
    }

    static func shown(_ scene: DeskScene) -> WallTime? { scene.roomState?.time }

    @Test("Dragging the minute hand from :50 to :10 previews 20 minutes on: dusk turns to night, the room relights")
    func preview() throws {
        let store = SceneStore(F.state(), time: WallTime(hour: 18, minute: 50))
        let scene = store.scene
        let p = Pointer(scene: scene)
        #expect(scene.roomState?.timeOfDay.phase == .dusk && scene.roomState?.sky == .dusk)
        let dusk = scene.lighting
        p.drag(Self.face(scene, minute: 50), Self.face(scene, minute: 10), steps: 20, hold: true)
        let t = try #require(Self.shown(scene))
        #expect(t.hour == 19 && t.minute == 10)
        #expect(scene.roomState?.timeOfDay.phase == .night && scene.roomState?.sky == .night)
        #expect(scene.roomState?.timeOfDay.ambientLevel == 6 && scene.lighting.ambient.tint == .warm)
        #expect(scene.lighting.ambient != dusk.ambient)
        #expect(scene.lightOverrides?.previewTime == t)
        #expect(store.actions.isEmpty, "a preview never touches the model")
        // The real time is untouched underneath.
        #expect(scene.lightOverrides?.clockTime == WallTime(hour: 18, minute: 50))
    }

    @Test("On release the hands spring back over 0.5 s, swinging a little past the real time")
    func springBack() throws {
        let scene = SceneStore(F.state(), time: WallTime(hour: 18, minute: 50)).scene
        let p = Pointer(scene: scene)
        p.drag(Self.face(scene, minute: 50), Self.face(scene, minute: 10), steps: 20)
        var minutes: [Int] = []
        for _ in 0..<40 {
            p.frames(1)
            if let t = Self.shown(scene) { minutes.append(t.hour * 60 + t.minute - (18 * 60 + 50)) }
        }
        #expect(minutes.first.map { $0 > 0 && $0 < 20 } == true, "already on its way back: \(minutes)")
        #expect(minutes.contains { $0 < 0 }, "overshoots the real time: \(minutes)")
        #expect(minutes.last == 0 && scene.lightOverrides?.previewTime == nil)
        // Back to dusk, and nothing left running.
        #expect(scene.roomState?.timeOfDay.phase == .dusk && !scene.needsFrames)
        // Settled within 0.5 s (30 frames).
        #expect(minutes.dropFirst(30).allSatisfy { $0 == 0 })
    }

    @Test("Going round counts hours (1½ turns = 90 minutes), backwards too")
    func turns() throws {
        let scene = SceneStore(F.state(), time: WallTime(hour: 10, minute: 0)).scene
        let p = Pointer(scene: scene)
        let start = Self.face(scene, minute: 0)
        _ = p.event(.move, start)
        _ = p.event(.down, start, count: 1)
        for k in 1...90 { _ = p.event(.drag, Self.face(scene, minute: Double(k))) }
        #expect(Self.shown(scene) == WallTime(hour: 11, minute: 30))
        for k in stride(from: 89, through: -30, by: -1) { _ = p.event(.drag, Self.face(scene, minute: Double(k))) }
        #expect(Self.shown(scene) == WallTime(hour: 9, minute: 30))
        _ = p.event(.up, Self.face(scene, minute: -30), count: 1)
    }

    @Test("Reduce Motion: the hands jump back on release")
    func reduceMotion() {
        let scene = SceneStore(F.state(), time: WallTime(hour: 18, minute: 50)).scene
        scene.reduceMotion = true
        let p = Pointer(scene: scene)
        p.drag(Self.face(scene, minute: 50), Self.face(scene, minute: 10), steps: 20)
        #expect(Self.shown(scene) == WallTime(hour: 18, minute: 50) && scene.lightOverrides?.previewTime == nil)
        #expect(!scene.needsFrames)
    }

    @Test("A forced phase stays put: in Lamp Only the preview turns only the hands")
    func forcedPhase() {
        var s = F.state()
        s.lights = .lampOnly
        let scene = SceneStore(s, time: WallTime(hour: 10, minute: 0)).scene
        scene.lightsMode = .lampOnly
        let p = Pointer(scene: scene)
        p.drag(Self.face(scene, minute: 0), Self.face(scene, minute: 20), steps: 20, hold: true)
        #expect(Self.shown(scene) == WallTime(hour: 10, minute: 20))
        #expect(scene.roomState?.timeOfDay.phase == .night && scene.roomState?.timeOfDay.ambientLevel == 1)
    }

    @Test("Clicking the clock does nothing; its tooltip tells the time shown")
    func tooltip() {
        let store = SceneStore(F.state(), time: WallTime(hour: 7, minute: 5))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let c = F.centre(scene.layout!.rect(CoreLayout.clock))
        p.click(c)
        #expect(store.actions.isEmpty && scene.lightOverrides?.previewTime == nil)
        _ = p.event(.move, c + SIMD2(1, 0))
        p.frames(20)
        #expect(scene.tooltipShown?.title == "Clock" && scene.tooltipShown?.detail == "07:05")
    }
}

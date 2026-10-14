import AppKit
import DeskCore
import Foundation
import Metal
import QuartzCore
import Testing
@testable import DeskScene

/// A frame-loop host around a real `MonitorMachine` on AV: each render notes whether the logo's picture changed
/// since the last one (a move, a sparkle frame, the sparkle's end).
final class LogoLoopHost: FrameLoopHost {
    var machine: MonitorMachine
    private var shown: (ArtPoint, Int?)
    /// Picture changes seen by each render.
    private(set) var changesPerRender: [Int] = []
    private var pending = 0

    init(_ s: DeskState) {
        machine = MonitorMachine(s)
        shown = (machine.logo.position, machine.logo.sparkleFrame)
    }

    func frameLoopStep(_ dt: Double) {
        machine.step(dt)
        let now = (machine.logo.position, machine.logo.sparkleFrame)
        if now != shown { pending += 1 }
        shown = now
    }

    func frameLoopRender() {
        changesPerRender.append(pending)
        pending = 0
    }

    var frameLoopNeedsFrames: Bool { machine.needsFrames }
    var frameLoopScriptedAnimating: Bool { machine.needsFrames }
    func frameLoopForceRest() { machine.settle() }
    var frameLoopSlowFrameInterval: Double? { machine.logoFrameInterval() }
}

/// The wave-6 review (Errata 25): slow ticks land on the AV logo's own frames, a model change shows at once while the
/// loop ticks slowly, and Reduce Motion holds the wastebasket, the pen cup and the AV logo still.
@Suite("Perf and motion hardening after review (wave 6)")
@MainActor
struct HardeningReviewSceneTests {
    typealias F = SceneFixture

    // MARK: Slow ticks on the logo's frames

    @Test("Each slow tick shows exactly one change of the AV logo, however late its timer (0–5 ms, or a stall)")
    func oneChangePerSlowTick() {
        var s = F.state()
        s.monitor.av = true
        let host = LogoLoopHost(s)
        let loop = FrameLoop()
        loop.host = host
        defer { loop.invalidate() }
        var rng = SplitMix64(seed: 7)
        var now = 50.0
        var ticks = 0
        while host.machine.needsFrames, ticks < 400 {
            loop.slowTick(at: now)
            ticks += 1
            let due = FrameClock.step * Double(FrameClock.steps(covering: host.frameLoopSlowFrameInterval ?? 0))
            let late = ticks % 25 == 0 ? 0.3 : Double(rng.next() % 5_000) / 1_000_000  // a stall now and then
            now += due + late
        }
        #expect(!host.machine.needsFrames, "the bounce ended (10 s of simulation)")
        let changes = host.changesPerRender
        #expect(changes.count == ticks && ticks > 70)
        #expect(changes.dropLast().allSatisfy { $0 == 1 }, "never 0 or 2 changes in one tick: \(changes)")
    }

    @Test("A model change while the loop ticks slowly is shown at once, not at the next slow tick")
    func modelChangeRendersNow() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let host = try SceneHost(grid: PixelGrid(display: DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2,
                                                                          topInsetPt: 33)), device: device)
        defer { host.invalidate() }
        host.scene.setContent(.room)
        var s = F.state()
        s.monitor.av = true
        host.scene.apply(s)
        #expect(host.scene.slowFrameInterval != nil)
        host.loop.slowTick(at: CACurrentMediaTime())
        #expect(host.loop.isTickingSlowly)
        let before = host.renders
        s.lights = LightsState(mode: .night, room: false, lamp: true)  // starts no animation of its own
        host.scene.apply(s)
        host.modelChanged()
        #expect(host.renders == before + 1, "rendered now")
        #expect(host.loop.isTickingSlowly, "and the slow pace holds")
    }

    // MARK: Reduce Motion

    @Test("With Reduce Motion a bonk, a rim hit or a click leaves the wastebasket still: no shake, no jiggle")
    func reduceMotionBasket() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        stage.scene.reduceMotion = true
        let basket = stage.hub.basket
        basket.bonked()
        #expect(!basket.needsFrames && basket.machine.jiggle == 0)
        basket.rimHit(at: [Float(CoreLayout.wastebasketMouth.minX), Float(CoreLayout.wastebasketMouth.minY)])
        #expect(!basket.needsFrames)
        stage.click(stage.centre(basket.bounds))
        #expect(!basket.needsFrames && basket.machine.jiggle == 0)
        stage.scene.reduceMotion = false
        basket.bonked()
        #expect(basket.needsFrames && basket.machine.jiggle > 0, "without Reduce Motion it shakes and jiggles")
    }

    @Test("With Reduce Motion a click or a bonk leaves the pen cup upright and still")
    func reduceMotionCup() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        stage.scene.reduceMotion = true
        let cup = stage.hub.cup
        stage.click(stage.centre(cup.bounds))
        #expect(!cup.machine.needsFrames && cup.machine.lean == 0)
        cup.bonked()
        #expect(!cup.machine.needsFrames && cup.machine.isUpright)
        stage.scene.reduceMotion = false
        stage.click(stage.centre(cup.bounds))
        #expect(cup.machine.needsFrames, "without Reduce Motion a click wobbles it")
    }

    @Test("With Reduce Motion the AV logo holds still: no bounce, no frames; hovering does not start it")
    func reduceMotionLogo() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        scene.reduceMotion = true
        store.dispatch(.selectAV)
        let p = Pointer(scene: scene)
        p.frames(70)  // static and the OSD
        let monitor = try #require(scene.room?.monitor)
        let start = try #require(monitor.machine?.logo.position)
        #expect(!scene.needsFrames && scene.slowFrameInterval == nil, "nothing moves: the loop can rest")
        let glass = F.centre(try #require(scene.layout).rect(CoreLayout.screen))
        let away = F.centre(try #require(scene.layout).rect(CoreLayout.wastebasket))
        p.event(.move, glass)
        p.frames(30)
        #expect(monitor.machine?.logo.position == start && !scene.needsFrames)
        scene.reduceMotion = false
        p.event(.move, away)
        p.event(.move, glass)
        #expect(scene.needsFrames, "Reduce Motion off: hovering the glass bounces it again")
        p.frames(20)
        #expect(monitor.machine?.logo.position != start)
        scene.reduceMotion = true
        p.frames(1)
        #expect(!scene.needsFrames && monitor.machine?.logoStill == true, "turned on mid-bounce: it stops")
    }
}

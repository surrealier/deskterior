import AppKit
import DeskCore
import Foundation
import Metal
import QuartzCore
import Testing
@testable import DeskScene

/// A frame-loop host that steps a counter and says how slowly it may tick.
final class SlowLoopHost: FrameLoopHost {
    var needsFrames = true
    var slowInterval: Double? = 8.0 / 60
    var steps = 0
    var renders = 0
    func frameLoopStep(_ dt: Double) { steps += 1 }
    func frameLoopRender() { renders += 1 }
    var frameLoopNeedsFrames: Bool { needsFrames }
    var frameLoopScriptedAnimating: Bool { needsFrames }
    func frameLoopForceRest() { needsFrames = false }
    var frameLoopSlowFrameInterval: Double? { slowInterval }
}

/// Pre-release perf and motion fixes (wave 6, Errata 25): the AV logo ticks the loop at its own 8 fps, Reduce Motion
/// sets tosses down without a flight and stills knocks and spring-backs, and a carry resting on INPUT turns the page.
@Suite("Perf and motion hardening (wave 6)")
@MainActor
struct HardeningSceneTests {
    typealias F = SceneFixture

    // MARK: The AV logo's own rate

    @Test("A slow tick takes exactly the steps up to the next change, however late its timer, and renders once")
    func slowTickSteps() {
        let loop = FrameLoop()
        let host = SlowLoopHost()
        loop.host = host
        defer { loop.invalidate() }
        loop.slowTick(at: 10)
        #expect(host.steps == 8 && host.renders == 1, "the host's next change is 8 steps away")
        loop.slowTick(at: 10 + 0.137)
        #expect(host.steps == 16 && host.renders == 2, "12 ms late: still 8 steps, never 9")
        host.slowInterval = 7.0 / 60
        loop.slowTick(at: 10 + 0.25)
        #expect(host.steps == 23 && loop.isTickingSlowly)
        loop.slowTick(at: 100)
        #expect(host.steps == 30, "a long stall is never queued: one change's worth")
        host.needsFrames = false
        loop.slowTick(at: 100.125)
        #expect(!loop.isTickingSlowly, "nothing moves: no next tick")
        #expect(loop.slowTicks == 5)
        #expect(FrameClock.steps(covering: 0.125) == 8 && FrameClock.steps(covering: 7.0 / 60) == 7)
        #expect(FrameClock.steps(covering: 0) == 1)
    }

    @Test("While ticking slowly, a wake keeps the slow pace; once something faster runs, the link takes over")
    func slowWake() {
        let loop = FrameLoop()
        let host = SlowLoopHost()
        loop.host = host
        loop.attach(to: NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8)))
        defer { loop.invalidate() }
        loop.slowTick(at: CACurrentMediaTime())
        #expect(loop.isTickingSlowly && !loop.isRunning)
        loop.wake()
        #expect(loop.isTickingSlowly && !loop.isRunning, "only the logo moves: the slow pace holds")
        host.slowInterval = nil
        loop.wake()
        #expect(!loop.isTickingSlowly && loop.isRunning)
        loop.setPaused(.occluded, true)
        #expect(!loop.isTickingSlowly && !loop.isRunning)
    }

    @Test("Pausing stops slow ticks; a slow tick never runs while paused")
    func slowPause() {
        let loop = FrameLoop()
        let host = SlowLoopHost()
        loop.host = host
        defer { loop.invalidate() }
        loop.slowTick(at: 1)
        #expect(loop.isTickingSlowly)
        loop.setPaused(.screensAsleep, true)
        #expect(!loop.isTickingSlowly)
        loop.slowTick(at: 2)
        #expect(host.renders == 1)
    }

    @Test("The AV logo alone lets the loop tick at 8 fps (12 while it sparkles); anything else needs 60")
    func logoInterval() throws {
        var s = F.state()
        s.monitor.av = true
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let logoFrame = { (scene.slowFrameInterval ?? 0) > 0 && (scene.slowFrameInterval ?? 1) <= 8.0 / 60 + 1e-9 }
        #expect(scene.needsFrames)
        #expect(scene.slowFrameInterval == 8.0 / 60, "a desk that starts on AV bounces its logo: its first move")
        store.dispatch(.cycleInput)  // HDMI 1: static and the OSD need every frame.
        store.dispatch(.selectAV)
        #expect(scene.needsFrames && scene.slowFrameInterval == nil)
        p.frames(70)  // the OSD's second is over; the logo bounces on
        #expect(scene.needsFrames && logoFrame())
        scene.toast(.containerFull)
        #expect(scene.slowFrameInterval == nil, "a toast slides at 60 Hz")
        p.frames(Int((ToastView.hold + 2 * ToastView.slide) * 60) + 2)
        #expect(logoFrame())
        p.frames(Int(MonitorMachine.avBounceLimit * 60))
        #expect(!scene.needsFrames && scene.slowFrameInterval == nil, "after 10 s it holds still: rest")
    }

    @Test("The machine reports the logo's rate only while it is all that animates")
    func machineInterval() {
        var s = F.state()
        s.monitor.av = true
        var m = MonitorMachine(s)
        #expect(m.logoFrameInterval() == 8.0 / 60, "7.5 steps to the first move: on the 8th")
        s.monitor.av = false
        m.sync(s)
        s.monitor.av = true
        m.sync(s)
        #expect(m.logoFrameInterval() == nil, "static and the OSD")
        for _ in 0..<70 { m.step(1.0 / 60) }
        #expect(m.logoFrameInterval() != nil)
        m.settle()
        #expect(m.logoFrameInterval() == nil)
        s.monitor.power = .off
        m.sync(s)
        #expect(m.logoFrameInterval() == nil)
    }

    // MARK: Reduce Motion

    @Test("With Reduce Motion a fling off the desk is set down at once where its arc would land: no flight drawn")
    func reduceMotionToss() throws {
        let plain = try PhysicsStage(F.state(), physics: false)
        let reduced = try PhysicsStage(F.state(), physics: false)
        reduced.scene.reduceMotion = true
        for stage in [plain, reduced] {
            let from = try #require(stage.tokenPoint(F.key(2)))
            stage.drag(from, stage.point(core: 300, 262), steps: 4)
        }
        #expect(plain.hub.tosses.flights.count == 1)
        let drawn = reduced.hub.tosses.flights.filter { !$0.node.isHidden }
        #expect(drawn.isEmpty, "never drawn")
        plain.frames(2)
        reduced.frames(2)
        #expect(plain.hub.tosses.flights.count == 1, "still in the air")
        #expect(reduced.hub.tosses.flights.isEmpty, "set down (and hopped onto the floor line) in two steps")
        plain.settle()
        reduced.settle()
        guard case let .floor(a)? = plain.location(F.key(2)), case let .floor(b)? = reduced.location(F.key(2)) else {
            let where0 = String(describing: plain.location(F.key(2)))
            let where1 = String(describing: reduced.location(F.key(2)))
            Issue.record("both land on the floor: \(where0), \(where1)")
            return
        }
        #expect(abs(a - b) <= 24, "the same arc's landing: \(a) vs \(b)")
        #expect(reduced.journal.undoLabel == "Move" && reduced.scene.screen?.carried.isEmpty == true)
    }

    @Test("With Reduce Motion a carry let go over nothing is home at once (no spring-back flight)")
    func reduceMotionSpringBack() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        stage.scene.reduceMotion = true
        let from = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(from, stage.point(core: 460, 100), steps: 12, pause: 6)
        #expect(!stage.scene.needsFrames, "nothing left to animate")
        #expect(stage.location(F.key(1))?.isScreen == true && stage.scene.screen?.carried.isEmpty == true)
    }

    @Test("With Reduce Motion a knock hops and wobbles nothing; an ajar drawer still shuts")
    func reduceMotionKnock() throws {
        var s = F.state()
        s.tokens.move(F.key(1), to: .desk(pile: "P1", order: 0))
        s.piles["P1"] = [150, 30]
        s.drawers[.riserLeft] = DrawerState(p: 2)
        let stage = try PhysicsStage(s, physics: false)
        stage.scene.reduceMotion = true
        let pile = try #require(stage.scene.deskTokenRect(F.key(1)))
        stage.click(stage.point(core: 120, 238), count: 2)
        #expect(stage.hub.knocks == 1 && !stage.hub.cup.machine.needsFrames, "the cup does not wobble")
        for _ in 0..<30 {
            stage.frames(1)
            #expect(stage.scene.deskTokenRect(F.key(1)) == pile, "the pile does not hop")
        }
        stage.settle()
        #expect(stage.state.drawerOpening(.riserLeft) == 0)
        let plan = DeskKnock.plan(for: s, origin: [120, 0], seed: 1)
        #expect(!plan.pileHops.isEmpty && !plan.wobbles.isEmpty && plan.clothRipple)
        let still = plan.stilled
        #expect(still.pileHops.isEmpty && still.floorHops.isEmpty && still.wobbles.isEmpty && !still.clothRipple)
        #expect(still.drawerJostle.isEmpty && !still.basketJiggle && still.frames == 0)
        #expect(still.drawerCloses == plan.drawerCloses)
        #expect("\(DeskKnock.actions(still, state: s))" == "\(DeskKnock.actions(plan, state: s))")
    }

    // MARK: INPUT spring-loading

    @Test("INPUT under a carry turns to the next HDMI page every 0.6 s, wrapping, never to AV")
    func inputSpringLoads() throws {
        let store = SceneStore(F.state(F.names + (0..<80).map { "extra \($0).txt" }))  // three pages
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let input = try #require(scene.layout).rect(CoreLayout.input)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(1)))), F.centre(input), hold: true)
        p.frames(30)
        #expect(store.actions.isEmpty)
        p.frames(8)
        #expect(store.actions == ["setPage(1)"] && scene.isDragging)
        p.frames(38)
        #expect(store.actions == ["setPage(1)", "setPage(2)"])
        p.frames(38)
        #expect(store.actions == ["setPage(1)", "setPage(2)", "setPage(0)"], "wraps to HDMI 1, skipping AV")
        #expect(scene.handleKey(.escape) && !scene.isDragging)
        var s = F.state()
        #expect(MonitorMachine.springInputPage(s) == nil, "one page: nowhere to turn")
        s.monitor.av = true
        #expect(MonitorMachine.springInputPage(s) == 0)
    }
}

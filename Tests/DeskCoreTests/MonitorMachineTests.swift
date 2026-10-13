import Testing
@testable import DeskCore

@Suite("MonitorMachine")
struct MonitorMachineTests {
    typealias F = ModelFixture

    /// Steps `m` for `seconds` at 60 Hz.
    func run(_ m: inout MonitorMachine, _ seconds: Double) {
        _ = run(&m, seconds) { _ in 0 }
    }

    /// Steps `m` for `seconds` at 60 Hz, recording what `probe` reports each frame.
    func run<T>(_ m: inout MonitorMachine, _ seconds: Double, _ probe: (MonitorMachine) -> T) -> [T] {
        var out: [T] = []
        for _ in 0..<Int((seconds * 60).rounded()) {
            m.step(1.0 / 60)
            out.append(probe(m))
        }
        return out
    }

    @Test("Overlay follows access, tokens and AV")
    func overlays() {
        var s = DeskState()
        #expect(ScreenOverlay.of(s) == .connectPrompt)
        s.access = .finderHidden
        #expect(ScreenOverlay.of(s) == .desktopHidden)
        s.access = .denied
        #expect(ScreenOverlay.of(s) == .noAccess)
        s.access = .connecting
        #expect(ScreenOverlay.of(s) == .connecting)
        s = F.mirrored(["a"])
        s.access = .connecting
        #expect(ScreenOverlay.of(s) == .none)
        s.access = .connected
        s.monitor.av = true
        #expect(ScreenOverlay.of(s) == .av)
    }

    @Test("Power off: six CRT frames in 0.5 s, then black; bounded and at rest")
    func powerOff() {
        var s = F.mirrored(["a", "b"])
        var m = MonitorMachine(s)
        #expect(m.phase == .on && !m.needsFrames && m.showsTokens && m.rowsShown == 5 && m.led == .on)
        s.monitor.power = .off
        m.sync(s)
        #expect(m.phase == .poweringOff && m.crtFrame == .off(0) && !m.showsTokens)
        let frames = run(&m, 0.7) { $0.crtFrame }
        let offFrames = frames.compactMap { f -> Int? in if case let .off(i)? = f { i } else { nil } }
        #expect(Set(offFrames) == Set(0..<MonitorMachine.powerOffFrameCount))
        #expect(offFrames == offFrames.sorted())
        #expect(m.phase == .off && m.crtFrame == nil && !m.needsFrames && m.led == .off && m.badge == nil)
        #expect(MonitorMachine.powerOffDuration <= 0.7 && MonitorMachine.bloomDuration <= 0.7)
    }

    @Test("Power on: the bloom, then icons pop in row by row")
    func powerOn() {
        var s = F.mirrored(["a"])
        s.monitor.power = .off
        var m = MonitorMachine(s)
        #expect(m.phase == .off && !m.needsFrames)
        s.monitor.power = .on
        m.sync(s)
        #expect(m.phase == .poweringOn && m.crtFrame == .on(0) && m.rowsShown == 0 && m.led == .on)
        let rows = run(&m, MonitorMachine.powerOnDuration + 0.1) { $0.rowsShown }
        #expect(rows == rows.sorted())
        #expect(Set(rows) == Set(0...5))
        #expect(m.phase == .on && m.showsTokens && !m.needsFrames)
    }

    @Test("Files arriving while off: the LED blinks amber three times, then holds; +N on the bezel")
    func amberBadge() {
        var s = F.mirrored(["a"])
        s.monitor.power = .off
        var m = MonitorMachine(s)
        s.monitor.pendingNew = 2
        m.sync(s)
        #expect(m.badge == "+2" && m.needsFrames)
        let leds = run(&m, 2) { $0.led }
        var blinks = 0
        for (a, b) in zip(leds, leds.dropFirst()) where a == .off && b == .amber { blinks += 1 }
        #expect(blinks == MonitorMachine.ledBlinks, "two blinks back to amber, then the steady pip")
        #expect(m.led == .amber && !m.needsFrames)
        s.monitor.pendingNew = 120
        m.sync(s)
        #expect(m.badge == "+99")
        s.monitor.power = .on
        s.monitor.pendingNew = 0
        m.sync(s)
        #expect(m.badge == nil && m.led == .on)
    }

    @Test("An input change shows two frames of static and a 1 s OSD")
    func inputChange() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot((0..<50).map { F.entry("f\($0)", UInt64($0 + 1)) }), now: F.t0)
        s.access = .connected
        var m = MonitorMachine(s)
        s.monitor.page = 1
        m.sync(s)
        #expect(m.staticFrame == 0 && m.osdText == "HDMI 2 · 5")
        let statics = run(&m, 0.3) { $0.staticFrame }
        #expect(statics.compactMap { $0 }.count == 10)
        #expect(Set(statics.compactMap { $0 }) == [0, 1])
        run(&m, 0.8)
        #expect(m.osdText == nil && !m.needsFrames)
        s.monitor.av = true
        m.sync(s)
        #expect(m.osdText == "AV" && m.overlay == .av)
    }

    @Test("The AV logo bounces inside the glass for at most 10 s; hovering restarts it")
    func avLogo() {
        var s = F.mirrored(["a"])
        s.monitor.av = true
        var m = MonitorMachine(s)
        #expect(m.logo.isMoving && m.needsFrames)
        let start = m.logo.position
        let positions = run(&m, 11) { $0.logo.position }
        #expect(positions.contains { $0 != start })
        for p in positions {
            #expect(p.x >= 0 && p.y >= 0 && p.x + m.logo.size.w <= m.logo.bounds.w && p.y + m.logo.size.h <= m.logo.bounds.h)
        }
        #expect(!m.logo.isMoving && !m.needsFrames)
        let frozen = m.logo.position
        run(&m, 1)
        #expect(m.logo.position == frozen)
        m.wakeLogo()
        #expect(m.logo.isMoving)
        m.settle()
        #expect(!m.needsFrames)
    }

    @Test("A corner hit sparkles")
    func cornerSparkle() {
        var logo = BouncingLogo(size: ArtSize(4, 2), bounds: ArtSize(10, 7))
        logo.wake(for: 30)
        var sparkled = false
        for _ in 0..<(30 * 60) {
            logo.step(1.0 / 60)
            if logo.sparkle > 0 { sparkled = true }
        }
        #expect(sparkled && logo.cornerHits > 0)
    }

    @Test("⏻ connects on the first-run prompt, otherwise toggles the display")
    func powerAction() {
        var s = DeskState()
        if case .requestConnect = MonitorMachine.powerAction(s) {} else { Issue.record("expected requestConnect") }
        s.access = .connected
        if case .power(false) = MonitorMachine.powerAction(s) {} else { Issue.record("expected power off") }
        s.monitor.power = .off
        if case .power(true) = MonitorMachine.powerAction(s) {} else { Issue.record("expected power on") }
        s.access = .notConnected
        if case .power(true) = MonitorMachine.powerAction(s) {} else { Issue.record("an off monitor powers on first") }
    }

    @Test("Hard sleep settles every animation at its last frame")
    func settle() {
        var s = F.mirrored(["a"])
        var m = MonitorMachine(s)
        s.monitor.power = .off
        s.monitor.pendingNew = 1
        m.sync(s)
        m.settle()
        #expect(m.phase == .off && !m.needsFrames && m.led == .amber)
    }
}

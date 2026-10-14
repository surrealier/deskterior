import Testing
@testable import DeskCore

/// The frame-loop gating policy (DESIGN §5 pause sources; M12): which system states hold the loop, when it is capped
/// at 30 Hz, and what one-shot work each event asks for.
@Suite("System gate")
struct SystemGateTests {
    @Test("Nothing holds a fresh desk; it runs at up to 60 Hz")
    func idle() {
        let g = SystemGate()
        #expect(g.holds.isEmpty && g.maxFrameRate == 60 && !g.capped)
    }

    @Test("Occlusion, display sleep, lock, fast user switching and Pause Desk each hold the loop until they clear")
    func holds() {
        var g = SystemGate()
        g.handle(.occlusion(visible: false))
        #expect(g.holds == [.occluded])
        g.handle(.screensSlept)
        g.handle(.locked)
        g.handle(.sessionResigned)
        g.handle(.userPaused(true))
        #expect(g.holds == [.occluded, .screensAsleep, .locked, .sessionInactive, .userPaused])
        g.handle(.occlusion(visible: true))
        g.handle(.screensWoke)
        g.handle(.unlocked)
        g.handle(.sessionActivated)
        #expect(g.holds == [.userPaused])
        g.handle(.userPaused(false))
        #expect(g.holds.isEmpty)
    }

    @Test("Battery holds the loop only with the setting, and never while peeking")
    func battery() {
        var g = SystemGate()
        g.handle(.battery(onBattery: true))
        #expect(g.holds.isEmpty, "the setting is off by default")
        g.pauseOnBattery = true
        #expect(g.holds == [.onBattery])
        g.handle(.peeking(true))
        #expect(g.holds.isEmpty, "Peek Desk wants the desk alive")
        g.handle(.peeking(false))
        g.handle(.battery(onBattery: false))
        #expect(g.holds.isEmpty)
    }

    @Test("Low Power Mode or a serious thermal state caps the loop at 30 Hz")
    func cap() {
        var g = SystemGate()
        g.handle(.lowPowerMode(true))
        #expect(g.maxFrameRate == 30 && g.capped)
        g.handle(.lowPowerMode(false))
        g.handle(.thermal(.fair))
        #expect(g.maxFrameRate == 60)
        g.handle(.thermal(.serious))
        #expect(g.maxFrameRate == 30)
        g.handle(.thermal(.critical))
        #expect(g.maxFrameRate == 30 && g.holds.isEmpty, "heat slows the desk but never stops it")
        g.handle(.thermal(.nominal))
        #expect(!g.capped)
    }

    @Test("Sleep settles and saves; wake regrids and rescans; a session switch does both once")
    func commands() {
        var g = SystemGate()
        let r1 = g.handle(.willSleep)
        #expect(r1 == [.forceRest, .flush])
        let r2 = g.handle(.didWake)
        #expect(r2 == [.refreshDisplays, .rescan])
        let r3 = g.handle(.screensSlept)
        #expect(r3 == [.forceRest])
        let r4 = g.handle(.screensWoke)
        #expect(r4.isEmpty)
        let r5 = g.handle(.locked)
        #expect(r5 == [.forceRest])
        let r6 = g.handle(.sessionResigned)
        #expect(r6 == [.forceRest, .flush])
        let r7 = g.handle(.sessionResigned)
        #expect(r7.isEmpty, "a repeated resign does nothing more")
        let r8 = g.handle(.sessionActivated)
        #expect(r8 == [.refreshDisplays, .rescan])
        let r9 = g.handle(.sessionActivated)
        #expect(r9.isEmpty)
        let r10 = g.handle(.userPaused(true))
        #expect(r10 == [.forceRest, .flush])
        let r11 = g.handle(.userPaused(false))
        #expect(r11.isEmpty)
    }

    @Test("Hold names match the frame loop's pause reasons")
    func names() {
        #expect(LoopHold.allCases.map(\.rawValue)
            == ["occluded", "screensAsleep", "sessionInactive", "locked", "userPaused", "onBattery"])
    }
}

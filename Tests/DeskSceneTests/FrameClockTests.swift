import Testing
@testable import DeskScene

/// The display-link-free stepping logic of `FrameLoop` (DESIGN §4.6).
@Suite("FrameClock")
struct FrameClockTests {
    static let step = FrameClock.step

    /// Ticks at `hz` from `start` for `count` ticks; returns the steps of each tick.
    static func ticks(_ clock: inout FrameClock, hz: Double, from start: Double, count: Int) -> [Int] {
        (1...count).map { clock.advance(to: start + Double($0) / hz) }
    }

    @Test("The first tick after a wake takes exactly one step")
    func firstTick() {
        var c = FrameClock()
        c.wake(at: 100)
        #expect(c.advance(to: 100.5) == 1)
        #expect(c.stepCount == 1)
        #expect(c.simTime == Self.step)
    }

    @Test("60 Hz ticks take one step each and simTime advances by exactly 1/60")
    func sixtyHertz() {
        var c = FrameClock()
        c.wake(at: 0)
        _ = c.advance(to: 0)
        let steps = Self.ticks(&c, hz: 60, from: 0, count: 600)
        #expect(steps.allSatisfy { $0 == 1 })
        #expect(c.stepCount == 601)
        #expect(c.simTime == 601.0 / 60)
    }

    @Test("Jittery 60 Hz timestamps never produce 0/2 alternation")
    func jitter() {
        var c = FrameClock()
        c.wake(at: 0)
        _ = c.advance(to: 0)
        var t = 0.0
        var steps: [Int] = []
        for i in 0..<300 {
            t += Self.step + (i % 2 == 0 ? 0.0004 : -0.0004)
            steps.append(c.advance(to: t))
        }
        #expect(steps.allSatisfy { $0 == 1 })
    }

    @Test("30 Hz ticks take two steps; 120 Hz ticks alternate zero and one")
    func otherRates() {
        var c = FrameClock()
        c.wake(at: 0)
        _ = c.advance(to: 0)
        #expect(Self.ticks(&c, hz: 30, from: 0, count: 60).allSatisfy { $0 == 2 })

        var d = FrameClock()
        d.wake(at: 0)
        _ = d.advance(to: 0)
        let fast = Self.ticks(&d, hz: 120, from: 0, count: 120)
        #expect(fast.reduce(0, +) == 60)
        #expect(fast.allSatisfy { $0 <= 1 })
    }

    @Test("A long stall takes at most maxStepsPerTick steps and banks nothing")
    func stall() {
        var c = FrameClock()
        c.wake(at: 0)
        _ = c.advance(to: 0)
        #expect(c.advance(to: 5) == 2)
        #expect(c.advance(to: 5 + Self.step) == 1)
        c.maxStepsPerTick = 3
        #expect(c.advance(to: 60) == 3)
    }

    @Test("Wake resets the accumulator: a paused gap is not replayed")
    func wakeResets() {
        var c = FrameClock()
        c.wake(at: 0)
        _ = c.advance(to: 0)
        _ = c.advance(to: 1.0 / 60)
        c.wake(at: 50)
        #expect(c.advance(to: 50.2) == 1)
    }

    @Test("Thirty consecutive rest ticks pause; needing frames resets the count")
    func rest() {
        var c = FrameClock()
        c.wake(at: 0)
        var t = 0.0
        for _ in 0..<29 {
            t += Self.step
            #expect(c.finishTick(at: t, needsFrames: false) == .run)
        }
        t += Self.step
        #expect(c.finishTick(at: t, needsFrames: true) == .run)
        #expect(c.restFrames == 0)
        for _ in 0..<29 {
            t += Self.step
            #expect(c.finishTick(at: t, needsFrames: false) == .run)
        }
        t += Self.step
        #expect(c.finishTick(at: t, needsFrames: false) == .rest)
        #expect(c.restFrames == 30)
    }

    @Test("Hard sleep 3 s after the later of wake, input and animation end, even while frames are needed")
    func hardSleep() {
        var c = FrameClock()
        c.wake(at: 10)
        #expect(c.finishTick(at: 12.9, needsFrames: true) == .run)
        #expect(c.finishTick(at: 13.0, needsFrames: true) == .hardSleep)

        c.wake(at: 20)
        c.noteActivity(at: 22)          // input at 22 s
        #expect(c.finishTick(at: 24.5, needsFrames: true) == .run)
        c.noteActivity(at: 27)          // a scripted animation ending at 27 s
        c.noteActivity(at: 23)          // an older timestamp never moves the timer back
        #expect(c.lastActivity == 27)
        #expect(c.finishTick(at: 29.9, needsFrames: true) == .run)
        #expect(c.finishTick(at: 30.0, needsFrames: true) == .hardSleep)
    }
}

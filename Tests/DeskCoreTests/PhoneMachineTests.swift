import Testing
@testable import DeskCore

@Suite("PhoneMachine")
struct PhoneMachineTests {
    static let dt: Float = 1.0 / 60

    @Test("Flip: commits at once, shows the three edge frames, lands face-down")
    func flipDown() {
        var m = PhoneMachine()
        #expect(m.face == .up && m.showsContents && m.isEmissive && !m.needsFrames)
        let started = m.flip() == [.committed(faceDown: true)]
        #expect(started)
        #expect(m.state == PhoneState(faceDown: true), "face-down hides at once")
        #expect(!m.showsContents && !m.canAccept(count: 0))
        var faces: [PropArt.PhoneFace] = [m.face]
        var events: [PhoneMachine.Event] = []
        var frames = 0
        while m.needsFrames {
            events += m.step(Self.dt)
            frames += 1
            if faces.last != m.face { faces.append(m.face) }
        }
        #expect(faces == [.flip1, .flip2, .flip3, .down])
        #expect(events == [.landed(faceDown: true)])
        #expect((15...16).contains(frames), "three frames at 12 fps")
        #expect(!m.isEmissive)
    }

    @Test("Flipping back up mirrors the frames; a click mid-flip turns back from the frame it is on")
    func reverse() {
        var m = PhoneMachine(PhoneState(faceDown: true))
        #expect(m.face == .down)
        _ = m.flip()
        #expect(m.face == .flip3)
        for _ in 0..<6 { _ = m.step(Self.dt) }
        let mid = m.face
        #expect(mid == .flip2)
        let turned = m.flip() == [.committed(faceDown: true)]
        #expect(turned)
        #expect(m.face == mid, "no jump")
        var events: [PhoneMachine.Event] = []
        while m.needsFrames { events += m.step(Self.dt) }
        #expect(events == [.landed(faceDown: true)] && m.face == .down)
    }

    @Test("Drops: accepted face-up below six, bonk otherwise; sync jumps without animating")
    func drops() {
        var m = PhoneMachine()
        #expect(m.canAccept(count: 5) && !m.canAccept(count: 6))
        m.sync(PhoneState(faceDown: true))
        #expect(m.phase == .faceDown && !m.needsFrames && !m.canAccept(count: 0))
        m.sync(PhoneState(faceDown: true))
        #expect(m.phase == .faceDown)
        #expect(m.step(Self.dt).isEmpty)
    }
}

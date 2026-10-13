import DeskCore
import Metal
import Testing
@testable import DeskScene

@Suite("Monitor element")
struct MonitorTests {
    typealias F = SceneFixture

    func anchor(_ scene: DeskScene, _ name: String) throws -> SIMD2<Float> {
        F.centre(try #require(scene.layout?.anchors[name]))
    }

    @Test("⏻ toggles the display; on the first-run prompt it connects; INPUT cycles only while on; dots pick pages")
    func controls() throws {
        var s = F.state()
        let scene = F.scene(s)
        let rec = SceneRecorder(scene)
        let p = Pointer(scene: scene)
        p.click(try anchor(scene, "monitor.power"))
        #expect(rec.actions.last == "power(false)")
        p.click(try anchor(scene, "monitor.input"))
        #expect(rec.actions.last == "cycleInput")
        p.click(try anchor(scene, "monitor.pageDots") - SIMD2(Float(CoreLayout.pageDots.w / 2) - 1, 0))
        #expect(rec.actions.last == "setPage(0)")
        s.monitor.power = .off
        scene.apply(s)
        rec.actions.removeAll()
        p.click(try anchor(scene, "monitor.input"))
        #expect(rec.actions.isEmpty)
        p.click(try anchor(scene, "monitor.power"))
        #expect(rec.actions == ["power(true)"])
        let fresh = F.scene(DeskState())
        let rec2 = SceneRecorder(fresh)
        let q = Pointer(scene: fresh)
        q.click(try anchor(fresh, "monitor.power"))
        #expect(rec2.actions == ["requestConnect"])
        #expect(fresh.monitor?.machine?.overlay == .connectPrompt)
    }

    @Test("Card buttons: DESKTOP HIDDEN asks Show / Keep hidden; NO SIGNAL offers Open Settings / Choose Folder…")
    func cards() throws {
        var s = DeskState()
        s.access = .finderHidden
        let scene = F.scene(s)
        let rec = SceneRecorder(scene)
        let p = Pointer(scene: scene)
        let monitor = try #require(scene.monitor)
        #expect(Set(monitor.cardButtons.keys) == ["card.show", "card.keepHidden"])
        let glass = try #require(scene.layout).rect(CoreLayout.screen)
        for r in monitor.cardButtons.values { #expect(glass.contains(r)) }
        p.click(F.centre(try #require(monitor.cardButtons["card.show"])))
        p.click(F.centre(try #require(monitor.cardButtons["card.keepHidden"])))
        #expect(rec.actions == ["requestConnect", "power(false)"])
        s.access = .denied
        scene.apply(s)
        #expect(Set(monitor.cardButtons.keys) == ["card.openSettings", "card.chooseFolder"])
        p.click(F.centre(try #require(monitor.cardButtons["card.openSettings"])))
        p.click(F.centre(try #require(monitor.cardButtons["card.chooseFolder"])))
        #expect(rec.actions.suffix(2) == ["requestPrivacySettings", "requestChooseFolder"])
        #expect(monitor.accessibilityItems().map(\.id).contains("card.chooseFolder"))
    }

    @Test("Power off: the screen glows through the CRT collapse, then goes dark; the loop comes to rest")
    func powerOffLight() throws {
        var s = F.state()
        let scene = F.scene(s)
        let p = Pointer(scene: scene)
        let glass = try #require(scene.layout).rect(CoreLayout.screen)
        func screenLevel() -> UInt8 { scene.lighting.mask[glass.midY * scene.grid.artSize.w + glass.midX] & 7 }
        #expect(screenLevel() == 7 && !scene.needsFrames)
        s.monitor.power = .off
        scene.apply(s)
        #expect(scene.needsFrames && scene.scriptedAnimating && screenLevel() == 7)
        p.frames(Int(MonitorMachine.powerOffDuration * 60) + 2)
        #expect(!scene.needsFrames && screenLevel() < 7 && scene.roomState?.lights.monitorOn == false)
        s.monitor.power = .on
        scene.apply(s)
        #expect(screenLevel() == 7 && scene.needsFrames)
        p.frames(Int(MonitorMachine.powerOnDuration * 60) + 2)
        #expect(!scene.needsFrames && scene.screen?.visibleTokenCount == F.names.count)
    }

    @Test("Scrolling over the screen flips one page per gesture")
    func scrollPages() throws {
        let scene = F.scene(F.state((0..<50).map { "f\($0).txt" }))
        let rec = SceneRecorder(scene)
        let p = Pointer(scene: scene)
        let at = try anchor(scene, "monitor.screen")
        for _ in 0..<6 { _ = p.event(.scroll, at, scroll: SIMD2(-8, 0)) }
        #expect(rec.actions == ["setPage(1)"])
        p.frames(20)
        _ = p.event(.scroll, at, scroll: SIMD2(30, 0))
        #expect(rec.actions == ["setPage(1)"], "page 0 is current in the model: a right scroll has nowhere to go")
        p.frames(20)
        #expect(!scene.needsFrames)
    }

    @Test("Hovering the AV screen restarts the logo's 10 s bounce")
    func avHover() throws {
        var s = F.state()
        s.monitor.av = true
        let scene = F.scene(s)
        let p = Pointer(scene: scene)
        let monitor = try #require(scene.monitor)
        p.frames(Int(MonitorMachine.avBounceLimit * 60) + 5)
        #expect(!scene.needsFrames && monitor.machine?.logo.isMoving == false)
        _ = p.event(.move, try anchor(scene, "monitor.screen"))
        #expect(monitor.machine?.logo.isMoving == true && scene.needsFrames)
        scene.forceRest()
        #expect(!scene.needsFrames)
    }
}

@Suite("Monitor snapshots", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MonitorSnapshotTests {
    typealias F = SceneFixture
    let gpu: GPU

    init() throws {
        gpu = try GPU()
    }

    /// Renders `state` (after `frames` steps) and crops the monitor with a margin.
    func monitor(_ state: DeskState, frames: Int = 1, before: ((DeskScene) -> Void)? = nil, change: DeskState? = nil) throws -> PixelBuffer {
        let host = try SceneHost(grid: PixelGrid(display: calibrationDisplay), device: gpu.device)
        host.scene.clock = .fixed(WallTime(hour: 10, minute: 0))
        host.scene.connect(presenter: host.presenter)
        host.scene.apply(state)
        before?(host.scene)
        if let change { host.scene.apply(change) }
        let driver = OffscreenDriver(host: host)
        driver.run(frames: frames)
        let frame = try driver.snapshot()
        #expect(frame.pixels.allSatisfy { Apollo.index(of: $0) != nil })
        let r = try #require(host.scene.layout).rect(CoreLayout.monitorBody).insetBy(-4, -4)
        return frame.cropped(to: r)
    }

    @Test("CRT collapse, frame 3 (a short bright line)")
    func crtOff() throws {
        var s = F.state()
        let on = s
        s.monitor.power = .off
        let image = try monitor(on, frames: Int(3.5 * 60 / 12), change: s)
        #expect(Golden.match(image, "monitor-crt-off"))
    }

    @Test("Off with three new files: amber LED and +3 on the chin")
    func badge() throws {
        var s = F.state()
        s.monitor.power = .off
        s.monitor.pendingNew = 3
        #expect(Golden.match(try monitor(s), "monitor-badge"))
    }

    @Test("AV: NO SIGNAL")
    func noSignal() throws {
        var s = F.state()
        s.monitor.av = true
        #expect(Golden.match(try monitor(s), "monitor-no-signal"))
    }

    @Test("First run: the connect prompt")
    func connectPrompt() throws {
        #expect(Golden.match(try monitor(DeskState()), "monitor-connect-prompt"))
    }

    @Test("Access denied: the NO SIGNAL card with its buttons")
    func accessDenied() throws {
        var s = DeskState()
        s.access = .denied
        #expect(Golden.match(try monitor(s), "monitor-access-denied"))
    }
}

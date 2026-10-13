import AppKit
import DeskCore
import Foundation
import Metal
import QuartzCore
import Testing
@testable import DeskScene

/// A scene whose actions run through the reducer and come straight back, as the app's `Store` does.
final class SceneStore {
    let scene: DeskScene
    var state: DeskState
    var journal = UndoJournal()
    var actions: [String] = []
    var requests: [SceneRequest] = []

    init(_ state: DeskState, time: WallTime = WallTime(hour: 10, minute: 0)) {
        self.state = state
        scene = SceneFixture.scene(state, time: time)
        scene.onAction = { [unowned self] in dispatch($0) }
        scene.onRequest = { [unowned self] in requests.append($0) }
    }

    func dispatch(_ a: DeskAction) {
        actions.append("\(a)")
        let before = state
        let effects = Reducer.reduce(&state, journal: &journal, a, ReduceEnv(now: SceneFixture.t0))
        if state != before { scene.apply(state) }
        for case let .play(id, target) in effects { scene.play(id, target) }
    }

    var opens: [String] { actions.filter { $0.hasPrefix("requestOpen") } }
}

@Suite("Interaction: what is hidden stays out of reach, clicks hit what is drawn, carries behave")
struct InteractionTests {
    typealias F = SceneFixture

    /// 13 named tokens plus `extra` more: 53 fill HDMI 1 and put 8 on HDMI 2.
    static func names(extra: Int) -> [String] { F.names + (0..<extra).map { "extra \($0).txt" } }

    @Test("Keys and menus never act on tokens the desk no longer shows: power off, AV, another page, a hiding place")
    func hiddenSelection() throws {
        let store = SceneStore(F.state(Self.names(extra: 40)))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let sel = try #require(scene.selection)
        func fileActions() -> [String] { store.actions.filter { $0.hasPrefix("request") } }

        p.click(F.centre(try #require(screen.iconRect(of: F.key(1)))))
        #expect(sel.keys == [F.key(1)])
        store.dispatch(.power(false))
        #expect(sel.isEmpty, "the selection goes with the picture")
        #expect(!scene.handleKey(.quickLook) && !scene.handleKey(.open) && !scene.handleKey(.copy))
        #expect(fileActions().isEmpty)

        store.dispatch(.power(true))
        p.frames(Int(MonitorMachine.powerOnDuration * 60) + 2)
        p.click(F.centre(try #require(screen.iconRect(of: F.key(2)))))
        store.dispatch(.selectAV)
        #expect(sel.isEmpty && !scene.handleKey(.open) && fileActions().isEmpty)

        store.dispatch(.setPage(0))
        p.frames(10)
        p.click(F.centre(try #require(screen.iconRect(of: F.key(3)))))
        store.dispatch(.setPage(1))
        p.frames(10)
        #expect(sel.isEmpty, "a page change leaves the old page's selection behind")
        let other = try #require(screen.visibleTokens().first?.key)
        p.click(F.centre(try #require(screen.iconRect(of: other))), mods: .command)
        _ = p.event(.rightDown, F.centre(try #require(screen.iconRect(of: other))), count: 1)
        guard case let .menu(menu, _)? = store.requests.last else { Issue.record("no menu"); return }
        #expect(menu.item("open")?.command == .open([other]) && menu.item("trash")?.command == .moveToTrash([other]))

        store.dispatch(.move([other], to: .container(.cabinetTop, order: 0)))
        #expect(sel.isEmpty && !scene.handleKey(.copy) && fileActions().isEmpty)
    }

    @Test("A double-click opens only when both clicks hit the same drawn token, and a triple-click opens once")
    func doubleClicks() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        p.click(F.centre(try #require(screen.iconRect(of: F.key(1)))), count: 3)
        #expect(store.opens == ["requestOpen([\(F.key(1))])"])

        // The first click lands on empty glass; a file prints into that cell before the second (count 2) press.
        store.actions.removeAll()
        let emptyRect = try #require(screen.firstEmptyCell())
        let empty = F.centre(emptyRect)
        _ = p.event(.move, empty)
        _ = p.event(.down, empty, count: 1)
        _ = p.event(.up, empty, count: 1)
        let cell = screen.cell(nearest: ArtPoint(Int(empty.x), Int(empty.y)))
        var s = store.state
        s.tokens.insert(F.key(99), meta: TokenMeta(name: "late.txt", kind: .text, added: F.t0), at: .screen(page: 0, col: cell.col, row: cell.row))
        store.state = s
        scene.apply(s)
        _ = p.event(.down, empty, count: 2)
        _ = p.event(.up, empty, count: 2)
        #expect(store.opens.isEmpty)
        #expect(scene.selection?.keys == [F.key(99)], "the second click counts as a first click on the new token")

        // A token still waiting for its print-in is not there to click.
        scene.play(.printIn, .tokens([F.key(5), F.key(6)]))
        let six = try #require(screen.iconRect(of: F.key(6)))
        #expect(scene.hitTest(six.center)?.token == nil)
        p.frames(4)
        #expect(scene.hitTest(six.center)?.token == F.key(6))
    }

    @Test("⌘-drag carries the whole selection; ⌘-click on a selected token deselects it on release")
    func commandDrag() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let sel = try #require(scene.selection)
        p.click(F.centre(try #require(screen.iconRect(of: F.key(1)))))
        p.click(F.centre(try #require(screen.iconRect(of: F.key(2)))), mods: .command)
        #expect(sel.keys == [F.key(1), F.key(2)])
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(2)))), F.centre(screen.cellRect(6, 3)), mods: .command)
        #expect(store.actions.last == "move([\(F.key(2)), \(F.key(1))], to: screen p0(6,3))")
        p.frames(10)
        #expect(sel.count == 2)
        let b = F.centre(try #require(screen.iconRect(of: F.key(2))))
        _ = p.event(.move, b)
        _ = p.event(.down, b, mods: .command, count: 1)
        #expect(sel.count == 2, "the press may still become a drag")
        _ = p.event(.up, b, mods: .command, count: 1)
        #expect(sel.keys == [F.key(1)])
    }

    @Test("A label hit-tests before the icons it covers; on the bottom row it sits above its icon, on the glass")
    func labels() throws {
        let scene = F.scene(F.state((0..<45).map { "file \($0).txt" }))
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let top = try #require(screen.iconRect(of: F.key(1)))
        p.click(F.centre(top))
        let label = try #require(screen.labelRects.first { $0.key == F.key(1) }?.rect)
        #expect(label.minY > top.maxY)
        // Where the label covers the next row's icon, the label's token answers.
        let below = try #require(screen.iconRect(of: F.key(10)))
        let spot = label.intersection(below)
        #expect(!spot.isEmpty && scene.hitTest(spot.center)?.token == F.key(1))
        let bottom = try #require(screen.iconRect(of: F.key(37)))
        p.click(F.centre(bottom))
        let up = try #require(screen.labelRects.first { $0.key == F.key(37) }?.rect)
        #expect(up.maxY <= bottom.minY && screen.screenRect.contains(up))
    }

    @Test("While carrying, keys other than Esc do nothing; a scroll or 0.6 s on a page dot turns the page")
    func carryPaging() throws {
        let store = SceneStore(F.state(Self.names(extra: 40)))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let to = F.centre(screen.cellRect(5, 2))
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(1)))), to, hold: true)
        #expect(!scene.handleKey(.undo) && !scene.handleKey(.selectAll) && !scene.handleKey(.move(dx: 1, dy: 0)))
        #expect(store.actions.isEmpty)
        _ = p.event(.scroll, to, scroll: SIMD2(-30, 0))
        #expect(store.actions == ["setPage(1)"] && screen.dropTarget?.page == 1)
        let dots = try #require(scene.layout).rect(CoreLayout.pageDots)
        _ = p.event(.drag, SIMD2(Float(dots.minX) + 0.5, Float(dots.minY) + 0.5))
        p.frames(30)
        #expect(store.actions.count == 1)
        p.frames(8)
        #expect(store.actions.last == "setPage(0)" && scene.isDragging)
        #expect(scene.handleKey(.escape) && !scene.isDragging)
    }

    @Test("A carry springing home does not uncover a token another carry holds; a lost mouse-up does not land")
    func carriesOverlap() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let layout = try #require(scene.layout)
        let wall = SIMD2<Float>(Float(layout.coreOrigin.x + 260), Float(layout.coreOrigin.y + 4))
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(1)))), wall)
        let b = try #require(screen.iconRect(of: F.key(2)))
        p.drag(F.centre(b), wall, steps: 2, hold: true)
        #expect(screen.carried == [F.key(1), F.key(2)])
        p.frames(8)
        #expect(scene.isDragging && screen.carried == [F.key(2)])
        #expect(scene.hitTest(b.center)?.token != F.key(2))

        // The mouse-up of that carry never arrives; the next press drops it and starts afresh.
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(5)))), F.centre(screen.cellRect(8, 4)))
        #expect(store.actions == ["move([\(F.key(5))], to: screen p0(8,4))"])
        p.frames(8)
        #expect(screen.carried.isEmpty && !scene.isDragging)
    }

    @Test("Several tokens dropped where their page has no room bonk with \"That's full.\"")
    func fullPageDrop() throws {
        let store = SceneStore(F.state((0..<46).map { "f\($0).txt" }))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        p.click(F.centre(try #require(screen.iconRect(of: F.key(1)))))
        p.click(F.centre(try #require(screen.iconRect(of: F.key(2)))), mods: .command)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(2)))), F.centre(screen.cellRect(6, 3)))
        #expect(store.actions.isEmpty && scene.bonkCount == 1 && scene.toastShown == .containerFull)
        // Onto one of their own cells they just trade places.
        p.frames(10)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(2)))), F.centre(screen.cellRect(0, 0)))
        #expect(store.actions.count == 1 && scene.bonkCount == 1)
    }

    @Test("A swap slides the displaced token over 6 frames; while bracketed its ghost waits where it would go")
    func swapFeedback() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let glass = screen.screenRect
        func opaque(_ r: ArtRect) -> Int {
            let image = screen.compose()
            let local = r.offsetBy(-glass.x, -glass.y)
            var n = 0
            for y in local.minY..<local.maxY { for x in local.minX..<local.maxX where image.pixel(x, y).a != 0 { n += 1 } }
            return n
        }
        let target = try #require(screen.iconRect(of: F.key(5)))
        let home = screen.iconRect(0, 0)
        let whole = opaque(target)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(1)))), F.centre(target), hold: true)
        let ghost = opaque(home)
        #expect(ghost > 0 && ghost < whole * 2 / 3, "ghost \(ghost) of \(whole)")
        #expect(opaque(target) == whole, "the occupant itself stays put until the drop")
        _ = p.event(.up, F.centre(target), count: 1)
        #expect(store.actions == ["move([\(F.key(1))], to: screen p0(4,0))"])
        #expect(screen.needsFrames && opaque(home) == 0, "the displaced token starts from where it was")
        p.frames(7)
        #expect(!screen.needsFrames && opaque(home) > 0)
    }

    @Test("Page dots answer only where one is drawn; INPUT is inert while off; new files on another page blink its dot")
    func monitorChin() throws {
        let store = SceneStore(F.state(Self.names(extra: 40)))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let layout = try #require(scene.layout)
        let monitor = try #require(scene.monitor)
        let dots = layout.rect(CoreLayout.pageDots)
        #expect(scene.hitTest(ArtPoint(dots.minX + CoreLayout.pageDotPitch, dots.minY + 1))?.part == "monitor.pageDots")
        let past = scene.hitTest(ArtPoint(dots.minX + 2 * CoreLayout.pageDotPitch, dots.minY + 1))
        #expect(past?.element == "monitor" && past?.part == nil && past.flatMap(monitor.tooltip) == nil)

        let input = try #require(scene.hitTest(layout.rect(CoreLayout.input).center))
        #expect(monitor.tooltip(input) != nil)
        store.dispatch(.power(false))
        #expect(monitor.tooltip(input) == nil)
        if case .none = monitor.hoverStyle(input) {} else { Issue.record("INPUT lights up while off") }
        store.dispatch(.power(true))
        p.frames(Int(MonitorMachine.powerOnDuration * 60) + 2)

        let onPage2 = try #require(store.state.tokens.sortedKeys.first { store.state.tokens.location(of: $0)?.cell?.page == 1 })
        scene.play(.printIn, .tokens([onPage2]))
        #expect(monitor.blinkingPages == [1] && scene.needsFrames)
        p.frames(Int(MonitorElement.dotBlinkDuration * 60) + 2)
        #expect(monitor.blinkingPages.isEmpty)
    }

    @Test("After a drop the token under the pointer rings, but its tooltip waits for the pointer to move")
    func noTooltipAfterDrop() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let to = F.centre(screen.cellRect(7, 3))
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(1)))), to)
        #expect(scene.room?.hovered?.token == F.key(1))
        #expect(scene.nextInputDeadline == nil)
        _ = p.event(.move, to + SIMD2(1, 0))
        #expect(scene.nextInputDeadline != nil)
    }

    @Test("VoiceOver lists tokens and controls; a press clicks them; Open works only on a token on show")
    func accessibility() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let items = scene.accessibilityItems()
        let token = try #require(items.first { $0.token == F.key(1) })
        #expect(token.role == .token && token.label == "보고서 final.pdf")
        let power = try #require(items.first { $0.id == "monitor.power" })
        scene.accessibilityPress(token, time: 1)
        #expect(scene.selection?.keys == [F.key(1)])
        scene.accessibilityOpen(F.key(1))
        #expect(store.opens == ["requestOpen([\(F.key(1))])"])
        scene.accessibilityPress(power, time: 2)
        #expect(store.state.monitor.power == .off)
        scene.accessibilityOpen(F.key(1))
        #expect(store.opens.count == 1)
        #expect(!scene.accessibilityItems().contains { $0.token != nil })
    }

    @Test("Show on Desk selects the token once it is on show, even after powering the display on")
    func showOnDeskSelects() throws {
        var s = F.state(Self.names(extra: 40))
        s.monitor.power = .off
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let key = try #require(s.tokens.sortedKeys.first { s.tokens.location(of: $0)?.cell?.page == 1 })
        store.dispatch(.showOnDesk(key))
        #expect(scene.selection?.isEmpty == true, "not yet: the screen is still blooming")
        p.frames(Int(MonitorMachine.powerOnDuration * 60) + 4)
        #expect(scene.selection?.keys == [key] && store.state.monitor.page == 1)
    }

    @Test("The drag threshold is 3 art px but at most 4 pt")
    func dragThreshold() throws {
        let scene = F.scene()
        let router = try #require(scene.room?.router)
        #expect(router.dragDistance == InputRouter.dragThreshold)
        scene.pointsPerArtPx = 2.5
        #expect(abs(router.dragDistance - 1.6) < 0.001)
        scene.pointsPerArtPx = 0.5
        #expect(router.dragDistance == 3)
    }
}

/// A frame-loop host that only says whether it needs frames.
final class StubLoopHost: FrameLoopHost {
    var needsFrames: Bool
    var renders = 0
    init(needsFrames: Bool) { self.needsFrames = needsFrames }
    func frameLoopStep(_ dt: Double) {}
    func frameLoopRender() { renders += 1 }
    var frameLoopNeedsFrames: Bool { needsFrames }
    var frameLoopScriptedAnimating: Bool { needsFrames }
    func frameLoopForceRest() { needsFrames = false }
}

@Suite("Frame loop pauses")
struct FrameLoopPauseTests {
    @Test("Clearing the last pause reason wakes the loop when something waits to animate, else renders once")
    func resume() {
        let loop = FrameLoop()
        let host = StubLoopHost(needsFrames: true)
        loop.host = host
        loop.attach(to: NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8)))
        defer { loop.invalidate() }
        loop.setPaused(.occluded, true)
        loop.setPaused(.locked, true)
        loop.setPaused(.occluded, false)
        #expect(!loop.isRunning)
        loop.setPaused(.locked, false)
        #expect(loop.isRunning, "a print-in queued while covered plays when the desk shows again")
        host.needsFrames = false
        let idle = FrameLoop()
        idle.host = host
        idle.attach(to: NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8)))
        defer { idle.invalidate() }
        idle.setPaused(.userPaused, true)
        idle.setPaused(.userPaused, false)
        #expect(!idle.isRunning && host.renders == 1)
    }
}

@Suite("Scene host wakes", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct SceneHostWakeTests {
    @Test("Hovering the AV screen restarts the logo and wakes the loop to play it")
    func hoverWakesAV() throws {
        let gpu = try GPU()
        var s = SceneFixture.state()
        s.monitor.av = true
        let host = try SceneHost(grid: PixelGrid(display: calibrationDisplay), device: gpu.device)
        host.scene.apply(s)
        host.attach(to: NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8)), layer: CAMetalLayer())
        defer { host.invalidate() }
        host.scene.forceRest()
        #expect(!host.loop.isRunning && !host.scene.needsFrames)
        let glass = try #require(host.scene.layout).rect(CoreLayout.screen)
        host.handle(InputEvent(.move, art: SIMD2(Float(glass.midX) + 0.5, Float(glass.minY) + 2.5), t: 1))
        #expect(host.scene.needsFrames && host.loop.isRunning)
    }
}

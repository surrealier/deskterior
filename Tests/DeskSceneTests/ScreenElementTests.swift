import DeskCore
import Foundation
import Testing
@testable import DeskScene

/// Desks with mirrored tokens for the scene tests (kind icons only, so pictures are deterministic).
enum SceneFixture {
    static let volume = "VOL"
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func key(_ i: UInt64) -> TokenKey { TokenKey(volume: volume, inode: i) }

    static let names = [
        "보고서 final.pdf", "IMG_0001.png", "notes.md", "Projects", "archive.zip", "song.mp3", "clip.mov",
        "main.swift", "installer.dmg", "Screenshot 2026-10-12.png", "todo.txt", "budget.xlsx", "Tagged.txt",
    ]

    static func kind(_ name: String) -> FileKind {
        if name.hasPrefix("Screenshot") { return .screenshot }
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return .pdf
        case "png": return .image
        case "md", "txt": return .text
        case "zip": return .zip
        case "mp3": return .audio
        case "mov": return .video
        case "swift": return .code
        case "dmg": return .dmg
        case "xlsx": return .doc
        case "": return .folder
        default: return .unknown
        }
    }

    /// A connected desk holding `names` (inodes 1…n) on the monitor in reading order (key n+1 in cell n).
    static func state(_ names: [String] = names) -> DeskState {
        var s = DeskState()
        s.root = DesktopRoot(path: "/fake/Desktop", volume: volume)
        for (i, n) in names.enumerated() {
            let meta = TokenMeta(name: n, kind: kind(n), added: t0, modified: t0, size: 1, tags: n.hasPrefix("Tagged") ? ["Red"] : [])
            s.tokens.insert(key(UInt64(i + 1)), meta: meta, at: ScreenGrid.standard.cell(page: i / 45, index: i % 45).location)
        }
        s.access = .connected
        return s
    }

    /// The room at 10:00 (or `time`) on this Mac's default display, showing `state`.
    static func scene(_ state: DeskState? = state(), time: WallTime = WallTime(hour: 10, minute: 0)) -> DeskScene {
        let scene = DeskScene(grid: PixelGrid(display: calibrationDisplay))
        scene.clock = .fixed(time)
        if let state { scene.apply(state) }
        return scene
    }

    static func centre(_ r: ArtRect) -> SIMD2<Float> { SIMD2(Float(r.midX) + 0.5, Float(r.midY) + 0.5) }
}

/// Records what a scene asks for.
final class SceneRecorder {
    var actions: [String] = []
    var requests: [SceneRequest] = []

    init(_ scene: DeskScene) {
        scene.onAction = { [unowned self] in actions.append("\($0)") }
        scene.onRequest = { [unowned self] in requests.append($0) }
    }
}

/// Feeds a scene synthetic pointer input on a virtual clock.
final class Pointer {
    let scene: DeskScene
    var t: Double = 100

    init(scene: DeskScene) {
        self.scene = scene
    }

    @discardableResult
    func event(_ kind: InputEvent.Kind, _ p: SIMD2<Float>, mods: InputEvent.Modifiers = [], count: Int = 0,
                        scroll: SIMD2<Float> = .zero) -> Bool {
        t += 1.0 / 60
        return scene.handle(InputEvent(kind, art: p, mods: mods, clickCount: count, scroll: scroll, t: t))
    }

    func click(_ p: SIMD2<Float>, mods: InputEvent.Modifiers = [], count: Int = 1) {
        _ = event(.move, p)
        for n in 1...count {
            _ = event(.down, p, mods: mods, count: n)
            _ = event(.up, p, mods: mods, count: n)
        }
    }

    /// Presses at `from`, moves to `to` in `steps` and (unless `hold`) releases there, stepping the scene a frame
    /// per move.
    func drag(_ from: SIMD2<Float>, _ to: SIMD2<Float>, steps: Int = 8, hold: Bool = false, mods: InputEvent.Modifiers = []) {
        _ = event(.move, from)
        _ = event(.down, from, mods: mods, count: 1)
        for k in 1...steps {
            _ = event(.drag, from + (to - from) * Float(k) / Float(steps), mods: mods)
            scene.step(1.0 / 60)
        }
        if !hold { _ = event(.up, to, mods: mods, count: 1) }
    }

    func frames(_ n: Int) {
        for _ in 0..<n {
            t += 1.0 / 60
            scene.step(1.0 / 60)
            scene.advanceInput(to: t)
        }
    }
}

@Suite("Screen element")
struct ScreenElementTests {
    typealias F = SceneFixture

    @Test("Tokens of the current page show and hit-test only while the monitor shows the desktop")
    func visibility() throws {
        var s = F.state()
        let scene = F.scene(s)
        let screen = try #require(scene.screen)
        #expect(screen.visibleTokenCount == F.names.count)
        let r = try #require(screen.iconRect(of: F.key(1)))
        #expect(r.size == ArtSize(16, 16))
        #expect(scene.hitTest(r.center)?.token == F.key(1) && scene.hitTest(r.center)?.element == "screen")
        // The gutter between cells is the glass (the monitor's), not a token.
        #expect(scene.hitTest(ArtPoint(r.maxX + 1, r.midY))?.part == "monitor.screen")
        s.monitor.av = true
        scene.apply(s)
        #expect(screen.visibleTokenCount == 0 && scene.hitTest(r.center)?.token == nil)
        s.monitor.av = false
        s.access = .denied
        scene.apply(s)
        #expect(screen.visibleTokenCount == 0)
        s.access = .connected
        s.monitor.power = .off
        scene.apply(s)
        #expect(screen.visibleTokenCount == 0, "tokens go with the CRT collapse")
    }

    @Test("Press selects, ⌘ toggles, ⇧ extends, a plain click narrows, a double-click opens")
    func selection() throws {
        let scene = F.scene()
        let rec = SceneRecorder(scene)
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let sel = try #require(scene.selection)
        let a = F.centre(try #require(screen.iconRect(of: F.key(1))))
        let b = F.centre(try #require(screen.iconRect(of: F.key(2))))
        let c = F.centre(try #require(screen.iconRect(of: F.key(3))))
        p.click(a)
        #expect(sel.keys == [F.key(1)] && sel.primary == F.key(1))
        p.click(b, mods: .command)
        p.click(c, mods: .shift)
        #expect(sel.keys == [F.key(1), F.key(2), F.key(3)] && sel.primary == F.key(3))
        p.click(b, mods: .command)
        #expect(sel.keys == [F.key(1), F.key(3)])
        p.click(a)
        #expect(sel.keys == [F.key(1)])
        p.click(a, count: 2)
        #expect(rec.actions.last == "requestOpen([\(F.key(1))])")
        // Clicking empty glass (or the bare wall) clears the selection.
        let glass = try #require(scene.layout).rect(CoreLayout.screen)
        p.click(SIMD2(Float(glass.maxX - 3), Float(glass.maxY - 3)))
        #expect(sel.isEmpty)
    }

    @Test("A carry follows the pointer, brackets the landing cell and drops with one move")
    func carryAndDrop() throws {
        let scene = F.scene()
        let rec = SceneRecorder(scene)
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let from = F.centre(try #require(screen.iconRect(of: F.key(1))))
        let to = F.centre(screen.cellRect(7, 3))
        p.drag(from, to, hold: true)
        #expect(scene.isDragging && screen.carried == [F.key(1)])
        #expect(screen.dropTarget == ScreenCell(page: 0, col: 7, row: 3))
        #expect(screen.iconRect(of: F.key(1)) != nil && screen.token(at: ArtPoint(Int(from.x), Int(from.y))) == nil)
        #expect(scene.needsFrames && scene.scriptedAnimating)
        _ = p.event(.up, to, count: 1)
        #expect(rec.actions == ["move([\(F.key(1))], to: screen p0(7,3))"])
        #expect(!scene.isDragging && screen.carried.isEmpty && screen.dropTarget == nil)
        // A move under the drag threshold is a click, not a carry.
        rec.actions.removeAll()
        p.drag(from, from + SIMD2(2.5, 0), steps: 2)
        #expect(rec.actions.isEmpty && scene.selection?.keys == [F.key(1)])
    }

    @Test("A drop on the drive hub bonks and springs back; on the bare wall it just springs back")
    func bonkAndSpringBack() throws {
        let scene = F.scene()
        let rec = SceneRecorder(scene)
        let p = Pointer(scene: scene)
        let layout = try #require(scene.layout)
        let screen = try #require(scene.screen)
        let from = F.centre(try #require(screen.iconRect(of: F.key(2))))
        p.drag(from, F.centre(try #require(layout.anchors["hub"])))
        #expect(rec.actions.isEmpty && scene.bonkCount == 1 && scene.toastShown == .drivesReadOnly)
        #expect(screen.carried == [F.key(2)] && scene.needsFrames)
        p.frames(8)
        #expect(screen.carried.isEmpty)
        let wall = SIMD2<Float>(Float(layout.coreOrigin.x + 260), Float(layout.coreOrigin.y + 4))
        p.drag(from, wall)
        #expect(rec.actions.isEmpty && scene.bonkCount == 1)
        p.frames(8)
        #expect(screen.carried.isEmpty)
        // Esc cancels a carry in hand.
        p.drag(from, F.centre(screen.cellRect(8, 4)), hold: true)
        #expect(scene.handleKey(.escape) && !scene.isDragging)
        p.frames(8)
        _ = p.event(.up, F.centre(screen.cellRect(8, 4)), count: 1)
        #expect(rec.actions.isEmpty && screen.carried.isEmpty)
    }

    @Test("Several selected tokens travel together and pour into the cells nearest the drop")
    func multiCarry() throws {
        let scene = F.scene()
        let rec = SceneRecorder(scene)
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        p.click(F.centre(try #require(screen.iconRect(of: F.key(1)))))
        p.click(F.centre(try #require(screen.iconRect(of: F.key(3)))), mods: .command)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(3)))), F.centre(screen.cellRect(6, 4)))
        #expect(rec.actions == ["move([\(F.key(3)), \(F.key(1))], to: screen p0(6,4))"])
    }

    @Test("A marquee on empty glass selects what it touches; ⇧ keeps the old selection; Esc restores it")
    func marquee() throws {
        let scene = F.scene()
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let sel = try #require(scene.selection)
        let glass = try #require(scene.layout).rect(CoreLayout.screen)
        let start = SIMD2<Float>(Float(glass.minX + 2), Float(glass.minY + 2))
        p.drag(start, F.centre(screen.cellRect(1, 1)))
        #expect(sel.keys == [F.key(1), F.key(2), F.key(10), F.key(11)])
        p.drag(F.centre(screen.cellRect(8, 4)), F.centre(screen.cellRect(3, 1)) + SIMD2(0, 1), mods: .shift)
        #expect(sel.keys == [F.key(1), F.key(2), F.key(10), F.key(11), F.key(13)])
        let before = sel.keys
        p.drag(F.centre(screen.cellRect(8, 4)), F.centre(screen.cellRect(0, 0)), hold: true, mods: .shift)
        #expect(sel.count > before.count)
        #expect(scene.handleKey(.escape))
        #expect(sel.keys == before && screen.marquee == nil)
    }

    @Test("Keys: ⌘A, arrows, Space, ⌘C, ⌘O, ⌘F, ⌘Z and Esc")
    func keys() throws {
        let scene = F.scene()
        let rec = SceneRecorder(scene)
        let sel = try #require(scene.selection)
        #expect(!scene.handleKey(.quickLook), "nothing selected: nothing to look at")
        #expect(scene.handleKey(.move(dx: 1, dy: 0)) && sel.keys == [F.key(1)])
        #expect(scene.handleKey(.move(dx: 1, dy: 0)) && sel.keys == [F.key(2)])
        #expect(scene.handleKey(.move(dx: 0, dy: 1)) && sel.keys == [F.key(11)])
        #expect(scene.handleKey(.move(dx: -1, dy: 0)) && sel.keys == [F.key(10)])
        #expect(scene.handleKey(.quickLook) && rec.actions.last == "requestQuickLook([\(F.key(10))])")
        #expect(scene.handleKey(.copy) && rec.actions.last == "requestCopy([\(F.key(10))])")
        #expect(scene.handleKey(.open) && rec.actions.last == "requestOpen([\(F.key(10))])")
        #expect(scene.handleKey(.selectAll) && sel.count == F.names.count)
        #expect(scene.handleKey(.undo) && rec.actions.last == "undo")
        #expect(scene.handleKey(.redo) && rec.actions.last == "redo")
        #expect(scene.handleKey(.find) && rec.requests.last == .inventory)
        #expect(scene.handleKey(.escape) && sel.isEmpty)
        #expect(!scene.handleKey(.escape))
    }

    @Test("Right-click: the token menu (selecting the token), the monitor menu on glass, the desk menu on the wall")
    func menus() throws {
        let scene = F.scene()
        let rec = SceneRecorder(scene)
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let layout = try #require(scene.layout)
        _ = p.event(.rightDown, F.centre(try #require(screen.iconRect(of: F.key(4)))), count: 1)
        guard case let .menu(tokenMenu, _)? = rec.requests.last else { Issue.record("no menu"); return }
        #expect(tokenMenu.item("open")?.command == .open([F.key(4)]) && scene.selection?.keys == [F.key(4)])
        _ = p.event(.rightDown, F.centre(screen.cellRect(8, 4)), count: 1)
        guard case let .menu(monitorMenu, _)? = rec.requests.last else { Issue.record("no menu"); return }
        #expect(monitorMenu.item("input.av") != nil)
        _ = p.event(.rightDown, SIMD2(Float(layout.coreOrigin.x + 260), Float(layout.coreOrigin.y + 4)), count: 1)
        guard case let .menu(deskMenu, _)? = rec.requests.last else { Issue.record("no menu"); return }
        #expect(deskMenu.item("lights.lamp") != nil && deskMenu.item("takeEverythingOut") != nil)
        #expect(scene.contextMenu(at: ArtPoint(layout.coreOrigin.x + 260, layout.coreOrigin.y + 4)) == deskMenu)
    }

    @Test("Hover rings a token and labels it at once; its tooltip (kind and date; the full NFC name when the label is shortened) waits 250 ms, sits above on the glass and renders once")
    func hoverAndTooltip() throws {
        let scene = F.scene()
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let r = try #require(screen.iconRect(of: F.key(1)))
        #expect(p.event(.move, F.centre(r)))
        #expect(scene.room?.hovered?.token == F.key(1) && screen.hovered == F.key(1))
        #expect(screen.labelRects.map(\.key) == [F.key(1)])
        #expect(scene.tooltipShown == nil && scene.nextInputDeadline != nil && !scene.needsFrames)
        #expect(!scene.advanceInput(to: p.t + 0.1))
        #expect(scene.advanceInput(to: p.t + 0.26))
        let tip = try #require(scene.tooltipShown)
        #expect(tip.title.hasPrefix("PDF document · ") && tip.detail == nil, "the name is already on the label")
        let tipRect = try #require(scene.room?.tooltip.rect)
        #expect(screen.screenRect.contains(tipRect), "screen tooltips stay on the glass")
        #expect(!tipRect.intersects(r) && !tipRect.intersects(screen.labelRects[0].rect))
        // Moving off hides it; nothing animates meanwhile.
        #expect(p.event(.move, SIMD2(1, 1)))
        #expect(scene.tooltipShown == nil && !scene.needsFrames)
        // Room objects have tooltips too, kept at full light by the lit pass.
        let clock = try #require(scene.layout?.anchors["clock"])
        _ = p.event(.move, F.centre(clock))
        #expect(scene.advanceInput(to: p.t + 0.3) && scene.tooltipShown?.title == "Clock")
        let lit = try #require(scene.room?.tooltip.rect)
        #expect(scene.lighting.mask[lit.midY * scene.grid.artSize.w + lit.midX] & 7 == 7)
        // NFD names are shown in NFC; a name the label shortens is given in full.
        var s = F.state([String(repeating: "\u{1100}\u{1161}", count: 12) + ".txt"])
        s.access = .connected
        scene.apply(s)
        let r2 = try #require(screen.iconRect(of: F.key(1)))
        _ = p.event(.move, F.centre(r2))
        _ = scene.advanceInput(to: p.t + 1)
        #expect(scene.tooltipShown?.title == String(repeating: "가", count: 12) + ".txt")
        #expect(scene.tooltipShown?.detail?.hasPrefix("Plain text") == true)
    }

    @Test("Print-in, pulse and poof play and end")
    func animations() throws {
        let scene = F.scene()
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        scene.play(.printIn, .tokens([F.key(1), F.key(2)]))
        scene.play(.pulse, .token(F.key(3)))
        scene.play(.poof, .location(.screen(page: 0, col: 8, row: 4)))
        #expect(scene.needsFrames && screen.needsFrames)
        p.frames(Int(ScreenElement.pulseDuration * 60) + 2)
        #expect(!scene.needsFrames)
    }

    @Test("Screen goldens: tokens by day and by night, with a selection, a hovered label and the alias/tag marks",
          arguments: [(10, "day"), (22, "night")])
    func golden(hour: Int, name: String) throws {
        var s = F.state()
        s.tokens.updateMeta(F.key(6), TokenMeta(name: "song.mp3", kind: .audio, added: F.t0, isAlias: true))
        let scene = F.scene(s, time: WallTime(hour: hour, minute: 0))
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        p.click(F.centre(try #require(screen.iconRect(of: F.key(1)))))
        p.click(F.centre(try #require(screen.iconRect(of: F.key(3)))), mods: .command)
        _ = p.event(.move, F.centre(try #require(screen.iconRect(of: F.key(8)))))
        let sky = try #require(scene.roomState).sky
        var c = PixelCanvas(MonitorArt.deskOSWallpaper(sky: sky))
        c.blit(screen.compose(), at: .zero)
        #expect(c.buffer.pixels.allSatisfy { Apollo.index(of: $0) != nil })
        #expect(Golden.match(c.buffer, "screen-tokens-\(name)"))
    }
}

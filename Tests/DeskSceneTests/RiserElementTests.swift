import DeskCore
import Foundation
import Testing
@testable import DeskScene

/// Desks with tokens already hidden away, and helpers to run the scene until it rests.
enum ContainerFixture {
    typealias F = SceneFixture

    /// The 13 fixture tokens on the screen, plus `extra` more; then `moves` applied (key index → container).
    static func state(extra: Int = 0, _ moves: [(UInt64, ContainerID)] = []) -> DeskState {
        var s = F.state(F.names + (0..<extra).map { "extra \($0).txt" })
        var order: [ContainerID: Int] = [:]
        for (k, id) in moves {
            s.tokens.move(F.key(k), to: .container(id, order: order[id, default: 0]))
            order[id, default: 0] += 1
        }
        return s
    }

    static func room(_ scene: DeskScene) throws -> RoomContent { try #require(scene.room) }

    /// Steps until nothing animates (at most `max` frames); the frames it took.
    @discardableResult
    static func settle(_ p: Pointer, max: Int = 900) -> Int {
        var n = 0
        while p.scene.needsFrames, n < max {
            p.frames(1)
            n += 1
        }
        return n
    }

    static func centre(_ r: ArtRect) -> SIMD2<Float> { F.centre(r) }
}

@Suite("Riser element")
struct RiserElementTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture

    @Test("The riser takes its slot: fronts, pulls, interiors, cubby and body hit-test; its sprites replace the room's")
    func slot() throws {
        let bare = F.scene(nil)
        let a = try #require(bare.layout).anchors
        #expect(bare.hitTest(a.point("riser.drawerL.handle")!)?.part == "riser.drawerL.handle")
        let frontR = try #require(a["riser.drawerR"])
        #expect(bare.hitTest(ArtPoint(frontR.minX + 3, frontR.midY))?.part == "riser.drawerR")
        #expect(bare.hitTest(a.point("riser.cubby")!)?.part == "riser.cubby")
        let bareRoom = try C.room(bare)
        let placed = try #require(bareRoom.elements.first { $0.id == "riser" })
        #expect(placed.root.children.allSatisfy { !$0.isHidden }, "the bare room keeps drawing the room's riser")

        let store = SceneStore(C.state())
        let room = try C.room(store.scene)
        let riser = try #require(room.riserElement)
        #expect(room.routing.contains { $0 === riser } && !room.routing.contains { $0.id == "riser" && $0 !== riser })
        let hidden = try #require(room.elements.first { $0.id == "riser" })
        #expect(hidden.root.children.allSatisfy { $0.isHidden })
        #expect(riser.root.children.allSatisfy { !$0.isHidden })
        let top = try #require(store.scene.layout).rect(CoreLayout.riser)
        #expect(store.scene.hitTest(ArtPoint(top.midX - 40, top.minY + 2))?.element == "riser")
        #expect(riser.tooltip(Hit(element: "riser", part: "riser.drawerL", rect: .zero))?.title == "Left Riser Drawer")
        #expect(!store.scene.needsFrames)
    }

    @Test("A drop on a shut front chomps: one move, the drawer gapes 6 px, the token slides in as an icon, it shuts")
    func chomp() throws {
        let store = SceneStore(C.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let room = try C.room(scene)
        let unit = try #require(room.riserElement?.unit(.riserLeft))
        let screen = try #require(scene.screen)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(1)))), F.centre(unit.front))
        #expect(store.actions.first == "move([\(F.key(1))], to: riserLeft#0)")
        #expect(unit.sim.isChomping && unit.entering == [F.key(1)])
        var widest = 0
        var sawIcon = false
        for _ in 0..<40 {
            p.frames(1)
            widest = max(widest, unit.pixel)
            if unit.marks(hidden: [], selected: [], raised: []).shown == [0] { sawIcon = true }
        }
        #expect(widest == 6 && sawIcon)
        C.settle(p)
        #expect(unit.pixel == 0 && unit.entering.isEmpty && !scene.needsFrames)
        #expect(store.state.drawerOpening(.riserLeft) == 0 && store.state.tokens.location(of: F.key(1)) == .container(.riserLeft, order: 0))
        #expect(scene.containerMinis.isEmpty && Visibility.of(.container(.riserLeft, order: 0), store.state).isHidden)
    }

    @Test("A click opens a drawer (one more than half open closes); open, its minis are tokens on show")
    func clickOpenMinis() throws {
        let store = SceneStore(C.state([(1, .riserLeft), (2, .riserLeft), (3, .riserLeft)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let riser = try #require(try C.room(scene).riserElement)
        let unit = try #require(riser.unit(.riserLeft))
        #expect(scene.miniRect(of: F.key(1)) == nil && riser.shownTokens.isEmpty)
        p.click(F.centre(unit.handle))
        C.settle(p)
        #expect(store.actions.contains("drawerSettled(DeskCore.ContainerID.riserLeft, 10.0)"))
        #expect(store.state.drawerOpening(.riserLeft) == 10 && scene.containerMinis == [F.key(1), F.key(2), F.key(3)])
        // Each mini answers where it is drawn; hover names it; a click selects; a double-click opens.
        let r2 = try #require(scene.miniRect(of: F.key(2)))
        let hit = try #require(scene.hitTest(r2.center))
        #expect(hit.token == F.key(2) && hit.element == "riser")
        #expect(riser.tooltip(hit)?.title == "IMG_0001.png")
        p.click(F.centre(r2))
        #expect(scene.selection?.keys == [F.key(2)])
        p.click(F.centre(r2), count: 2)
        #expect(store.opens == ["requestOpen([\(F.key(2))])"])
        _ = p.event(.rightDown, F.centre(r2), count: 1)
        guard case let .menu(menu, _)? = store.requests.last else { Issue.record("no menu"); return }
        #expect(menu.item("open")?.command == .open([F.key(2)]) && menu.item("moveTo.monitor") != nil)
        // The pull moved out with the front; a click on it now shuts the drawer and the selection goes with it.
        p.click(F.centre(unit.handle))
        C.settle(p)
        #expect(store.state.drawerOpening(.riserLeft) == 0 && scene.containerMinis.isEmpty)
        #expect(scene.selection?.isEmpty == true && !scene.handleKey(.open))
        // The container menu opens and lists it.
        _ = p.event(.rightDown, F.centre(unit.front), count: 1)
        guard case let .menu(drawerMenu, _)? = store.requests.last else { Issue.record("no drawer menu"); return }
        #expect(drawerMenu.item("open")?.command == .openContainer(.riserLeft))
        #expect(drawerMenu.item("list.0")?.title == "IMG_0001.png")
    }

    @Test("Dragging a mini out carries it (not drawn inside meanwhile) and drops it on the screen in one move")
    func dragOut() throws {
        var s = C.state([(1, .riserLeft), (2, .riserLeft)])
        s.drawers[.riserLeft] = DrawerState(p: 10)
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let riser = try #require(try C.room(scene).riserElement)
        let screen = try #require(scene.screen)
        let from = F.centre(try #require(scene.miniRect(of: F.key(1))))
        let to = F.centre(screen.cellRect(7, 3))
        p.drag(from, to, hold: true)
        #expect(scene.isDragging && screen.carried == [F.key(1)])
        #expect(riser.drawerImage(.riserLeft) != nil)
        #expect(riser.unit(.riserLeft)?.look(hidden: screen.carried, selected: [], raised: []).marks.hidden == [0])
        #expect(scene.hitTest(ArtPoint(Int(from.x), Int(from.y)))?.token != F.key(1), "a mini in hand is not there")
        _ = p.event(.up, to, count: 1)
        #expect(store.actions.last == "move([\(F.key(1))], to: screen p0(7,3))")
        p.frames(2)
        #expect(scene.containerMinis == [F.key(2)])
    }

    @Test("A scroll peeks a shut drawer (paper only), and it slides shut 0.35 s after the last scroll")
    func peek() throws {
        let store = SceneStore(C.state([(1, .riserRight)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let unit = try #require(try C.room(scene).riserElement?.unit(.riserRight))
        _ = p.event(.scroll, F.centre(unit.front), scroll: SIMD2(0, 3))
        p.frames(12)
        #expect(unit.pixel == 3 && !unit.sim.isRevealed && scene.containerMinis.isEmpty)
        _ = p.event(.scroll, F.centre(unit.front), scroll: SIMD2(0, 3))
        p.frames(12)
        #expect(unit.pixel == 4, "at most 4 px")
        C.settle(p)
        #expect(unit.pixel == 0 && store.state.drawerOpening(.riserRight) == 0)
    }

    @Test("Jammed at its hard cap: it rests 6 px out, a close boings back off the gap, further drops bonk (golden frame)")
    func jam() throws {
        let moves = (1...14).map { (UInt64($0), ContainerID.riserLeft) }
        var s = C.state(extra: 4, moves)
        s.drawers[.riserLeft] = DrawerState(p: 6)
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let riser = try #require(try C.room(scene).riserElement)
        let unit = try #require(riser.unit(.riserLeft))
        #expect(unit.sim.isJammed && unit.pixel == 6)
        p.click(F.centre(unit.handle))
        C.settle(p)
        #expect(unit.pixel == 10)
        p.click(F.centre(unit.handle))
        // Watch it shut onto the gap and bounce back out; keep the frame at the top of the boing.
        var sawGap = false
        var peak: (p: Float, image: PixelBuffer)?
        var previous = unit.sim.p
        for _ in 0..<90 {
            p.frames(1)
            let now = unit.sim.p
            if now <= 6.01 { sawGap = true }
            if sawGap, now > previous, now > (peak?.p ?? 0) { peak = (now, try #require(riser.drawerImage(.riserLeft))) }
            previous = now
        }
        #expect(sawGap)
        let boing = try #require(peak)
        #expect(boing.p > 6.5 && boing.p < 8, "it overshoots about a pixel (Errata 13): \(boing.p)")
        #expect(Golden.match(boing.image, "riser-jam-boing"))
        C.settle(p)
        #expect(unit.pixel == 6 && store.state.drawerOpening(.riserLeft) == 6)
        // The next drop bonks with "That's full.".
        let screen = try #require(scene.screen)
        let before = store.actions.count
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(15)))), F.centre(unit.front))
        #expect(store.actions.count == before && scene.bonkCount == 1 && scene.toastShown == .containerFull)
        #expect(riser.dropVerdict([F.key(15)], at: unit.front.center) == .bonk(.containerFull))
        #expect(riser.dropVerdict([F.key(1)], at: unit.front.center) == .accept(.container(.riserLeft, order: 14)),
                "a member dropped back only reorders")
    }

    @Test("Spring-loading: a carry resting 0.6 s on the shut front opens it; dropped inside, it shuts 0.8 s later")
    func springLoading() throws {
        let store = SceneStore(C.state([(1, .riserRight)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let unit = try #require(try C.room(scene).riserElement?.unit(.riserRight))
        let screen = try #require(scene.screen)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(2)))), F.centre(unit.front), hold: true)
        p.frames(30)
        #expect(unit.pixel == 0, "not yet")
        p.frames(16)
        #expect(unit.springOpened && unit.sim.isRevealed)
        p.frames(20)
        #expect(unit.pixel == 10 && scene.isDragging)
        _ = p.event(.up, F.centre(unit.closedFront), count: 1)
        #expect(store.actions.last == "move([\(F.key(2))], to: riserRight#1)")
        p.frames(30)
        #expect(unit.pixel == 10, "it waits 0.8 s")
        C.settle(p)
        #expect(unit.pixel == 0 && store.state.tokens.location(of: F.key(2)) == .container(.riserRight, order: 1))
        // A carry that leaves again lets it shut too, with nothing dropped.
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(3)))), F.centre(unit.front), hold: true)
        p.frames(60)
        #expect(unit.pixel == 10)
        _ = p.event(.drag, F.centre(screen.cellRect(8, 4)))
        p.frames(80)
        #expect(unit.pixel == 0 && scene.isDragging)
        _ = p.event(.up, F.centre(screen.cellRect(8, 4)), count: 1)
        #expect(store.state.tokens.location(of: F.key(3))?.isScreen == true)
    }

    @Test("Cubby: drops go in; dim silhouettes hover with their names, select, and drag back out")
    func cubby() throws {
        let store = SceneStore(C.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let riser = try #require(try C.room(scene).riserElement)
        let screen = try #require(scene.screen)
        let cubby = riser.cubbyRect
        for k: UInt64 in [1, 2, 3] {
            p.drag(F.centre(try #require(screen.iconRect(of: F.key(k)))), F.centre(cubby))
            p.frames(8)
        }
        #expect(store.state.tokens.members(of: .riserCubby) == [F.key(1), F.key(2), F.key(3)])
        #expect(riser.shownTokens == [F.key(1), F.key(2), F.key(3)])
        let r = try #require(scene.miniRect(of: F.key(2)))
        let hit = try #require(scene.hitTest(r.center))
        #expect(hit.token == F.key(2) && riser.tooltip(hit)?.title == "IMG_0001.png")
        if case .image = riser.hoverStyle(hit) {} else { Issue.record("a mini rings on hover") }
        p.click(F.centre(r))
        #expect(scene.selection?.keys == [F.key(2)])
        p.drag(F.centre(r), F.centre(screen.cellRect(8, 3)))
        #expect(store.actions.last == "move([\(F.key(2))], to: screen p0(8,3))")
        // A full cubby (12) bonks.
        #expect(riser.dropVerdict([F.key(4)], at: cubby.center) == .accept(.container(.riserCubby, order: 2)))
        let many = (4...13).map { F.key(UInt64($0)) }
        #expect(riser.dropVerdict(many + [F.key(1)], at: cubby.center) == .accept(.container(.riserCubby, order: 2)),
                "eleven movers (one already inside) and one staying fit twelve")
        #expect(riser.dropVerdict(many + [F.key(2)], at: cubby.center) == .bonk(.containerFull))
    }

    @Test("A flick shut slams (puff, shake, the knock hook); a knock snaps an ajar drawer shut; membership never changes")
    func slamAndKnock() throws {
        var s = C.state([(1, .riserLeft)])
        s.drawers[.riserLeft] = DrawerState(p: 10)
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let room = try C.room(scene)
        let unit = try #require(room.riserElement?.unit(.riserLeft))
        var slams: [(ContainerID, Float)] = []
        room.onDrawerSlam { slams.append(($0, $1)) }
        let from = F.centre(unit.handle)
        _ = p.event(.move, from)
        _ = p.event(.down, from, count: 1)
        for k in 1...3 {
            _ = p.event(.drag, from - SIMD2(0, Float(k) * 6))
            scene.step(1.0 / 60)
        }
        _ = p.event(.up, from - SIMD2(0, 24), count: 1)
        for _ in 0..<30 where slams.isEmpty { p.frames(1) }
        #expect(slams.count == 1 && slams.first?.0 == .riserLeft && (slams.first?.1 ?? 0) > 120)
        #expect(room.context.shakeFrames > 0 || room.context.fx.count > 0)
        C.settle(p)
        #expect(store.state.tokens.location(of: F.key(1)) == .container(.riserLeft, order: 0))

        // A knock: the right drawer ajar 3 px snaps shut; the left one's contents hop; nobody moves house.
        var t = store.state
        t.drawers[.riserRight] = DrawerState(p: 3)
        store.state = t
        scene.apply(t)
        C.settle(p)
        #expect(room.drawerSims[.riserRight]?.p == 3)
        let plan = DeskKnock.plan(for: t, drawers: room.drawerSims, origin: SIMD2(256, 40), strength: 1, seed: 3)
        #expect(plan.drawerCloses.contains(.riserRight))
        room.knockContainers(plan)
        C.settle(p)
        #expect(store.state.drawerOpening(.riserRight) == 0 && store.state.tokens.location(of: F.key(1)) == .container(.riserLeft, order: 0))
    }

    @Test("Show on Desk opens a token's drawer and selects it once on show; a removed file wiggles the pull")
    func showOnDesk() throws {
        let store = SceneStore(C.state([(1, .riserRight), (2, .riserRight)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let unit = try #require(try C.room(scene).riserElement?.unit(.riserRight))
        store.dispatch(.showOnDesk(F.key(2)))
        #expect(scene.selection?.isEmpty == true)
        C.settle(p)
        #expect(unit.pixel == 10 && scene.selection?.keys == [F.key(2)])
        scene.play(.handleWiggle, .container(.riserRight))
        #expect(unit.wiggleDX != 0 && scene.needsFrames)
        C.settle(p)
        #expect(unit.wiggleDX == 0)
    }

    @Test("Hard sleep stops every drawer where it is, commits it, and the scene goes idle")
    func hardSleep() throws {
        let store = SceneStore(C.state([(1, .riserLeft)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let unit = try #require(try C.room(scene).riserElement?.unit(.riserLeft))
        p.click(F.centre(unit.handle))
        p.frames(3)
        #expect(scene.needsFrames && unit.pixel > 0 && unit.pixel < 10)
        scene.forceRest()
        #expect(!scene.needsFrames)
        #expect(store.state.drawerOpening(.riserLeft) == Float(unit.pixel))
    }
}

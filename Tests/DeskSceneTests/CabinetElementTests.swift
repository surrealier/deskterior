import DeskCore
import Foundation
import Testing
@testable import DeskScene

@Suite("Cabinet element")
struct CabinetElementTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture

    @Test("The cabinet keeps its anchors' parts; its sprite replaces the room's once a model arrives")
    func slot() throws {
        let bare = F.scene(nil)
        let a = try #require(bare.layout).anchors
        #expect(bare.hitTest(a.point("cabinet.top.handle")!)?.part == "cabinet.top.handle")
        #expect(bare.hitTest(a.point("cabinet.file")!)?.part == "cabinet.file")
        #expect(bare.hitTest(a.point("cabinet.middle")!)?.element == "cabinet")
        let store = SceneStore(C.state())
        let room = try C.room(store.scene)
        #expect(try #require(room.elements.first { $0.id == "cabinet" }).root.children.allSatisfy { $0.isHidden })
        let cabinet = try #require(room.cabinetElement)
        #expect(cabinet.drawnImage.size == StorageArt.cabinet().size)
        #expect(cabinet.tooltip(Hit(element: "cabinet", part: "cabinet.file", rect: .zero))?.title == "File Drawer")
    }

    @Test("Interlocked: opening one drawer shuts the open one; a chomp into another shuts it too")
    func interlock() throws {
        var s = C.state([(1, .cabinetMiddle)])
        s.drawers[.cabinetMiddle] = DrawerState(p: 14)
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let cabinet = try #require(try C.room(scene).cabinetElement)
        let top = try #require(cabinet.unit(.cabinetTop)), middle = try #require(cabinet.unit(.cabinetMiddle))
        let file = try #require(cabinet.unit(.cabinetFile))
        #expect(scene.containerMinis == [F.key(1)])
        p.click(F.centre(top.handle))
        C.settle(p)
        #expect(top.pixel == 12 && middle.pixel == 0)
        #expect(store.state.drawerOpening(.cabinetTop) == 12 && store.state.drawerOpening(.cabinetMiddle) == 0)
        let screen = try #require(scene.screen)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(2)))), F.centre(file.front))
        p.frames(4)
        #expect(file.sim.isChomping && top.sim.p < 12)
        C.settle(p)
        #expect(top.pixel == 0 && file.pixel == 0 && store.state.tokens.location(of: F.key(2)) == .container(.cabinetFile, order: 0))
    }

    @Test("The chair in front blocks the drawers: a click opens 3 px and thunks it aside; then the drawer opens all the way")
    func chairBlock() throws {
        var s = C.state()
        s.chair.x = 350
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let room = try C.room(scene)
        let cabinet = try #require(room.cabinetElement), chair = try #require(room.chairElement)
        let top = try #require(cabinet.unit(.cabinetTop))
        p.frames(1)
        #expect(top.sim.openLimit == 3)
        #expect(scene.hitTest(top.handle.center)?.part == "cabinet.top.handle", "the pull shows beside the seat")
        p.click(F.centre(top.handle))
        var pushed = false
        for _ in 0..<40 {
            p.frames(1)
            if chair.sim.v < -100 { pushed = true }
        }
        #expect(pushed, "the thunk sends the chair rolling away from the cabinet")
        C.settle(p)
        #expect(top.pixel == 3 && store.state.drawerOpening(.cabinetTop) == 3)
        #expect(store.state.chair.x < RollerSim.cabinetBlockX() && top.sim.openLimit == 12)
        p.click(F.centre(top.handle))
        C.settle(p)
        #expect(top.pixel == 12 && store.state.drawerOpening(.cabinetTop) == 12)
        // Open, it stops the chair rolling back in.
        #expect(cabinet.blocksChair)
        let seat = F.centre(chair.seatRect)
        p.drag(seat, seat + SIMD2(120, 0))
        C.settle(p)
        #expect(store.state.chair.x <= RollerSim.cabinetBlockX() + 0.5)
    }

    @Test("Show on Desk with the chair in the way: the chair rolls clear, the drawer opens, the token is selected")
    func showOnDesk() throws {
        var s = C.state([(1, .cabinetTop)])
        s.chair.x = 380
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let cabinet = try #require(try C.room(scene).cabinetElement)
        p.frames(1)
        store.dispatch(.showOnDesk(F.key(1)))
        C.settle(p)
        #expect(cabinet.unit(.cabinetTop)?.pixel == 12 && store.state.drawerOpening(.cabinetTop) == 12)
        #expect(store.state.chair.x <= RollerSim.cabinetBlockX())
        #expect(scene.selection?.keys == [F.key(1)])
    }

    @Test("The file drawer hangs folders: tabs carry initials; hover names a folder; it drags out")
    func fileDrawer() throws {
        var s = C.state([(1, .cabinetFile), (2, .cabinetFile), (4, .cabinetFile), (13, .cabinetFile)])
        s.drawers[.cabinetFile] = DrawerState(p: 18)
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let cabinet = try #require(try C.room(scene).cabinetElement)
        p.frames(1)
        #expect(scene.containerMinis.count == 4)
        let r = try #require(scene.miniRect(of: F.key(4)))
        let hit = try #require(scene.hitTest(r.center))
        #expect(hit.token == F.key(4) && cabinet.tooltip(hit)?.title == "Projects")
        p.click(F.centre(r))
        #expect(scene.selection?.keys == [F.key(4)])
        p.frames(1)
        let file = try #require(cabinet.unit(.cabinetFile))
        let cropped = cabinet.drawnImage.cropped(to: file.contentClip.offsetBy(-cabinet.spriteOrigin.x, -cabinet.spriteOrigin.y))
        #expect(Golden.match(cropped, "cabinet-file-tabs-selected"))
        let screen = try #require(scene.screen)
        p.drag(F.centre(r), F.centre(screen.cellRect(8, 4)))
        #expect(store.actions.last == "move([\(F.key(4))], to: screen p0(8,4))")
    }
}

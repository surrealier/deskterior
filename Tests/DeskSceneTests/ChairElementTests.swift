import DeskCore
import Foundation
import Testing
@testable import DeskScene

@Suite("Chair element")
struct ChairElementTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture

    @Test("The chair starts where the model says, replaces the room's sprite, and hit-tests by its pixels")
    func place() throws {
        var s = C.state()
        s.chair = ChairState(x: 120, facing: 2)
        let store = SceneStore(s)
        let room = try C.room(store.scene)
        let chair = try #require(room.chairElement)
        let layout = try #require(store.scene.layout)
        #expect(chair.sim.pixelX == 120 && chair.sim.chairFacing == .front)
        #expect(chair.origin == layout.point(ArtPoint(120, CoreLayout.chair.y)))
        #expect(try #require(room.elements.first { $0.id == "chair" }).root.children.allSatisfy { $0.isHidden })
        #expect(store.scene.hitTest(chair.seatRect.center)?.element == "chair")
        #expect(store.scene.hitTest(layout.point(ArtPoint(122, CoreLayout.chair.y + 1)))?.element != "chair", "a clear corner")
        #expect(chair.tooltip(Hit(element: "chair", part: nil, rect: chair.rect))?.title == "Chair")
        #expect(store.scene.chairX == 120)
    }

    @Test("A drag rolls it; a slow release stays; it commits x and facing once at rest, then idles")
    func drag() throws {
        let store = SceneStore(C.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let chair = try #require(try C.room(scene).chairElement)
        let x0 = chair.sim.x
        let seat = F.centre(chair.seatRect)
        p.drag(seat, seat + SIMD2(-60, 0), steps: 30, hold: true)
        p.frames(6)
        #expect(abs(chair.sim.x - (x0 - 60)) <= 1)
        _ = p.event(.up, seat + SIMD2(-60, 0), count: 1)
        C.settle(p)
        #expect(abs(store.state.chair.x - (x0 - 60)) <= 1 && !scene.needsFrames)
        #expect(store.actions.filter { $0.hasPrefix("chair(") }.count == 1)
    }

    @Test("A fling coasts on (60% of the release), spins through facings, and bounces off the travel's end")
    func fling() throws {
        for (start, bounces) in [(Float(400), false), (130, true)] {
            var s = C.state()
            s.chair.x = start
            let store = SceneStore(s)
            let scene = store.scene
            let p = Pointer(scene: scene)
            let chair = try #require(try C.room(scene).chairElement)
            let seat = F.centre(chair.seatRect)
            p.drag(seat, seat + SIMD2(-60, 0), steps: 3)
            let released = chair.sim.x
            var facings = Set<Int>()
            var minX = Float.infinity
            for _ in 0..<900 where scene.needsFrames {
                p.frames(1)
                facings.insert(chair.sim.facing)
                minX = min(minX, chair.sim.x)
            }
            #expect(minX < released - (bounces ? 4 : 40), "it coasts on past the release")
            #expect(facings.count > 1, "a fast roll spins it")
            #expect(minX >= Float(CoreLayout.chairTravel.lowerBound))
            #expect((minX == Float(CoreLayout.chairTravel.lowerBound)) == bounces)
            if bounces { #expect(store.state.chair.x > minX + 2, "it bounced back off the desk leg") }
            #expect(store.state.chair.facing == chair.sim.facing && !scene.needsFrames)
        }
    }

    @Test("The model moving the chair (Show on Desk clearing the cabinet) rolls it there")
    func modelRoll() throws {
        var s = C.state()
        s.chair.x = 400
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let chair = try #require(try C.room(scene).chairElement)
        var t = store.state
        t.chair.x = 300
        store.state = t
        scene.apply(t)
        p.frames(2)
        #expect(chair.sim.x < 400 && chair.sim.x > 300, "rolling, not jumping")
        C.settle(p)
        #expect(abs(chair.sim.x - 300) <= 3 && abs(store.state.chair.x - chair.sim.x) < 0.01)
    }
}

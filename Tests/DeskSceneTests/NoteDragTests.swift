import DeskCore
import DeskPixels
import Foundation
import Testing
@testable import DeskScene

/// Sticky notes in hand (Erratum 31): `NoteDrag`, `PageTear` and `CubePeel`.
@Suite("Note drags")
struct NoteDragTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture
    typealias M = MemoFixture

    @Test("A note dragged across the felt shows a ghost where it would rest and rests there (Move Note)")
    func snapsToTheGhost() throws {
        let store = SceneStore(M.state([M.note(1, "우유 사기", at: M.tower)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let partition = try M.partition(scene)
        let from = F.centre(try #require(scene.noteRect(NoteID(1))))
        let to = M.point(scene, core: 449, 152)
        p.drag(from, to, hold: true)
        let drag = try #require(try C.room(scene).router.drag as? NoteDrag)
        #expect(drag.kind == .move(NoteID(1)) && drag.spot == ArtPoint(434, 140))
        #expect(!drag.ghost.isHidden && partition.lifted == [NoteID(1)])
        _ = p.event(.up, to, count: 1)
        #expect(store.actions.last == "\(DeskAction.moveNote(NoteID(1), to: ArtPoint(434, 140)))")
        #expect(partition.lifted.isEmpty && drag.isFinished)
        C.settle(p)
        #expect(!scene.needsFrames)
    }

    @Test("Let go where no note can rest, it springs back over six frames (at once with Reduce Motion); nothing changes")
    func springsBack() throws {
        for reduce in [false, true] {
            let store = SceneStore(M.state([M.note(1, "a", at: M.tower)]))
            let scene = store.scene
            scene.reduceMotion = reduce
            let room = try C.room(scene)
            let image = try #require(try M.partition(scene).noteImage(NoteID(1)))
            let home = try #require(scene.noteRect(NoteID(1))).origin
            var finished = 0
            let wall = M.point(scene, core: 260, 4)
            let drag = NoteDrag(kind: .move(NoteID(1)), colour: .yellow, image: image, home: home, grab: ArtPoint(15, 12),
                                pointer: wall, context: room.context) { finished += 1 }
            #expect(drag.spot == nil && drag.ghost.isHidden)
            drag.ended(at: wall, velocity: .zero, mods: [])
            #expect(store.actions.isEmpty)
            var frames = 0
            while !drag.isFinished, frames < 20 {
                drag.step(1.0 / 60)
                frames += 1
            }
            #expect(frames == (reduce ? 0 : 6), "reduce \(reduce): \(frames) frames")
            #expect(finished == 1 && drag.node.parent == nil && drag.ghost.parent == nil)
        }
    }

    @Test("Let go over the wastebasket's mouth, the note comes off with a toast and balls up into the basket")
    func intoTheWastebasket() throws {
        let store = SceneStore(M.state([M.note(1, "a", at: M.tower, colour: .pink)]))
        let scene = store.scene
        let room = try C.room(scene)
        let image = try #require(try M.partition(scene).noteImage(NoteID(1)))
        let mouth = try #require(scene.physicsAnchor("wastebasket.mouth"))
        let drag = NoteDrag(kind: .move(NoteID(1)), colour: .pink, image: image, home: .zero, grab: ArtPoint(15, 12),
                            pointer: F.centre(mouth), context: room.context) {}
        #expect(drag.spot == nil, "no ghost over the basket")
        drag.ended(at: F.centre(mouth), velocity: .zero, mods: [])
        #expect(store.actions == ["\(DeskAction.removeNote(NoteID(1)))"])
        #expect(scene.toastShown == .noteRemoved)
        #expect(drag.needsFrames, "the crumple falls in")
        var frames = 0
        while !drag.isFinished, frames < 40 {
            drag.step(1.0 / 60)
            frames += 1
        }
        #expect(frames == 20, "four 12 fps frames: \(frames)")
        // A new note let go there is no note to take off: it springs back.
        let peel = CubePeel(image: image, cube: try M.partition(scene).cubeRect, pointer: F.centre(mouth),
                            context: room.context) {}
        peel.ended(at: F.centre(mouth), velocity: .zero, mods: [])
        #expect(store.actions.count == 1 && peel.needsFrames)
    }

    @Test("Through the pointer: a note dropped on the basket's mouth is taken off; ⌘Z is the reducer's")
    func dropOnBasket() throws {
        let store = SceneStore(M.state([M.note(1, "a", at: M.tower)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let mouth = try #require(scene.physicsAnchor("wastebasket.mouth"))
        p.drag(F.centre(try #require(scene.noteRect(NoteID(1)))), F.centre(mouth))
        #expect(store.actions.last == "\(DeskAction.removeNote(NoteID(1)))")
        #expect(scene.toastShown == .noteRemoved)
        C.settle(p)
        #expect(!scene.needsFrames)
    }

    @Test("Esc cancels a note in hand: it springs back and nothing is dispatched")
    func escCancels() throws {
        let store = SceneStore(M.state([M.note(1, "a", at: M.tower)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let partition = try M.partition(scene)
        p.drag(F.centre(try #require(scene.noteRect(NoteID(1)))), M.point(scene, core: 449, 152), hold: true)
        #expect(scene.isDragging && partition.lifted == [NoteID(1)])
        #expect(scene.handleKey(.escape))
        #expect(!scene.isDragging)
        C.settle(p)
        #expect(partition.lifted.isEmpty && !store.actions.contains { $0.hasPrefix("moveNote") })
    }

    @Test("Tearing today's page off the pad makes it a note where it is let go (Tear Off Page); an empty pad does not tear")
    func tearOff() throws {
        let store = SceneStore(M.state(pages: [M.today: "회의 3시\n자료 준비"]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let a = try #require(scene.layout).anchors
        let pad = F.centre(try #require(a["partition.pad"]))
        p.drag(pad, M.point(scene, core: 419, 152), hold: true)
        let tear = try #require(try C.room(scene).router.drag as? PageTear)
        #expect(tear.kind == .tear(M.today) && tear.colour == .cream && tear.spot == ArtPoint(404, 140))
        #expect(try M.partition(scene).tearing, "the pad's line goes with the page")
        _ = p.event(.up, M.point(scene, core: 419, 152), count: 1)
        #expect(store.actions.last == "\(DeskAction.tearOffPage(M.today, at: ArtPoint(404, 140)))")
        C.settle(p)
        #expect(try !M.partition(scene).tearing && !scene.needsFrames)
        // No page today: the drag is not a tear.
        let empty = SceneStore(M.state())
        let q = Pointer(scene: empty.scene)
        q.drag(pad, M.point(empty.scene, core: 419, 152))
        #expect(!empty.actions.contains { $0.hasPrefix("tearOffPage") })
    }

    @Test("Peeling a note off the cube sticks a new yellow note where it is let go")
    func peelOff() throws {
        let store = SceneStore(M.state([M.note(1, "a", at: M.tower)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let a = try #require(scene.layout).anchors
        let to = M.point(scene, core: 419, 152)
        p.drag(F.centre(try #require(a["partition.cube"])), to, hold: true)
        let peel = try #require(try C.room(scene).router.drag as? CubePeel)
        #expect(peel.kind == .peel && peel.colour == .yellow)
        _ = p.event(.up, to, count: 1)
        let note = NewNote(id: NoteID(2), text: "", colour: .yellow, at: ArtPoint(404, 140))
        #expect(store.actions.last == "\(DeskAction.addNote(note, session: nil))")
        #expect(!store.requests.contains(.command(.editNote(NoteID(2)))), "a peel does not open the editor")
    }

    @Test("On a full partition a peeled or torn note springs back (the reducer refuses it and says so)")
    func fullSpringsBack() throws {
        let spots = PartitionLayout.defaultSpots
        let notes = (1...MemoBook.maxNotes).map { M.note($0, "n\($0)", at: spots[$0 % spots.count]) }
        let store = SceneStore(M.state(notes, pages: [M.today: "x"]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let a = try #require(scene.layout).anchors
        let to = M.point(scene, core: 419, 152)
        p.drag(F.centre(try #require(a["partition.cube"])), to, hold: true)
        let peel = try #require(try C.room(scene).router.drag as? CubePeel)
        _ = p.event(.up, to, count: 1)
        guard case .springing = peel.phase else {
            Issue.record("the peeled note springs back onto the cube, not \(peel.phase)")
            return
        }
        #expect(store.state.memos.notes.count == MemoBook.maxNotes)
        #expect(store.actions.last?.hasPrefix("addNote") == true, "asked all the same, so the toast says why")
        C.settle(p)
        #expect(peel.isFinished && !scene.needsFrames)
        // A torn page springs back to the pad, which shows its page again once it is home.
        p.drag(F.centre(try #require(a["partition.pad"])), to, hold: true)
        let tear = try #require(try C.room(scene).router.drag as? PageTear)
        _ = p.event(.up, to, count: 1)
        guard case .springing = tear.phase else {
            Issue.record("the torn page springs back to the pad, not \(tear.phase)")
            return
        }
        #expect(try M.partition(scene).tearing && store.state.memos.pages[M.today] == "x")
        C.settle(p)
        #expect(try !M.partition(scene).tearing && tear.isFinished && !scene.needsFrames)
    }

    @Test("A peel shows the note coming off a third at a time; a tear curls the page for three frames")
    func peelFrames() throws {
        let store = SceneStore(M.state(pages: [M.today: "x"]))
        let room = try C.room(store.scene)
        let partition = try M.partition(store.scene)
        let image = NoteSprite.image(M.note(1, at: .zero), font: room.context.font)
        let peel = CubePeel(image: image, cube: partition.cubeRect, pointer: [100, 100], context: room.context) {}
        #expect(peel.reveal == image.height / 3)
        for _ in 0..<5 { peel.step(1.0 / 60) }
        #expect(peel.reveal == 2 * image.height / 3)
        for _ in 0..<10 { peel.step(1.0 / 60) }
        #expect(peel.reveal == nil)
        let tear = PageTear(day: M.today, image: image, pad: partition.padRect, pointer: [100, 100],
                            context: room.context) {}
        #expect(tear.needsFrames)
        tear.cancelled()
        for _ in 0..<20 { tear.step(1.0 / 60) }
        #expect(tear.isFinished && !tear.needsFrames)
    }
}

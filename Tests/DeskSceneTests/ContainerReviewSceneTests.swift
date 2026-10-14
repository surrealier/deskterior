import DeskCore
import Foundation
import SpriteKit
import Testing
@testable import DeskScene

/// Regressions from the M6 container review, in the scene: every mini on show answers the pointer (hovered or
/// selected neighbours never take its strip), hidden contents stay hidden through a chomp or a peek, a drop back
/// where a mini came from is no move, the cabinet's pull wiggles, the phone's ring follows its flip, an emptied
/// drawer shuts.
@Suite("Container review (scene)")
struct ContainerReviewSceneTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture

    /// A scene with `n` tokens (inodes from `start`) in `id`, opened all the way.
    static func opened(_ id: ContainerID, n: Int, start: Int) -> SceneStore {
        var s = C.state(extra: 60, (0..<n).map { (UInt64(start + $0), id) })
        if let t = id.spec.travel { s.drawers[id] = DrawerState(p: t) }
        return SceneStore(s)
    }

    @Test("Every mini on show can be hovered and picked, whatever the seeds; selecting or hovering one keeps the rest")
    func everyMiniAnswers() throws {
        let cases: [(ContainerID, [Int])] = [
            (.riserLeft, [8, 11, 14]), (.cabinetMiddle, [12, 18]), (.cabinetFile, [20, 26]), (.riserCubby, [3, 8, 12]),
        ]
        for (id, counts) in cases {
            for n in counts {
                for start in [1, 7, 20, 33] {
                    let store = Self.opened(id, n: n, start: start)
                    let scene = store.scene
                    let p = Pointer(scene: scene)
                    p.frames(1)
                    let members = store.state.tokens.members(of: id)
                    #expect(scene.containerMinis == Set(members), "\(id) n=\(n) start=\(start)")
                    func check(_ label: String) {
                        for k in members {
                            guard let r = scene.miniRect(of: k) else {
                                Issue.record("\(id) n=\(n) start=\(start) \(label): \(k) cannot be picked")
                                continue
                            }
                            #expect(scene.hitTest(r.center)?.token == k, "\(id) n=\(n) start=\(start) \(label)")
                        }
                    }
                    check("plain")
                    // Select one and hover its neighbour: both draw on top, but neither covers another's strip.
                    let a = try #require(scene.miniRect(of: members[n / 2]))
                    p.click(F.centre(a))
                    let b = try #require(scene.miniRect(of: members[n / 2 - 1]))
                    _ = p.event(.move, F.centre(b))
                    #expect(scene.room?.hovered?.token == members[n / 2 - 1])
                    check("selected + hovered")
                }
            }
        }
    }

    @Test("The hovered mini draws in front of its neighbours (and of the selection), so its ring outlines what shows")
    func hoveredOnTop() throws {
        let store = Self.opened(.riserLeft, n: 14, start: 1)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let riser = try #require(try C.room(scene).riserElement)
        let unit = try #require(riser.unit(.riserLeft))
        p.frames(1)
        let members = unit.members
        p.click(F.centre(try #require(scene.miniRect(of: members[5]))))
        _ = p.event(.move, F.centre(try #require(scene.miniRect(of: members[4]))))
        #expect(riser.hoveredKey == members[4])
        let marks = unit.marks(hidden: [], selected: [members[5]], raised: [], hovered: riser.hoveredKey)
        #expect(InteriorRaster.drawOrder(14, open: true, marks: marks) { _ in 0 }.suffix(2) == [5, 4])
        let before = try #require(riser.drawerImage(.riserLeft))
        _ = p.event(.move, SIMD2(1, 1))
        #expect(riser.hoveredKey == nil && riser.drawerImage(.riserLeft) != before)
    }

    @Test("A chomp into, or a peek at, an overfull drawer shows no minis and nothing to pick")
    func overfullStaysHidden() throws {
        for n in [9, 10, 12] {
            var s = C.state(extra: 4, (1...UInt64(n)).map { ($0, ContainerID.riserLeft) })
            s.drawers[.riserLeft] = DrawerState(p: Float(min(6, n - 8)))
            let store = SceneStore(s)
            let scene = store.scene
            let p = Pointer(scene: scene)
            let unit = try #require(try C.room(scene).riserElement?.unit(.riserLeft))
            let screen = try #require(scene.screen)
            p.frames(1)
            p.drag(F.centre(try #require(screen.iconRect(of: F.key(UInt64(n + 1))))), F.centre(unit.front))
            #expect(store.state.tokens.members(of: .riserLeft).count == n + 1)
            for _ in 0..<40 {
                p.frames(1)
                #expect(scene.containerMinis.isEmpty && unit.pixel < 8, "n=\(n) chomp at \(unit.pixel)")
            }
            C.settle(p)
            _ = p.event(.scroll, F.centre(unit.front), scroll: SIMD2(0, 4))
            for _ in 0..<15 {
                p.frames(1)
                #expect(scene.containerMinis.isEmpty && unit.pixel < 8, "n=\(n) peek at \(unit.pixel)")
                let clip = unit.contentClip
                for y in clip.minY..<max(clip.minY, clip.maxY) {
                    #expect(scene.hitTest(ArtPoint(clip.midX, y))?.token == nil)
                }
            }
            C.settle(p)
            #expect(store.state.drawerOpening(.riserLeft) == Float(min(6, n + 1 - 8)))
        }
    }

    @Test("Dropping minis back where they came from is no move: they spring back, the order and undo stay")
    func dropBackHome() throws {
        var s = C.state([(1, .riserLeft), (2, .riserLeft), (3, .riserLeft), (4, .riserCubby), (5, .riserCubby),
                         (6, .phone), (7, .phone)])
        s.drawers[.riserLeft] = DrawerState(p: 10)
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        p.frames(1)
        let before = store.state.tokens
        for k: UInt64 in [1, 4, 6] {
            let r = try #require(scene.miniRect(of: F.key(k)))
            p.drag(F.centre(r), F.centre(r) + SIMD2(5, 0), steps: 3)
            C.settle(p)
            #expect(scene.miniRect(of: F.key(k)) != nil && scene.screen?.carried.isEmpty == true)
        }
        #expect(!store.actions.contains { $0.hasPrefix("move") })
        #expect(store.state.tokens == before && store.journal.undoLabel == nil)
        // Into another container it is a move.
        let r = try #require(scene.miniRect(of: F.key(2)))
        p.drag(F.centre(r), F.centre(try #require(try C.room(scene).riserElement).cubbyRect))
        #expect(store.actions.last == "move([\(F.key(2))], to: riserCubby#2)")
    }

    @Test("A removed file wiggles the cabinet drawer's pull")
    func cabinetWiggle() throws {
        let store = SceneStore(C.state([(1, .cabinetTop)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let cabinet = try #require(try C.room(scene).cabinetElement)
        p.frames(1)
        let still = cabinet.drawnImage
        scene.play(.handleWiggle, .container(.cabinetTop))
        var changed = false
        for _ in 0..<4 {
            p.frames(1)
            changed = changed || cabinet.drawnImage != still
        }
        #expect(changed)
        C.settle(p)
        #expect(cabinet.drawnImage == still)
    }

    @Test("The phone's hover outline follows it through a flip")
    func phoneRingFollowsFlip() throws {
        let store = SceneStore(C.state([(1, .phone)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let room = try C.room(scene)
        let phone = try #require(room.phoneElement)
        p.frames(1)
        let at = SIMD2(Float(phone.phoneRect.midX) + 0.5, Float(phone.phoneRect.maxY) - 2.5)
        _ = p.event(.move, at)
        #expect(room.hovered?.element == "phone")
        let rings = { room.hoverNode.texture }
        let faceUp = rings()
        p.click(at)
        var restyled = 0
        var last = faceUp
        for _ in 0..<30 where scene.needsFrames {
            p.frames(1)
            if rings() !== last { restyled += 1 }
            last = rings()
        }
        #expect(restyled >= 2 && room.hovered?.element == "phone" && !room.hoverNode.isHidden)
    }

    @Test("A selected phone mini is framed in a light ink that stays on the glass")
    func phoneSelection() throws {
        let store = SceneStore(C.state([(1, .phone), (2, .phone)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let phone = try #require(try C.room(scene).phoneElement)
        p.frames(1)
        let plain = phone.drawnImage
        p.click(F.centre(try #require(scene.miniRect(of: F.key(2)))))
        let selected = phone.drawnImage
        let glass = InteriorRaster.phoneGlass
        for y in 0..<plain.height {
            for x in 0..<plain.width where plain.pixel(x, y) != selected.pixel(x, y) {
                #expect(glass.contains(ArtPoint(x, y)), "(\(x),\(y)) is off the glass")
                #expect(selected.pixel(x, y) == InteriorRaster.selectionMark.color)
            }
        }
        #expect(plain != selected)
    }

    @Test("Take All Out of a jammed drawer: emptied, it slides shut from its gap and commits")
    func emptiedShuts() throws {
        var s = C.state(extra: 4, (1...14).map { (UInt64($0), ContainerID.riserLeft) })
        s.drawers[.riserLeft] = DrawerState(p: 6)
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let unit = try #require(try C.room(scene).riserElement?.unit(.riserLeft))
        p.frames(1)
        store.dispatch(.takeAllOut(.riserLeft))
        C.settle(p)
        #expect(unit.pixel == 0 && store.state.drawerOpening(.riserLeft) == 0 && !scene.needsFrames)
    }
}

import DeskCore
import Foundation
import Testing
@testable import DeskScene

@Suite("Phone stand element")
struct PhoneStandElementTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture

    @Test("Drops on the face-up phone become app minis (one move each); a seventh bonks; face down every drop bonks")
    func drops() throws {
        let store = SceneStore(C.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let phone = try #require(try C.room(scene).phoneElement)
        let screen = try #require(scene.screen)
        #expect(try #require(C.room(scene).elements.first { $0.id == "phone" }).root.children.allSatisfy { $0.isHidden })
        for k: UInt64 in 1...6 {
            p.drag(F.centre(try #require(screen.iconRect(of: F.key(k)))), F.centre(phone.phoneRect))
            p.frames(4)
        }
        #expect(store.state.tokens.members(of: .phone) == (1...6).map { F.key($0) })
        #expect(phone.shownTokens.count == 6 && scene.containerMinis.count == 6)
        for k: UInt64 in 1...6 {
            let r = try #require(scene.miniRect(of: F.key(k)))
            #expect(r.size == ArtSize(5, 5) && scene.hitTest(r.center)?.token == F.key(k))
        }
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(7)))), F.centre(phone.phoneRect))
        #expect(scene.bonkCount == 1 && scene.toastShown == .containerFull)
        #expect(Golden.match(phone.drawnImage, "phone-six-minis"))
        var s = store.state
        s.phone.faceDown = true
        store.state = s
        scene.apply(s)
        C.settle(p)
        #expect(phone.dropVerdict([F.key(8)], at: phone.phoneRect.center) == .bonk(nil))
    }

    @Test("A click flips it: the face-down commit comes first and once; the minis hide at once; the flip lands")
    func flip() throws {
        let store = SceneStore(C.state([(1, .phone), (2, .phone)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let phone = try #require(try C.room(scene).phoneElement)
        let r = try #require(scene.miniRect(of: F.key(1)))
        p.click(F.centre(r))
        #expect(scene.selection?.keys == [F.key(1)])
        let stand = SIMD2<Float>(Float(phone.phoneRect.midX) + 0.5, Float(phone.phoneRect.maxY) - 2.5)
        #expect(scene.hitTest(ArtPoint(Int(stand.x), Int(stand.y)))?.part == "phone")
        p.click(stand)
        #expect(store.actions.filter { $0.hasPrefix("phoneFace") } == ["phoneFace(down: true)"])
        #expect(store.state.phone.faceDown && phone.shownTokens.isEmpty && phone.machine.needsFrames)
        p.frames(1)
        #expect(scene.selection?.isEmpty == true && scene.miniRect(of: F.key(1)) == nil)
        #expect(Visibility.of(.container(.phone, order: 0), store.state).isHidden)
        C.settle(p)
        #expect(phone.machine.face == .down && !scene.needsFrames)
        #expect(store.actions.filter { $0.hasPrefix("phoneFace") }.count == 1)
        // Face down: hovering shows no names, only the phone.
        let back = try #require(scene.hitTest(r.center))
        #expect(back.token == nil && phone.tooltip(back)?.detail == "Face down")
        // A second click turns it face up again.
        p.click(stand)
        C.settle(p)
        #expect(!store.state.phone.faceDown && phone.shownTokens == [F.key(1), F.key(2)])
    }

    @Test("The menu turns it; the phone flips to match the model without committing again")
    func menuFlip() throws {
        let store = SceneStore(C.state([(1, .phone)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let phone = try #require(try C.room(scene).phoneElement)
        _ = p.event(.rightDown, F.centre(phone.phoneRect), count: 1)
        guard case let .menu(menu, _)? = store.requests.last else { Issue.record("no menu"); return }
        let item = try #require(menu.item("faceDown"))
        store.dispatch(try #require(item.command?.action(store.state)))
        #expect(store.state.phone.faceDown && phone.machine.needsFrames && phone.machine.state.faceDown)
        var faces: [PropArt.PhoneFace] = []
        for _ in 0..<30 where scene.needsFrames {
            p.frames(1)
            if faces.last != phone.machine.face { faces.append(phone.machine.face) }
        }
        #expect(faces.last == .down && faces.contains(.flip2))
        #expect(store.actions.filter { $0.hasPrefix("phoneFace") }.isEmpty, "the menu's own action was the commit")
    }

    @Test("A mini drags back out to the screen")
    func dragOut() throws {
        let store = SceneStore(C.state([(1, .phone), (2, .phone)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        p.drag(F.centre(try #require(scene.miniRect(of: F.key(2)))), F.centre(screen.cellRect(8, 4)))
        #expect(store.actions.last == "move([\(F.key(2))], to: screen p0(8,4))")
        p.frames(2)
        #expect(scene.containerMinis == [F.key(1)])
    }
}

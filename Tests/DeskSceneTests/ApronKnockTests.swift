import DeskCore
import Foundation
import Testing
@testable import DeskScene

/// The desk knock from the apron (DESIGN §2.2 E11; M6 accept: a knock never changes membership).
@Suite("Desk knock from the apron")
@MainActor
struct ApronKnockTests {
    typealias F = SceneFixture

    /// Token 1 in a pile, token 2 on the floor, token 3 in the pen cup; the left riser drawer ajar by 2 px.
    private func knockDesk() -> DeskState {
        var s = F.state()
        s.tokens.move(F.key(1), to: .desk(pile: "P1", order: 0))
        s.piles["P1"] = [150, 30]
        s.tokens.move(F.key(2), to: .floor(x: 200))
        s.tokens.move(F.key(3), to: .container(.penCup, order: 0))
        s.drawers[.riserLeft] = DrawerState(p: 2)
        return s
    }

    @Test("A double-click left of the chair hops piles 2 px and floor tokens 1 px, wobbles the cup, shuts an ajar drawer; nothing moves house")
    func knockHopsAndShuts() throws {
        let stage = try PhysicsStage(knockDesk(), physics: false)
        let before = stage.state
        let pile = try #require(stage.scene.deskTokenRect(F.key(1)))
        let floor = try #require(stage.scene.deskTokenRect(F.key(2)))
        stage.click(stage.point(core: 120, 238), count: 2)
        #expect(stage.hub.knocks == 1)
        #expect(stage.hub.cup.machine.needsFrames, "the cup wobbles")
        var pileTop = pile.minY, floorTop = floor.minY
        for _ in 0..<30 {
            stage.frames(1)
            pileTop = min(pileTop, try #require(stage.scene.deskTokenRect(F.key(1))).minY)
            floorTop = min(floorTop, try #require(stage.scene.deskTokenRect(F.key(2))).minY)
        }
        stage.settle()
        #expect(pile.minY - pileTop == 2, "the pile hopped 2 px")
        #expect(floor.minY - floorTop == 1, "the floor token hopped 1 px")
        #expect(stage.scene.deskTokenRect(F.key(1)) == pile && stage.scene.deskTokenRect(F.key(2)) == floor, "and came down")
        #expect(stage.state.drawerOpening(.riserLeft) == 0, "the ajar drawer snapped shut")
        // Membership and places are untouched.
        for k in UInt64(1)...UInt64(F.names.count) {
            #expect(stage.location(F.key(k)) == before.tokens.location(of: F.key(k)))
        }
        #expect(stage.state.piles == before.piles)
        #expect(stage.state.penCup.state == PenCupMachine.uprightName)
    }

    @Test("Knocks are 1 s apart: a second double-click inside the cooldown does nothing; a plain click never knocks")
    func cooldown() throws {
        let stage = try PhysicsStage(knockDesk(), physics: false)
        let apron = stage.point(core: 120, 238)
        stage.click(apron)
        #expect(stage.hub.knocks == 0)
        stage.click(apron, count: 2)
        stage.frames(20)
        stage.click(apron, count: 2)
        #expect(stage.hub.knocks == 1)
        stage.frames(60)
        stage.click(apron, count: 2)
        #expect(stage.hub.knocks == 2)
    }
}

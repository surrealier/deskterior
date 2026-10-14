import DeskCore
import Foundation
import Metal
import Testing
@testable import DeskScene

/// A desk with tokens 1…`pens` in the pen cup, the rest on the monitor.
private func cupDesk(pens: Int) -> DeskState {
    var s = SceneFixture.state()
    for i in 0..<pens { s.tokens.move(SceneFixture.key(UInt64(i + 1)), to: .container(.penCup, order: i)) }
    return s
}

@Suite("Pen cup element")
struct PenCupElementTests {
    typealias F = SceneFixture

    @Test("Drops go in as pens; the seventh bonks and the cup wobbles; the hover lists the pens")
    func dropsAndCap() throws {
        let stage = try PhysicsStage(cupDesk(pens: 5), physics: false)
        let cup = stage.hub.cup
        let mouth = stage.centre(try #require(stage.scene.physicsAnchor("pencup.mouth")))
        stage.drag(try #require(stage.tokenPoint(F.key(10))), mouth, steps: 20)
        #expect(stage.location(F.key(10)) == .container(.penCup, order: 5))
        stage.drag(try #require(stage.tokenPoint(F.key(11))), mouth, steps: 20)
        stage.frames(1)
        #expect(stage.location(F.key(11))?.isScreen == true && stage.scene.bonkCount == 1)
        #expect(cup.machine.needsFrames && cup.machine.lean != 0 || cup.machine.phase != .upright, "wobbling")
        let hit = try #require(stage.scene.hitTest(ArtPoint(Int(mouth.x), Int(mouth.y))))
        #expect(hit.element == "pencup" && hit.part == "pencup.mouth")
        let tip = try #require(cup.tooltip(hit) as TooltipSpec?)
        #expect(tip.title == "Pen Cup" && tip.detail?.hasPrefix("6 pens: ") == true)
        stage.settle()
        #expect(!stage.scene.needsFrames)
    }

    @Test("Pressing on the pens and dragging pulls the last one out (LIFO)")
    func pullLast() throws {
        let stage = try PhysicsStage(cupDesk(pens: 3), physics: false)
        let mouth = stage.centre(try #require(stage.scene.physicsAnchor("pencup.mouth")))
        let cell = try #require(stage.scene.screen).cellRect(8, 4)
        stage.drag(mouth, stage.centre(cell), steps: 20, pause: 4)
        #expect(stage.location(F.key(3)) == .screen(page: 0, col: 8, row: 4))
        #expect(stage.state.tokens.members(of: .penCup) == [F.key(1), F.key(2)])
    }

    @Test("A flick faster than 400 px/s with three pens tips it; the pens leave one by one as piles; a click rights it")
    func flickTipsAndSpills() throws {
        let stage = try PhysicsStage(cupDesk(pens: 4), physics: false)
        let cup = stage.hub.cup
        let body = stage.centre(try #require(stage.scene.physicsAnchor("pencup.body")))
        stage.drag(body, body - SIMD2(40, 0), steps: 3)
        #expect(!cup.machine.isUpright, "tipped by the flick")
        stage.settle()
        #expect(stage.state.penCup.state == PenCupMachine.lyingLeftName)
        #expect(stage.state.tokens.count(in: .penCup) == 0)
        // Each pen came out as a pile (or flew off an edge to the floor or the basket).
        for k in UInt64(1)...4 {
            let loc = try #require(stage.location(F.key(k)))
            switch loc {
            case .desk, .floor, .container(.wastebasket, _): break
            default: Issue.record("pen \(k) is \(loc)")
            }
        }
        #expect(stage.state.tokens.piles.count >= 1)
        stage.click(stage.centre(cup.bounds))
        stage.settle()
        #expect(stage.state.penCup.state == PenCupMachine.uprightName && cup.machine.isUpright)
    }

    @Test("A brisk move with two pens only wobbles it; a knock never tips it")
    func onlyGesturesTip() throws {
        let stage = try PhysicsStage(cupDesk(pens: 2), physics: false)
        let cup = stage.hub.cup
        let body = stage.centre(try #require(stage.scene.physicsAnchor("pencup.body")))
        stage.drag(body, body - SIMD2(40, 0), steps: 3)
        stage.settle()
        #expect(stage.state.penCup.state == PenCupMachine.uprightName && stage.state.tokens.count(in: .penCup) == 2)
        // The apron left of the chair (which covers its middle).
        stage.click(stage.point(core: 100, 238), count: 2)
        #expect(cup.machine.lean != 0 || cup.machine.needsFrames, "the knock wobbles it")
        stage.settle()
        #expect(cup.machine.isUpright && stage.state.tokens.count(in: .penCup) == 2)
    }

    @Test("Tip Over and Stand Up from its menu")
    func menu() throws {
        let stage = try PhysicsStage(cupDesk(pens: 1), physics: false)
        let spec = stage.scene.contextMenu(at: stage.hub.cup.bounds.center)
        #expect(spec.item("tipOver")?.isEnabled == true && spec.item("standUp")?.isEnabled == false)
        stage.dispatch(try #require(spec.item("tipOver")?.command?.action(stage.state)))
        stage.settle()
        #expect(stage.state.penCup.state != PenCupMachine.uprightName && stage.state.tokens.count(in: .penCup) == 0)
        let lying = stage.scene.contextMenu(at: stage.hub.cup.bounds.center)
        #expect(lying.item("standUp")?.isEnabled == true)
        stage.dispatch(.standUp(.penCup))
        stage.settle()
        #expect(stage.state.penCup.state == PenCupMachine.uprightName)
    }
}

@Suite("Pen cup carried (physics)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct PenCupCarryTests {
    typealias F = SceneFixture

    @Test("Dragging the cup carries it over the desk, shoving piles; it settles where it stopped and commits")
    func carry() throws {
        var s = cupDesk(pens: 1)
        s.tokens.move(F.key(5), to: .desk(pile: "P1", order: 0))
        s.piles["P1"] = [330, 90]
        let stage = try PhysicsStage(s, physics: true)
        let body = stage.centre(try #require(stage.scene.physicsAnchor("pencup.body")))
        // Down and left to the middle row (d ≈ 90), then along it through the pile, slowly enough not to tip.
        let mid = body + SIMD2(-20, 16)
        stage.drag(body, mid, steps: 20, hold: true)
        for k in 1...40 {
            stage.event(.drag, mid + SIMD2(Float(-2 * k), 0))
            stage.frames(1)
        }
        stage.frames(6)
        stage.event(.up, mid + SIMD2(-80, 0), count: 1)
        stage.settle()
        let pos = stage.state.penCup.pos
        #expect(stage.state.penCup.state == PenCupMachine.uprightName)
        #expect(pos.x < 290 && abs(pos.y - 88) < 4, "carried: \(pos)")
        let pile = try #require(stage.state.piles["P1"])
        #expect(pile.x < 300, "the pile was shoved along: \(pile)")
        #expect(PenCupMachine.isValidPosition(pos))
    }
}

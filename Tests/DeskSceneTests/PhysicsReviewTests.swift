import DeskCore
import Foundation
import Metal
import simd
import SpriteKit
import Testing
@testable import DeskScene

/// Regressions from the M7 reviews: knocks and restores never move tokens off the desk, flights land only what is
/// still where it took off, a carry has no body, landings and spills look and feel right.
private func pileDesk(_ piles: [(UInt64, PileID, SIMD2<Float>)]) -> DeskState {
    var s = SceneFixture.state()
    for (k, id, p) in piles {
        s.tokens.move(SceneFixture.key(k), to: .desk(pile: id, order: s.tokens.members(of: id).count))
        s.piles[id] = p
    }
    return s
}

@Suite("Physics review: knocks and restores (physics)", .serialized,
       .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct PhysicsRestoreTests {
    typealias F = SceneFixture

    @Test("A knock never sends a token off the desk, even with restored piles overlapping at the front edge",
          arguments: [Float(1), 2, 3, 6])
    func knockKeepsOverlappingPiles(front: Float) throws {
        let stage = try PhysicsStage(pileDesk([(1, "P1", [300, front]), (2, "P2", [300, front + 3]),
                                               (3, "P3", [150, 90]), (4, "P4", [151, 91])]), physics: true)
        stage.frames(3)
        stage.click(stage.point(core: 120, 238), count: 2)
        #expect(stage.hub.knocks == 1)
        stage.settle()
        for k in UInt64(1)...4 {
            #expect(stage.location(F.key(k))?.pile != nil, "token \(k): \(String(describing: stage.location(F.key(k))))")
        }
        // The restore put the crowded piles apart and committed it: the model and the bodies agree.
        for (id, p) in stage.scene.pilePositions {
            #expect(stage.state.piles[id].map { simd_length($0 - p) < 0.01 } == true, "\(id): \(p)")
        }
    }

    @Test("A file coming back to its old pile spot next to a fresh pile goes to a free spot; nothing leaves the desk")
    func returningPileFindsRoom() throws {
        let stage = try PhysicsStage(F.state(), physics: true)
        stage.hub.landOnDesk([F.key(2)], at: [300, 6], velocity: .zero, journaled: false)
        stage.frames(10)
        let fresh = try #require(stage.location(F.key(2))?.pile)
        let freshPos = try #require(stage.state.piles[fresh])
        stage.state.tokens.move(F.key(1), to: .desk(pile: "P90", order: 0))
        stage.state.piles["P90"] = freshPos + SIMD2(1, 1)
        stage.scene.apply(stage.state)
        stage.settle()
        #expect(stage.location(F.key(1))?.pile == "P90" && stage.location(F.key(2))?.pile == fresh)
        let moved = try #require(stage.state.piles["P90"])
        #expect(simd_length(moved - freshPos) > 8, "committed at a free spot: \(moved)")
        stage.click(stage.point(core: 120, 238), count: 2)
        stage.settle()
        #expect(stage.location(F.key(1))?.pile != nil && stage.location(F.key(2))?.pile != nil)
    }

    @Test("A pile in hand has no body: another pile slides through its spot; Esc brings it back, drawn and solid")
    func carriedPileHasNoBody() throws {
        let stage = try PhysicsStage(pileDesk([(1, "P1", [300, 14])]), physics: true)
        stage.frames(2)
        let grip = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(grip, grip + SIMD2(0, -40), steps: 10, hold: true)
        #expect(stage.scene.isDragging && stage.hub.world.piles["P1"] == nil, "no body while carried")
        stage.hub.landOnDesk([F.key(2)], at: [300, 40], velocity: [0, -900], journaled: false)
        stage.frames(60)
        stage.scene.cancelInput()
        stage.settle()
        #expect(stage.location(F.key(1)) == .desk(pile: "P1", order: 0))
        #expect(stage.scene.deskTokenRect(F.key(1)) != nil, "drawn again")
        #expect(stage.hub.world.piles["P1"] != nil && stage.hub.bodies.launched.isEmpty, "solid again")
    }

    @Test("A watchdog snap of a frozen pile leaves it frozen (static)")
    func watchdogKeepsFrozen() throws {
        let stage = try PhysicsStage(pileDesk([(1, "P1", [100, 140])]), physics: true)
        stage.frames(2)
        let b = stage.hub.bodies
        #expect(b.world.isDynamic("P1") == !b.freezer.isFrozen("P1"))
        stage.scene.forceRest()
        #expect(!b.world.isDynamic("P1") && b.freezer.isFrozen("P1"))
        #expect(stage.state.piles["P1"].map { $0.y <= 123 } == true, "back on the desk and committed")
    }

    @Test("A rebuild of the room (a display change) mid-spill lands every ball first")
    func regridMidSpill() throws {
        var s = F.state()
        for i in 0..<6 { s.tokens.move(F.key(UInt64(i + 1)), to: .container(.wastebasket, order: i)) }
        let stage = try PhysicsStage(s, physics: true)
        stage.dispatch(.tipOver(.wastebasket))
        var n = 0
        while stage.hub.tosses.flights.isEmpty && n < 120 { stage.frames(1); n += 1 }
        #expect(!stage.hub.tosses.flights.isEmpty)
        let wide = PixelGrid(display: DisplayGeometry(widthPt: 1920, heightPt: 1080, backingScale: 1, topInsetPt: 25))
        try #require(stage.host).setGrid(wide)
        for k in UInt64(1)...6 {
            if case .floor? = stage.location(F.key(k)) {} else {
                Issue.record("ball \(k): \(String(describing: stage.location(F.key(k))))")
            }
        }
    }
}

@Suite("Physics review: books and flights (CPU)", .serialized)
@MainActor
struct PhysicsBooksTests {
    typealias F = SceneFixture

    @Test("Balls rolling out of the tipped basket do not land after Take Everything Out (or an undo) moved them")
    func staleBallLanding() throws {
        var s = F.state()
        for i in 0..<8 { s.tokens.move(F.key(UInt64(i + 1)), to: .container(.wastebasket, order: i)) }
        let stage = try PhysicsStage(s, physics: false)
        stage.dispatch(.tipOver(.wastebasket))
        var n = 0
        while stage.hub.tosses.flights.isEmpty && n < 120 { stage.frames(1); n += 1 }
        stage.frames(2)
        stage.dispatch(.takeEverythingOut)
        stage.settle()
        for k in UInt64(1)...8 {
            #expect(stage.location(F.key(k))?.isScreen == true, "token \(k): \(String(describing: stage.location(F.key(k))))")
        }
    }

    @Test("A body that freezes away from where the model holds it commits there (no slow drift)")
    func commitsAtFreeze() {
        let bodies = PileBodies(world: DeskPlaneWorld())
        bodies.add("P1", at: [200, 40])
        _ = bodies.afterStep(1.0 / 60, obstacles: [])
        #expect(!bodies.isMoving)
        // Crept below the rest speed after its rest was committed.
        bodies.world.piles["P1"]?.position = DeskPlaneWorld.scenePoint([200.08, 40.03])
        var settled: [PileID: SIMD2<Float>] = [:]
        for _ in 0..<150 {
            let r = bodies.afterStep(1.0 / 60, obstacles: [])
            settled.merge(r.settled) { $1 }
            bodies.didCommit(r.settled)
        }
        #expect(bodies.freezer.isFrozen("P1"))
        #expect(settled["P1"].map { simd_length($0 - SIMD2(200.08, 40.03)) < 1e-3 } == true, "\(settled)")
    }

    @Test("Restored piles crowding each other or the keyboard get free spots, committed on the next step")
    func restoreFindsRoom() {
        let world = DeskPlaneWorld()
        let bodies = PileBodies(world: world)
        let keyboard = DeskPlaneWorld.keyboardFootprint(nil)
        bodies.sync(["P1": [300, 20], "P2": [302, 21], "P3": [256, 48], "P4": [100, 20], "P5": [114, 20]],
                    obstacles: [keyboard])
        let r = bodies.afterStep(1.0 / 60, obstacles: [keyboard])
        #expect(Set(r.settled.keys) == ["P2", "P3"], "\(r.settled)")
        let pos = bodies.positions
        for (a, p) in pos {
            for (b, q) in pos where a < b {
                #expect(!(abs(p.x - q.x) < 13 && abs(p.y - q.y) < 9), "\(a) \(p) and \(b) \(q) overlap")
            }
            #expect(!keyboard.intersects(DeskPlaneRect.centred(at: p, size: [13, 9])), "\(a) in the keyboard")
        }
        #expect(pos["P4"] == [100, 20] && pos["P5"] == [114, 20], "touching piles keep their places")
    }

    @Test("The dragged token ends on top of the pile it makes; a stack flung to the floor stands as one stack")
    func leadOnTopAndFloorStack() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        // Four tokens selected on the screen; ⌘-drag the third (the lead) and set them down gently.
        let sel = try #require(stage.scene.selection)
        sel.set(Set((UInt64(1)...4).map(F.key)), primary: F.key(3))
        let lead = try #require(stage.tokenPoint(F.key(3)))
        let to = stage.point(core: 300, 214)
        stage.event(.move, lead)
        stage.event(.down, lead, count: 1, mods: [.command])
        stage.frames(1)
        for k in 1...12 {
            stage.event(.drag, lead + (to - lead) * Float(k) / 12, mods: [.command])
            stage.frames(1)
        }
        stage.frames(6)
        stage.event(.up, to, count: 1, mods: [.command])
        stage.settle()
        #expect((UInt64(1)...4).allSatisfy { stage.location(F.key($0))?.pile != nil }, "all four on the desk")
        let pile = try #require(stage.location(F.key(3))?.pile)
        #expect(stage.state.tokens.members(of: pile).last == F.key(3), "the lead is on top")
        // The whole pile flung below the desk's edge: it lands on the floor as one stack, clear of the chair.
        let grip = try #require(stage.tokenPoint(F.key(3)))
        stage.drag(grip, stage.point(core: 330, 262), steps: 3)
        stage.settle()
        let xs = Set((UInt64(1)...4).compactMap { k -> Int? in
            if case let .floor(x)? = stage.location(F.key(k)) { x } else { nil }
        })
        #expect(xs.count == 1, "one stack: \(xs)")
        let x = try #require(xs.first)
        #expect(!FloorLine.chair(at: Float(CoreLayout.chair.x)).overlaps((x - 8)..<(x + 8)))
        #expect(stage.hub.floor.shownTokens.count == 4)
        let hit = try #require(stage.scene.hitTest(ArtPoint(stage.layout.x(x), stage.layout.floorY - 8)))
        #expect(hit.element == "floor")
        let tip = try #require(stage.hub.floor.tooltip(hit))
        #expect(tip.title == "4 items")
        #expect(stage.journal.undoLabel == "Move 4 Items")
    }

    @Test("A drop on the lying basket bonks and springs back")
    func lyingBasketBonks() throws {
        var s = F.state()
        s.wastebasket = BasketState(state: WastebasketMachine.tippedRightName)
        let stage = try PhysicsStage(s, physics: false)
        let lying = stage.layout.rect(WastebasketMachine.tippedRect(right: true))
        let target = stage.centre(lying)
        stage.drag(try #require(stage.tokenPoint(F.key(1))), target, steps: 12, pause: 6)
        stage.settle()
        #expect(stage.scene.bonkCount == 1 && stage.location(F.key(1))?.isScreen == true)
    }

    @Test("A sideways rim drag that starts slowly never digs; one that goes up out of the mouth does")
    func rimDragNeverDigsSideways() throws {
        var s = F.state()
        for i in 0..<3 { s.tokens.move(F.key(UInt64(i + 1)), to: .container(.wastebasket, order: i)) }
        let stage = try PhysicsStage(s, physics: false)
        let mouth = stage.centre(try #require(stage.scene.physicsAnchor("wastebasket.mouth")))
        // Easing in: slow first samples, then fast, 50 px across in all.
        stage.event(.move, mouth)
        stage.event(.down, mouth, count: 1)
        stage.frames(1)
        var x: Float = 0
        for step in [1, 2, 3, 4, 6, 8, 10, 16] as [Float] {
            x += step
            stage.event(.drag, mouth + SIMD2(x, 0))
            stage.frames(1)
        }
        stage.event(.up, mouth + SIMD2(x, 0), count: 1)
        stage.settle()
        #expect(stage.state.tokens.count(in: .wastebasket) == 3 || stage.state.wastebasket.state != WastebasketMachine.uprightName,
                "a sideways drag tips or does nothing; it never digs")
        #expect(stage.state.tokens.keys(where: { $0 == .carried }).isEmpty)
        #expect(stage.scene.screen?.carried.isEmpty == true)
    }

    @Test("Tip Over at the cup's home spot spills the pens beyond the lying cup; a forward flick spills them forward")
    func spillsClearOfCup() throws {
        var s = F.state()
        for i in 0..<4 { s.tokens.move(F.key(UInt64(i + 1)), to: .container(.penCup, order: i)) }
        let stage = try PhysicsStage(s, physics: false)
        stage.dispatch(.tipOver(.penCup))
        stage.settle()
        let cup = stage.hub.cup.machine
        let lying = cup.footprint
        for k in UInt64(1)...4 {
            guard let id = stage.location(F.key(k))?.pile, let p = stage.state.piles[id] else { continue }
            #expect(!lying.intersects(DeskPlaneRect.centred(at: p, size: [13, 9])), "pen \(k) at \(p) on the cup \(lying)")
        }
        // The spill's aim follows a flick toward the front.
        let forward = PenCupMachine.spill(count: 6, from: [300, 60], right: true, seed: 3, direction: [40, -500])
        let side = PenCupMachine.spill(count: 6, from: [300, 60], right: true, seed: 3)
        let meanD = { (spills: [PenCupMachine.Spill]) in spills.map(\.velocity.y).reduce(0, +) / Float(spills.count) }
        #expect(meanD(forward) < -100 && abs(meanD(side)) < 60, "\(meanD(forward)) \(meanD(side))")
    }

    @Test("Count tags never sit on each other")
    func tagsApart() throws {
        let stage = try PhysicsStage(pileDesk([(1, "P1", [200, 30]), (2, "P1", [200, 30]), (3, "P2", [200, 40]),
                                               (4, "P2", [200, 40]), (5, "P3", [203, 50]), (6, "P3", [203, 50])]),
                                     physics: false)
        stage.frames(1)
        let tags = stage.hub.piles.root.children.compactMap { $0 as? SKSpriteNode }
            .filter { $0.zPosition == DeskPilesElement.tagZ && !$0.isHidden }
            .map { stage.scene.space.artRect($0.frame) }
        #expect(!tags.isEmpty)
        for (i, a) in tags.enumerated() {
            for b in tags.dropFirst(i + 1) { #expect(!a.intersects(b), "\(a) \(b)") }
        }
    }

    @Test("A rim bounce jiggles the basket; a crumpled miss stays a ball until it lands")
    func rimFeedback() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        let p = Ballistics.Params.standard
        let toss = Ballistics.toss(from: SIMD3(p.basketX + 15, p.basketD, p.rimZ + 20), velocity: .zero)
        #expect(toss.rimHits > 0 && !toss.isIn)
        let image = stage.hub.flightImage([F.key(1)])
        let flight = stage.hub.tosses.launch([F.key(1)], path: .toss(toss), image: image.image, base: image.base,
                                             crumples: true) { _ in }
        var shook = false, crumpledThenIcon = false, crumpled = false
        while !flight.landed {
            stage.frames(1)
            shook = shook || stage.hub.basket.needsFrames
            if flight.crumpleAge != nil { crumpled = true }
            if crumpled, flight.crumpleAge == nil { crumpledThenIcon = true }
        }
        #expect(shook && crumpled && !crumpledThenIcon)
    }

    @Test("Metal is present where CI says it must be (the physics suites would otherwise skip)")
    func metalWhenRequired() {
        if ProcessInfo.processInfo.environment["DESKTERIOR_REQUIRE_METAL"] == "1" {
            #expect(MTLCreateSystemDefaultDevice() != nil,
                    "DESKTERIOR_REQUIRE_METAL=1 but no Metal device: the physics tests did not run")
        }
    }
}

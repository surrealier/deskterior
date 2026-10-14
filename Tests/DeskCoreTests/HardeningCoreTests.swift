import Foundation
import Testing
@testable import DeskCore

/// Pre-release hardening in the core (wave 6, Errata 25): a `desk.json` that parses but holds values no desk could
/// have saved is brought back into range before anything lays it out; the new problems and toasts are in the table.
@Suite("Core hardening (wave 6)")
struct HardeningCoreTests {
    typealias F = ModelFixture

    /// `doc` as JSON, edited as a dictionary by `edit`, then decoded as a launch would.
    static func roundTrip(_ doc: DeskDocument, _ edit: (inout [String: Any]) -> Void) throws -> DeskDocument {
        var object = try #require(JSONSerialization.jsonObject(with: try doc.encoded()) as? [String: Any])
        edit(&object)
        return try DeskDocument.decode(try JSONSerialization.data(withJSONObject: object))
    }

    @Test("Absurd numbers in a desk.json that parses are brought back into range, and the state can be made")
    func sanitizes() throws {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt", "d.txt"])
        s.piles["P1"] = [200, 40]
        s.tokens.move(F.key(2), to: .desk(pile: "P1", order: 0))
        s.tokens.move(F.key(3), to: .floor(x: 210))
        let doc = DeskDocument(state: s, savedAt: F.t0)
        let bad = try Self.roundTrip(doc) { o in
            o["mat"] = ["size": [1e30, 1e30], "origin": [5e20, -3], "angle": 1e9, "grid": [Int.max, 3],
                        "particles": "AAAA", "keyboard": [1e12, 0]]
            o["piles"] = [["id": "P1", "pos": [1e30, 40]]]
            o["chair"] = ["x": 1e30, "facing": Int.max]
            o["wastebasket"] = ["state": "upright", "swishes": Int.max]
            o["monitor"] = ["power": "on", "page": -5, "av": false, "pendingNew": Int.max]
            o["penCup"] = ["state": "upright", "pos": [-1e9, 1e9]]
            o["brush"] = ["pos": [1e20, 1e20]]
            o["drawers"] = ["riserLeft": ["p": 1e30], "cabinetTop": ["p": -4]]
            guard var tokens = o["tokens"] as? [[String: Any]] else { return }
            for i in tokens.indices {
                let key = tokens[i]["key"] as? [String: Any]
                if key?["inode"] as? Int == 1 { tokens[i]["loc"] = ["screen": ["page": 2_000_000_000, "col": 0, "row": 0]] }
                if key?["inode"] as? Int == 3 { tokens[i]["loc"] = ["floor": ["x": 99_999]] }
            }
            o["tokens"] = tokens
        }
        #expect(bad.mat.size == MatState().size && bad.mat.origin == MatState().origin && bad.mat.angle == 0)
        #expect(bad.mat.grid == MatState().grid && bad.mat.particles == nil && bad.mat.keyboard == nil)
        #expect(bad.piles == [.init(id: "P1", pos: Placement.defaultPilePos)])
        #expect(bad.chair.x == Float(CoreLayout.chairTravel.upperBound))
        #expect(bad.wastebasket.swishes == DeskDocument.maxCount && bad.monitor.pendingNew == DeskDocument.maxCount)
        #expect(bad.monitor.page == 0 && bad.penCup.pos == PenCupState().pos && bad.brush == BrushState())
        #expect(bad.drawers["riserLeft"]?.p == ContainerID.riserLeft.spec.travel && bad.drawers["cabinetTop"]?.p == 0)
        let state = bad.makeState()
        #expect(state.tokens.count == 4)
        #expect(state.tokens.location(of: F.key(1))?.cell?.page == 0, "the far-off page gave up its spot")
        #expect(state.tokens.location(of: F.key(3))?.isScreen == true, "so did the floor spot past the room")
        #expect(state.tokens.location(of: F.key(2)) == .desk(pile: "P1", order: 0))
        #expect(state.pageCount() == 1)
        // The next swish cannot overflow.
        var counted = state
        counted.wastebasket.swishes += 1
        #expect(counted.wastebasket.swishes == DeskDocument.maxCount + 1)
    }

    @Test("A sound desk.json passes through the sanitizer unchanged")
    func soundUnchanged() throws {
        var s = F.mirrored(["a.txt", "b.txt"])
        s.piles["P2"] = [281, 44]
        s.tokens.move(F.key(1), to: .desk(pile: "P2", order: 0))
        s.tokens.move(F.key(2), to: .floor(x: 210))
        s.penCup = PenCupState(state: "lying", pos: [300, 90])
        s.chair = ChairState(x: 320.5, facing: 3)
        s.drawers[.cabinetTop] = DrawerState(p: 12)
        s.mat.angle = 0.25
        s.mat.keyboard = [256, 52]
        let doc = DeskDocument(state: s, savedAt: F.t0)
        #expect(doc.sanitized() == doc)
        #expect(try DeskDocument.decode(try doc.encoded()) == doc)
    }

    @Test("A saved mat grid too large to multiply is malformed, never a crash")
    func gridOverflow() {
        var m = MatState()
        m.grid = [Int.max, 3]
        m.particles = "AAAA"
        #expect(ClothSim(state: m) == nil)
        m.grid = [Int.max, Int.max]
        let flat = ClothSim.flat(m)
        #expect(flat.cols == 35 && flat.rows == 15)
        #expect(DeskDocument.sane(m).grid == MatState().grid && DeskDocument.sane(m).particles == nil)
    }

    @Test("A locked drop has its own problem and toast; the new toasts speak Korean too")
    func lockedAndToasts() {
        #expect(FileReport(kind: .importItems, count: 1, problems: [.locked]).toast == .fileLocked)
        #expect(FileReport(kind: .importItems, count: 2, problems: [.locked]).toast == .someLocked)
        #expect(FileReport(kind: .importItems, count: 1, problems: [.landedUnverified]).toast == .copiedNoUndo)
        #expect(FileReport(kind: .importItems, count: 3, problems: [.gone, .landedUnverified]).toast == .copiedNoUndo)
        let both = FileReport(kind: .importItems, count: 2, problems: [.notPermitted], done: .copiedInstead)
        #expect(both.toast == .someCopiedInstead, "a move that came in as a copy is never left unsaid")
        let english = ["It's locked, so it stayed. ⌥ copies it.", "Copied in; the original stayed put.",
                       "Interrupted copy left files. See Settings.", "Some were locked, so they stayed.",
                       "Some came in as copies; the rest stayed.", "Copied in, but it can't be undone.",
                       "No leftover copies now."]
        for e in english {
            #expect(L10n.knows(e), "\(e)")
            #expect(L10n.tr(e, .ko) != e)
        }
        #expect(L10n.format(.leftoversMany, [3], .en).hasPrefix("3 hidden folders"))
        #expect(L10n.format(.leftoversOne, [1], .ko).contains("1"))
    }

    @Test("A stilled knock keeps only the drawers it shuts")
    func stilledKnock() {
        var s = F.mirrored(["a.txt"])
        s.piles["P1"] = [150, 30]
        s.tokens.move(F.key(1), to: .desk(pile: "P1", order: 0))
        s.drawers[.riserLeft] = DrawerState(p: 2)
        let plan = DeskKnock.plan(for: s, origin: [100, 0], seed: 7)
        let still = plan.stilled
        #expect(plan.drawerCloses.contains(.riserLeft) && still.drawerCloses == plan.drawerCloses)
        #expect(still.frames == 0 && still.pileHops.isEmpty && still.wobbles.isEmpty && !still.clothRipple)
    }

    @Test("INPUT spring-loads to the next HDMI page, wrapping, from AV to HDMI 1, and nowhere with one page")
    func inputSpring() {
        var s = F.mirrored((0..<100).map { "f\($0).txt" })  // three pages of 45
        #expect(s.pageCount() == 3)
        #expect(MonitorMachine.springInputPage(s) == 1)
        s.monitor.page = 2
        #expect(MonitorMachine.springInputPage(s) == 0)
        s.monitor.av = true
        #expect(MonitorMachine.springInputPage(s) == 0)
        #expect(MonitorMachine.springInputPage(F.mirrored(["a.txt"])) == nil)
    }
}

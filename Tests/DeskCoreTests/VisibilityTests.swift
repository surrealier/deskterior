import Foundation
import Testing
@testable import DeskCore

@Suite("Visibility matrix")
struct VisibilityTests {
    typealias A = Visibility.Appearance

    func v(_ loc: Location, _ s: DeskState, _ c: Visibility.Coverage = .none) -> (A, Bool) {
        let r = Visibility.of(loc, s, c)
        return (r.appearance, r.hitTestable)
    }

    @Test("Screen: only the current page of a powered monitor on HDMI shows")
    func screen() {
        var s = DeskState()
        let loc = Location.screen(page: 1, col: 0, row: 0)
        #expect(v(loc, s) == (.notShown, false))
        s.monitor.page = 1
        #expect(v(loc, s) == (.icon, true))
        s.monitor.av = true
        #expect(v(loc, s) == (.notShown, false))
        s.monitor.av = false
        s.monitor.power = .off
        #expect(v(loc, s) == (.notShown, false))
        #expect(Visibility.of(loc, s).isHidden)
    }

    @Test("Drawers: closed hides, a gap shows paper edges, open (p ≥ 8) shows minis")
    func drawers() {
        var s = DeskState()
        for id in [ContainerID.riserLeft, .riserRight, .cabinetTop, .cabinetMiddle, .cabinetFile] {
            let loc = Location.container(id, order: 0)
            s.drawers[id] = DrawerState(p: 0)
            #expect(v(loc, s) == (.notShown, false))
            s.drawers[id] = DrawerState(p: 4)
            #expect(v(loc, s) == (.paperEdges, false))
            s.drawers[id] = DrawerState(p: 8)
            #expect(v(loc, s) == (.mini, true))
        }
    }

    @Test("Cubby, phone, pen cup and wastebasket")
    func holders() {
        var s = DeskState()
        #expect(v(.container(.riserCubby, order: 3), s) == (.silhouette, true))
        #expect(v(.container(.phone, order: 0), s) == (.mini, true))
        s.phone.faceDown = true
        #expect(v(.container(.phone, order: 0), s) == (.notShown, false))
        for i in 0..<3 {
            s.tokens.insert(TokenKey(volume: "V", inode: UInt64(i)), meta: TokenMeta(name: "p\(i)", kind: .text), at: .container(.penCup, order: i))
            s.tokens.insert(TokenKey(volume: "V", inode: UInt64(10 + i)), meta: TokenMeta(name: "w\(i)", kind: .text), at: .container(.wastebasket, order: i))
        }
        #expect(v(.container(.penCup, order: 0), s) == (.penCap, false))
        #expect(v(.container(.penCup, order: 2), s) == (.penCap, true))
        #expect(v(.container(.wastebasket, order: 1), s) == (.ball, false))
        #expect(v(.container(.wastebasket, order: 2), s) == (.ball, true))
        #expect(Visibility.of(.container(.riserCubby, order: 0), s).isHidden)
    }

    @Test("Desk piles hide under the mat; the floor always shows")
    func deskAndFloor() {
        let s = DeskState()
        let pile = Location.desk(pile: "P1", order: 0)
        #expect(v(pile, s) == (.icon, true))
        #expect(v(pile, s, .init(coveredPiles: ["P1"])) == (.bump, false))
        #expect(v(pile, s, .init(coveredPiles: ["P2"])) == (.icon, true))
        #expect(v(.floor(x: 10), s) == (.icon, true))
        #expect(v(.carried, s) == (.icon, false))
    }

    @Test("Lamp-only darkness turns recognizable tokens into silhouettes and blocks clicks")
    func darkness() {
        let s = DeskState()
        let dark = Visibility.Coverage(dark: true)
        #expect(v(.screen(page: 0, col: 0, row: 0), s, dark) == (.silhouette, false))
        #expect(v(.floor(x: 1), s, dark) == (.silhouette, false))
        #expect(v(.container(.riserCubby, order: 0), s, dark) == (.silhouette, false))
        #expect(v(.container(.riserLeft, order: 0), s, dark) == (.notShown, false))
        #expect(v(.desk(pile: "P1", order: 0), s, .init(coveredPiles: ["P1"], dark: true)) == (.bump, false))
    }

    @Test("Inventory labels and search")
    func inventory() {
        var s = DeskState()
        let items: [(String, Location)] = [
            ("보고서.pdf", .screen(page: 1, col: 0, row: 0)), ("memo.txt", .container(.cabinetMiddle, order: 0)),
            ("old.zip", .desk(pile: "P1", order: 0)), ("a.png", .container(.wastebasket, order: 0)), ("Résumé.pdf", .floor(x: 3)),
        ]
        s.piles["P1"] = [1, 1]
        for (i, item) in items.enumerated() {
            s.tokens.insert(TokenKey(volume: "V", inode: UInt64(i)), meta: TokenMeta(name: item.0.decomposedStringWithCanonicalMapping, kind: .doc), at: item.1)
        }
        let all = InventoryQuery.items(s, coverage: .init(coveredPiles: ["P1"]))
        #expect(all.map(\.label) == ["Wastebasket", "Cabinet ▸ middle", "Under mat", "Floor", "Monitor · HDMI 2"])
        #expect(all.map(\.name).last == "보고서.pdf")
        #expect(all.allSatisfy(\.isHidden) == false)
        #expect(InventoryQuery.items(s, search: "resume").map(\.name) == ["Résumé.pdf"])
        #expect(InventoryQuery.items(s, search: "보고".decomposedStringWithCanonicalMapping).count == 1)
        #expect(InventoryQuery.items(s, search: "  ").count == 5)
    }

    // MARK: memos (0.3.0)

    @Test("Memo clips show their cards as minis that take clicks; in the dark they are silhouettes without")
    func memoClips() {
        let s = ModelFixture.mirrored(["a.txt", "b.txt"])
        #expect(v(.container(.memoClips, order: 0), s) == (.mini, true))
        #expect(v(.container(.memoClips, order: 1), s) == (.mini, true), "every card, not only the top one")
        #expect(v(.container(.memoClips, order: 0), s, .init(dark: true)) == (.silhouette, false))
        #expect(!Visibility.of(.container(.memoClips, order: 0), s).isHidden && ContainerID.memoClips.spec.concealment == .shown)
    }
}

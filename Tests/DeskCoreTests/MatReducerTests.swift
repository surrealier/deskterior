import Foundation
import simd
import Testing
@testable import DeskCore

@Suite("Reducer and menus: the desk mat and the brush (M9)")
struct MatReducerTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    @Test("Mat commands only ask the scene to play them; the model waits for the cloth to settle")
    func commands() {
        var s = F.mirrored(["a.txt"])
        let before = s
        for c: MatCommand in [.smooth, .unfold, .rotate(degrees: 15), .straighten, .size(.large), .peekUnder, .reset] {
            #expect(reduce(&s, .mat(c), env) == [.play(.matCommand, .mat(c)), .wakeLoop])
            #expect(MenuCommand.mat(c).action(s).map { "\($0)" } == "\(DeskAction.mat(c))")
        }
        #expect(s == before)
        var journal = UndoJournal()
        _ = Reducer.reduce(&s, journal: &journal, .mat(.reset), env)
        #expect(journal.undoLabel == nil, "moving the mat is not a layout change to undo")
    }

    @Test("matSettled keeps the cloth's pose (particles, keyboard) and refuses non-finite frames")
    func matSettled() {
        var s = F.mirrored(["a.txt"])
        var cloth = ClothSim()
        cloth.setKeyboard(MatState().keyboardFootprint)
        cloth.forceSleep()
        let m = cloth.matState()
        #expect(reduce(&s, .matSettled(m), env) == [.persist, .wakeLoop] && s.mat == m)
        #expect(s.mat.keyboard.map { simd_distance($0, MatState.defaultKeyboard) < 0.01 } == true)
        #expect(reduce(&s, .matSettled(m), env).isEmpty)
        var bad = m
        bad.angle = .nan
        #expect(reduce(&s, .matSettled(bad), env).isEmpty && s.mat == m)
    }

    @Test("brushSettled keeps the brush on the desk top")
    func brush() {
        var s = F.mirrored(["a.txt"])
        #expect(reduce(&s, .brushSettled([300, 40]), env) == [.persist, .wakeLoop] && s.brush.pos == [300, 40])
        #expect(reduce(&s, .brushSettled([300, 40]), env).isEmpty)
        _ = reduce(&s, .brushSettled([900, -20]), env)
        #expect(s.brush.pos == [500, 0])
        #expect(reduce(&s, .brushSettled([.nan, 1]), env).isEmpty && s.brush.pos == [500, 0])
    }

    @Test("The mat's menu: every command, Unfold and turns only when they can do something, sizes ticked")
    func menu() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt"])
        s.tokens.move(F.key(2), to: .desk(pile: "P1", order: 0))
        s.piles["P1"] = [250, 40]
        var info = MenuSpec.MatInfo()
        info.under = [F.key(2)]
        let spec = MenuSpec.mat(s, info)
        #expect(spec.ids == ["smoothMat", "unfoldMat", "rotate", "rotate.cw", "rotate.ccw", "rotate.straighten", "size",
                             "size.small", "size.medium", "size.large", "peekUnder", "listUnder", "under.0", "resetMat"])
        #expect(spec.item("unfoldMat")?.isEnabled == false && spec.item("rotate.straighten")?.isEnabled == false)
        #expect(spec.item("size.medium")?.isChecked == true && spec.item("size.medium")?.isEnabled == false)
        #expect(spec.item("rotate.cw")?.command == .mat(.rotate(degrees: -15)))
        #expect(spec.item("under.0")?.title == "b.txt" && spec.item("under.0")?.command == .moveTo([F.key(2)], .screen(page: 0, col: 1, row: 0)))
        info.flat = true
        info.folded = true
        info.under = []
        let flat = MenuSpec.mat(s, info)
        #expect(flat.item("peekUnder")?.isEnabled == false && flat.item("listUnder")?.isEnabled == false)
        #expect(flat.item("unfoldMat")?.isEnabled == true)
        // Nothing on the mat's menu touches files.
        for id in spec.ids {
            guard let action = spec.item(id)?.command?.action(s) else { continue }
            var copy = s
            #expect(!reduce(&copy, action, env).contains { $0.touchesFiles }, "\(id)")
        }
    }

    @Test("Menu sizes match the mat's rest size; Smooth Desk Mat is on the status menu")
    func sizes() {
        #expect(MatSize.matching([204, 84]) == .medium && MatSize.matching([150.4, 60]) == .small)
        #expect(MatSize.matching([200, 84]) == nil)
        #expect(MatSize.allCases.allSatisfy { $0.dimensions.x.truncatingRemainder(dividingBy: 6) == 0 })
        let status = MenuSpec.status(F.mirrored(["a"]))
        #expect(status.item("smoothMat")?.command == .mat(.smooth) && status.item("clearDesk")?.isEnabled == true)
    }
}

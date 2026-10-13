import Testing
@testable import DeskCore

@Suite("MenuSpec")
struct MenuSpecTests {
    typealias F = ModelFixture

    @Test("Token menu: open, look, reveal, copy, Move to ▸ every hiding place, and Trash last")
    func tokenMenu() {
        let s = F.mirrored(["a.txt", "b.txt"])
        let keys = [F.key(1)]
        let m = MenuSpec.token(keys, s)
        #expect(m.items.compactMap { $0.isSeparator ? nil : $0.id } == ["open", "quickLook", "reveal", "copy", "moveTo", "trash"])
        #expect(m.item("quickLook")?.title == "Quick Look “a.txt”")
        #expect(m.item("open")?.command == .open(keys))
        #expect(m.item("trash")?.command == .moveToTrash(keys))
        #expect(m.item("moveTo.monitor") == nil, "tokens on the screen are already on the monitor")
        for id in ContainerID.allCases {
            #expect(m.item("moveTo.\(id.rawValue)")?.command == .moveTo(keys, .container(id, order: 0)))
        }
        if case .requestTrash(keys)? = m.item("trash")?.command?.action(s) {} else { Issue.record("trash is a request") }
    }

    @Test("Move to ▸ disables a container that cannot take the tokens; hidden tokens can go back to the monitor")
    func moveToLimits() {
        var s = F.mirrored((1...8).map { "f\($0)" })
        for i in 1...6 { s.tokens.move(F.key(UInt64(i)), to: .container(.penCup, order: 9)) }
        let m = MenuSpec.token([F.key(7)], s)
        #expect(m.item("moveTo.penCup")?.isEnabled == false)
        #expect(m.item("moveTo.cabinetFile")?.isEnabled == true)
        let hidden = MenuSpec.token([F.key(1)], s)
        #expect(hidden.item("moveTo.monitor")?.isEnabled == true)
        #expect(hidden.item("moveTo.penCup")?.isEnabled == true, "reordering inside a full cup is fine")
        #expect(MenuSpec.token([], s).item("open")?.isEnabled == false)
    }

    @Test("Monitor menu: power, one input per page plus AV (current checked), Clean Up By")
    func monitorMenu() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot((0..<50).map { F.entry("f\($0)", UInt64($0 + 1)) }), now: F.t0)
        s.monitor.page = 1
        let m = MenuSpec.monitor(s)
        #expect(m.item("power")?.title == "Turn Display Off" && m.item("power")?.command == .power(false))
        #expect(m.item("input.hdmi1")?.title == "HDMI 1 · 45" && m.item("input.hdmi1")?.isChecked == false)
        #expect(m.item("input.hdmi2")?.title == "HDMI 2 · 5" && m.item("input.hdmi2")?.isChecked == true)
        #expect(m.item("input.av")?.command == .avInput)
        #expect(m.item("cleanUp.dateAdded")?.command == .cleanUp(.dateAdded))
        s.monitor.power = .off
        #expect(MenuSpec.monitor(s).item("power")?.title == "Turn Display On")
        #expect(MenuSpec.monitor(DeskState()).item("cleanUp")?.isEnabled == false)
        if case .selectAV? = MenuCommand.avInput.action(s) {} else { Issue.record("AV selects the AV input") }
    }

    @Test("Desk and status menus: lights, global actions, undo labels, pause; the status item adds its extras")
    func deskMenus() {
        var s = F.mirrored(["a", "b"])
        s.lights = LightsState(mode: .night, room: false, lamp: true)
        s.tokens.move(F.key(2), to: .container(.wastebasket, order: 0))
        let wall = MenuSpec.desk(s, MenuSpec.Context(paused: false, undo: "Move", redo: nil))
        #expect(wall.item("lights.night")?.isChecked == true && wall.item("lights.auto")?.isChecked == false)
        #expect(wall.item("lights.room")?.isChecked == false && wall.item("lights.deskLamp")?.isChecked == true)
        #expect(wall.item("undo")?.title == "Undo Move" && wall.item("undo")?.isEnabled == true)
        #expect(wall.item("redo")?.isEnabled == false)
        #expect(wall.item("pause")?.title == "Pause Desk" && wall.item("pause")?.command == .pauseDesk(true))
        #expect(wall.item("takeEverythingOut")?.isEnabled == true)
        #expect(wall.item("emptyWastebasket") == nil && wall.item("openDesktopFolder") == nil)
        let status = MenuSpec.status(s, MenuSpec.Context(paused: true))
        #expect(status.item("emptyWastebasket")?.title == "Empty Wastebasket… (1)")
        #expect(status.item("openDesktopFolder") != nil && status.item("pause")?.title == "Resume Desk")
        #expect(Set(wall.ids).isSubset(of: Set(status.ids)))
        // Lights commands keep the other switches.
        if case let .lights(l)? = MenuCommand.lightsMode(.lampOnly).action(s) {
            #expect(l == LightsState(mode: .lampOnly, room: false, lamp: true))
        } else {
            Issue.record("lights mode is a lights action")
        }
        if case let .lights(l)? = MenuCommand.roomLight(true).action(s) { #expect(l.room && l.mode == .night) }
        // Lamp Only owns both switches.
        s.lights.mode = .lampOnly
        #expect(MenuSpec.desk(s).item("lights.room")?.isEnabled == false)
    }

    @Test("App commands have no model action; nothing on the desk menus changes files")
    func commandKinds() {
        let s = F.mirrored(["a"])
        for c: MenuCommand in [.inventory, .peekDesk, .pauseDesk(true), .openDesktopFolder, .settings, .about, .quit] {
            #expect(c.action(s) == nil)
        }
        for spec in [MenuSpec.desk(s), MenuSpec.monitor(s)] {
            for id in spec.ids {
                guard let action = spec.item(id)?.command?.action(s) else { continue }
                var copy = s
                let effects = reduce(&copy, action, ReduceEnv(now: F.t0))
                #expect(!effects.contains { $0.mutatesFiles }, "\(id) mutates files")
            }
        }
    }
}

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
        #expect(m.item("trash")?.isEnabled == false, "Move to Trash waits for FileOperator (M11)")
        #expect(m.item("moveTo.monitor") == nil, "tokens on the screen are already on the monitor")
        for id in ContainerID.allCases {
            #expect(m.item("moveTo.\(id.rawValue)")?.command == .moveTo(keys, .container(id, order: 0)))
        }
        #expect(m.item("moveTo.riserLeft")?.title == "Left Riser Drawer" && m.item("moveTo.cabinetFile")?.title == "File Drawer")
        if case .requestTrash(keys)? = m.item("trash")?.command?.action(s) {} else { Issue.record("trash is a request") }
    }

    @Test("Move to ▸ HDMI n: other pages with room, and a new page; not the page the tokens are on")
    func moveToPages() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot((0..<50).map { F.entry("f\($0)", UInt64($0 + 1)) }), now: F.t0)
        // HDMI 1 is full (45), HDMI 2 holds 5.
        let k0 = s.tokens.sortedKeys.first { s.tokens.location(of: $0)?.cell?.page == 0 }!
        let k45 = s.tokens.sortedKeys.first { s.tokens.location(of: $0)?.cell?.page == 1 }!
        let m = MenuSpec.token([k0], s)
        #expect(m.item("moveTo.hdmi1")?.isEnabled == false, "already there")
        #expect(m.item("moveTo.hdmi2")?.isEnabled == true && m.item("moveTo.hdmi3")?.title == "HDMI 3 (New)")
        guard case let .moveTo(keys, to)? = m.item("moveTo.hdmi2")?.command else { Issue.record("no page move"); return }
        #expect(keys == [k0] && to.cell?.page == 1)
        var copy = s
        _ = reduce(&copy, .move(keys, to: to), ReduceEnv(now: F.t0))
        #expect(copy.tokens.location(of: k0)?.cell?.page == 1)
        // HDMI 1 is full: a token from HDMI 2 cannot go there.
        #expect(MenuSpec.token([k45], s).item("moveTo.hdmi1")?.isEnabled == false)
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
        #expect(m.item("input")?.isEnabled == true && m.item("cleanUp")?.isEnabled == true)
        s.monitor.av = true
        #expect(MenuSpec.monitor(s).item("cleanUp")?.isEnabled == false, "no desktop on AV")
        s.monitor.av = false
        s.monitor.power = .off
        #expect(MenuSpec.monitor(s).item("power")?.title == "Turn Display On")
        #expect(MenuSpec.monitor(s).item("input")?.isEnabled == false && MenuSpec.monitor(s).item("cleanUp")?.isEnabled == false)
        #expect(MenuSpec.monitor(DeskState()).item("cleanUp")?.isEnabled == false)
        if case .selectAV? = MenuCommand.avInput.action(s) {} else { Issue.record("AV selects the AV input") }
    }

    @Test("Desk and status menus: the same items (lights, global actions, undo labels, pause); unfinished ones disabled")
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
        // The wall stands in for a hidden status item: the same items, Empty Wastebasket and the folder included.
        #expect(wall.item("emptyWastebasket")?.title == "Empty Wastebasket… (1)" && wall.item("openDesktopFolder") != nil)
        let status = MenuSpec.status(s, MenuSpec.Context(paused: true))
        #expect(status.item("pause")?.title == "Resume Desk")
        #expect(wall.ids == status.ids)
        for id in ["clearDesk", "peekDesk", "settings", "emptyWastebasket"] {
            #expect(wall.item(id)?.isEnabled == false, "\(id) waits for its milestone")
        }
        #expect(wall.item("find")?.isEnabled == true && wall.item("about")?.isEnabled == true)
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

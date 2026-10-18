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
        #expect(m.item("trash")?.isEnabled == true, "Move to Trash runs through FileOperator (M11)")
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
        #expect(hidden.item("moveTo.penCup")?.isEnabled == false && hidden.item("moveTo.penCup")?.isChecked == true,
                "a pen already in the cup: ticked, nothing to move")
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
        #expect(MenuSpec.pending.isEmpty)
        // MARK: mat
        #expect(wall.item("clearDesk")?.isEnabled == true && wall.item("smoothMat")?.command == .mat(.smooth))
        #expect(wall.item("emptyWastebasket")?.isEnabled == true, "M11: Empty Wastebasket… runs (after its sheet)")
        // MARK: system (M12)
        #expect(wall.item("peekDesk")?.isEnabled == true && wall.item("settings")?.isEnabled == true)
        #expect(wall.item("find")?.isEnabled == true && wall.item("about")?.isEnabled == true)
        // Lights commands keep the other switches.
        if case let .lights(l)? = MenuCommand.lightsMode(.lampOnly).action(s) {
            #expect(l == LightsState(mode: .lampOnly, room: false, lamp: true))
        } else {
            Issue.record("lights mode is a lights action")
        }
        if case let .lights(l)? = MenuCommand.roomLight(true).action(s) { #expect(l.room && l.mode == .night) }
        // In Lamp Only the switches stay live: turning one leaves it for Night (LightingInteractionTests).
        s.lights.mode = .lampOnly
        #expect(MenuSpec.desk(s).item("lights.room")?.isEnabled == true)
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

    // MARK: tidy (0.3.0)

    /// The children of a submenu item, separators as "-".
    func children(_ spec: MenuSpec, _ id: String) -> [MenuItem] {
        if case let .submenu(items)? = spec.item(id)?.content { return items }
        return []
    }

    @Test("Desk and status menus: New Sticky Note, Memos…, Put Away ▸, Bring Back ▸ and Arrange Desk… before Undo")
    func deskMenuTidyItems() {
        let s = F.mirrored(["a", "b"])
        let ids = MenuSpec.desk(s).items.map(\.id)
        let i = ids.firstIndex(of: "emptyWastebasket")!
        #expect(Array(ids[i...].prefix(9)) == ["emptyWastebasket", "-", "newNote", "memos", "putAway", "bringBack", "arrangeDesk", "-", "undo"])
        let desk = MenuSpec.desk(s)
        #expect(desk.item("newNote")?.command == .newNote && desk.item("memos")?.command == .openMemos(.today))
        #expect(desk.item("arrangeDesk")?.command == .arrangeDesk && desk.item("arrangeDesk")?.title == "Arrange Desk…")
        #expect(MenuSpec.status(s).ids == desk.ids)
    }

    @Test("Put Away ▸: what is out, in catalog order with groups apart; a place with files says it takes them out")
    func putAwaySubmenu() {
        var s = F.mirrored(["a", "b", "c"])
        s.tokens.move(F.key(2), to: .container(.cabinetMiddle, order: 0))
        s.tokens.move(F.key(3), to: .container(.cabinetFile, order: 0))
        let items = children(MenuSpec.desk(s), "putAway")
        #expect(items.map(\.id) == [
            "putAway.riserDrawers", "putAway.cabinet", "-", "putAway.phoneStand", "putAway.plant", "-", "putAway.partition",
            "putAway.dailyPad", "putAway.memoClips", "putAway.clipLight", "putAway.dDayCard", "-", "putAway.wallShelf",
            "putAway.pegboard", "putAway.stringLights", "putAway.floorPlant", "putAway.wallArt",
        ])
        let put = MenuSpec(items)
        #expect(put.item("putAway.cabinet")?.title == "Take Out 2 & Put Away Cabinet")
        #expect(put.item("putAway.cabinet")?.command == .putAway(.cabinet))
        #expect(put.item("putAway.plant")?.title == "Plant" && put.item("putAway.dDayCard")?.title == "D-Day Card")
        // An away partition takes its add-ons out of the list; everything away leaves it empty, and off.
        s.tokens.move(F.key(2), to: .container(.memoClips, order: 0))
        #expect(MenuSpec(children(MenuSpec.desk(s), "putAway")).item("putAway.partition")?.title
            == "Take Out 1 & Put Away Desk Partition")
        s.stowed = [.partition]
        let ids = MenuSpec.desk(s).ids
        #expect(!ids.contains("putAway.partition") && !ids.contains("putAway.memoClips") && ids.contains("putAway.plant"))
        s.stowed = Set(StowID.allCases)
        #expect(MenuSpec.desk(s).item("putAway")?.isEnabled == false && children(MenuSpec.desk(s), "putAway").isEmpty)
    }

    @Test("Bring Back ▸: disabled, never hidden, when nothing is away; lists what comes back on its own, then all")
    func bringBackSubmenu() {
        var s = F.mirrored(["a"])
        let none = MenuSpec.desk(s)
        #expect(none.item("bringBack")?.isEnabled == false)
        #expect(children(none, "bringBack").map(\.id) == ["bringBackAll"] && none.item("bringBackAll")?.isEnabled == false)
        s.stowed = [.cabinet, .partition, .clipLight, .stringLights]
        let some = MenuSpec.desk(s)
        #expect(some.item("bringBack")?.isEnabled == true)
        #expect(children(some, "bringBack").map(\.id)
            == ["bringBack.cabinet", "bringBack.partition", "bringBack.stringLights", "-", "bringBackAll"])
        #expect(some.item("bringBack.partition")?.title == "Desk Partition" && some.item("bringBackAll")?.isEnabled == true)
        #expect(some.item("bringBack.cabinet")?.command == .bringBack(.cabinet))
        #expect(some.item("bringBackAll")?.command == .bringBackAll && some.item("bringBackAll")?.title == "Bring Everything Back")
        // An add-on away on its own flag, with its partition out, comes back by itself.
        s.stowed = [.clipLight]
        #expect(children(MenuSpec.desk(s), "bringBack").first?.id == "bringBack.clipLight")
    }

    @Test("Object menus end with Put Away ‹X› (or Take Out n & …); the sealed riser offers Bring Back Riser Drawers")
    func objectMenus() {
        var s = F.mirrored(["a", "b"])
        let plain = MenuSpec.objectPutAway(.cabinet, s)
        #expect(plain.map(\.id) == ["-", "putAway"] && plain.last?.title == "Put Away Cabinet")
        #expect(plain.last?.command == .putAway(.cabinet))
        s.tokens.move(F.key(1), to: .container(.phone, order: 0))
        #expect(MenuSpec.objectPutAway(.phoneStand, s).last?.title == "Take Out 1 & Put Away Phone Stand")
        #expect(MenuSpec.objectPutAway(.plant, s).last?.title == "Put Away Plant")
        #expect(MenuSpec.objectPutAway(.riserDrawers, s).last?.title == "Put Away Riser Drawers")
        s.stowed = [.riserDrawers]
        #expect(MenuSpec.objectPutAway(.riserDrawers, s).isEmpty, "nothing to put away while it is away")
        let sealed = MenuSpec.sealedRiser(s, MenuSpec.Context(undo: "Put Away"))
        #expect(sealed.items.first?.id == "bringBack" && sealed.items.first?.title == "Bring Back Riser Drawers")
        #expect(sealed.items.first?.command == .bringBack(.riserDrawers) && sealed.items[1].isSeparator)
        #expect(Array(sealed.items.dropFirst(2)).map(\.id) == MenuSpec.desk(s).items.map(\.id))
        #expect(sealed.item("undo")?.title == "Undo Put Away")
        // The memo clips' container menu gains the same line.
        s.stowed = []
        s.tokens.move(F.key(2), to: .container(.memoClips, order: 0))
        #expect(MenuSpec.memoClipsExtras(s).map(\.title) == ["", "Take Out 1 & Put Away Memo Clips"])
    }

    // MARK: memos (0.3.0)

    @Test("Partition menu: notes, today, calendar, add-ons, the clip light, the D-Day, Put Away")
    func partitionMenu() {
        var s = F.mirrored(["a", "b"])
        let c = MenuSpec.Context(today: DayKey("2026-10-18"))
        let m = MenuSpec.partition(s, c)
        #expect(m.items.map(\.id) == ["newNote", "todayMemo", "calendar", "-", "addOns", "clipLight.toggle", "setDDay", "-", "putAway"])
        #expect(m.item("newNote")?.command == .newNote && m.item("todayMemo")?.command == .openMemos(.today))
        #expect(m.item("setDDay")?.command == .openMemos(.dDay) && m.item("setDDay")?.title == "Set D-Day…")
        #expect(m.item("clipLight.toggle")?.title == "Turn Clip Light On" && m.item("clipLight.toggle")?.command == .clipLight(true))
        #expect(m.item("putAway")?.title == "Put Away Desk Partition" && m.item("putAway")?.command == .putAway(.partition))
        #expect(children(m, "addOns").map(\.id) == ["addOn.dailyPad", "addOn.memoClips", "addOn.clipLight", "addOn.dDayCard"])
        #expect(children(m, "addOns").filter(\.isChecked).count == 4)
        #expect(m.item("addOn.dailyPad")?.command == .putAway(.dailyPad) && m.item("addOn.dailyPad")?.title == "Daily Memo Pad")
        // Files in the clips; the clip light on, then put away; the pad away.
        s.tokens.move(F.key(2), to: .container(.memoClips, order: 0))
        s.clipLightOn = true
        let on = MenuSpec.partition(s, c)
        #expect(on.item("addOn.memoClips")?.title == "Take Out 1 & Put Away Memo Clips")
        #expect(on.item("putAway")?.title == "Take Out 1 & Put Away Desk Partition")
        #expect(on.item("clipLight.toggle")?.title == "Turn Clip Light Off" && on.item("clipLight.toggle")?.command == .clipLight(false))
        s.stowed = [.clipLight, .dailyPad]
        let away = MenuSpec.partition(s, c)
        #expect(away.item("clipLight.toggle") == nil)
        #expect(away.item("addOn.clipLight")?.isChecked == false && away.item("addOn.clipLight")?.command == .bringBack(.clipLight))
        #expect(away.item("addOn.dailyPad")?.title == "Daily Memo Pad")
        // A full partition takes no new note.
        for i in 1...MemoBook.maxNotes {
            s.memos.notes[NoteID(i)] = StickyNote(id: NoteID(i), text: "", colour: .yellow, pos: ArtPoint(371, 67), z: i,
                                                  created: F.t0, edited: F.t0)
        }
        #expect(MenuSpec.partition(s, c).item("newNote")?.isEnabled == false && MenuSpec.cube(s).item("newNote")?.isEnabled == false)
        #expect(MenuSpec.desk(s).item("newNote")?.isEnabled == false)
    }

    @Test("Note menu: edit, colour (current ticked), front, save (connected and written), remove; no user text")
    func noteMenu() {
        var s = F.mirrored(["a"])
        let a = NoteID(1), b = NoteID(2)
        s.memos.notes[a] = StickyNote(id: a, text: "우유 사기", colour: .pink, pos: ArtPoint(371, 67), z: 0, created: F.t0, edited: F.t0)
        s.memos.notes[b] = StickyNote(id: b, text: "", colour: .sky, pos: ArtPoint(401, 67), z: 1, created: F.t0, edited: F.t0)
        let m = MenuSpec.note(a, s)
        #expect(m.items.map(\.id) == ["editNote", "colour", "raiseNote", "saveFile", "-", "removeNote"])
        #expect(m.item("editNote")?.command == .editNote(a) && m.item("removeNote")?.command == .removeNote(a))
        #expect(children(m, "colour").map(\.title) == ["Yellow", "Pink", "Sky", "Lime", "Orange", "Cream"])
        #expect(children(m, "colour").filter(\.isChecked).map(\.id) == ["colour.pink"])
        #expect(m.item("colour.cream")?.command == .noteColour(a, .cream))
        #expect(m.item("raiseNote")?.isEnabled == true && MenuSpec.note(b, s).item("raiseNote")?.isEnabled == false)
        #expect(m.item("saveFile")?.isEnabled == true && m.item("saveFile")?.command == .saveMemoFile(.note(a)))
        #expect(MenuSpec.note(b, s).item("saveFile")?.isEnabled == false, "an empty note has nothing to save")
        s.access = .notConnected
        #expect(MenuSpec.note(a, s).item("saveFile")?.isEnabled == false)
        #expect(!MenuSpec.note(a, s).ids.compactMap { MenuSpec.note(a, s).item($0)?.title }.contains { $0.contains("우유") })
        #expect(MenuSpec.note(NoteID(9), s).items.isEmpty)
        if case .requestSaveMemoFile(.note(a))? = MenuCommand.saveMemoFile(.note(a)).action(s) {} else {
            Issue.record("Save as Text File is a request")
        }
    }

    @Test("Pad, cube, D-Day card, clip light and calendar menus")
    func smallMenus() {
        var s = F.mirrored(["a"])
        let today = DayKey("2026-10-18")!
        let c = MenuSpec.Context(today: today)
        let blank = MenuSpec.dailyPad(s, c)
        #expect(blank.items.map(\.id) == ["todayMemo", "tearOff", "saveFile", "-", "putAway"])
        #expect(blank.item("tearOff")?.isEnabled == false && blank.item("saveFile")?.isEnabled == false)
        #expect(blank.item("putAway")?.title == "Put Away Daily Memo Pad")
        s.memos.pages[today] = "회의"
        let written = MenuSpec.dailyPad(s, c)
        #expect(written.item("tearOff")?.isEnabled == true && written.item("tearOff")?.command == .tearOffPage(today))
        #expect(written.item("saveFile")?.isEnabled == true && written.item("saveFile")?.command == .saveMemoFile(.day(today)))
        #expect(MenuSpec.dailyPad(s, MenuSpec.Context()).item("tearOff")?.isEnabled == false, "no day, nothing to tear")
        if case .tearOffPage(today, at: nil)? = MenuCommand.tearOffPage(today).action(s) {} else { Issue.record("tear off") }

        #expect(MenuSpec.cube(s).items.map(\.id) == ["newNote"])
        let card = MenuSpec.dDayCard(s)
        #expect(card.items.map(\.id) == ["setDDay", "clearDDay", "-", "putAway"] && card.item("clearDDay")?.isEnabled == false)
        s.memos.dDay = DDay(day: today, title: "x")
        #expect(MenuSpec.dDayCard(s).item("clearDDay")?.isEnabled == true)
        if case .setDDay(nil)? = MenuCommand.clearDDay.action(s) {} else { Issue.record("Clear D-Day clears it") }
        let light = MenuSpec.clipLight(s)
        #expect(light.items.map(\.id) == ["clipLight.toggle", "-", "putAway"] && light.item("putAway")?.title == "Put Away Clip Light")

        let day = DayKey("2026-10-30")!
        let cal = MenuSpec.calendar(s, c, day: day)
        #expect(cal.items.map(\.id) == ["dayMemo", "todayMemo", "calendar"] && cal.item("dayMemo")?.command == .openMemos(.day(day)))
        #expect(MenuSpec.calendar(s, c, day: nil).items.map(\.id) == ["todayMemo", "calendar"])
    }

    @Test("The memo and tidy commands: model ones dispatch, app ones do not; demo names")
    func tidyCommands() {
        let s = F.mirrored(["a"])
        let n = NoteID(1)
        for c: MenuCommand in [.newNote, .editNote(n), .openMemos(.today), .arrangeDesk] { #expect(c.action(s) == nil, "\(c)") }
        if case .putAway(.plant)? = MenuCommand.putAway(.plant).action(s) {} else { Issue.record("put away") }
        if case .bringBack(.plant)? = MenuCommand.bringBack(.plant).action(s) {} else { Issue.record("bring back") }
        if case .bringBackAll? = MenuCommand.bringBackAll.action(s) {} else { Issue.record("bring back all") }
        if case .clipLight(true)? = MenuCommand.clipLight(true).action(s) {} else { Issue.record("clip light") }
        if case .noteColour(n, .lime)? = MenuCommand.noteColour(n, .lime).action(s) {} else { Issue.record("colour") }
        if case .raiseNote(n)? = MenuCommand.raiseNote(n).action(s) {} else { Issue.record("raise") }
        if case .removeNote(n)? = MenuCommand.removeNote(n).action(s) {} else { Issue.record("remove") }
        #expect(MenuCommand.newNote.demoName == "newNote" && MenuCommand.editNote(n).demoName == "editNote:N1")
        #expect(MenuCommand.openMemos(.today).demoName == "openMemos:today")
        #expect(MenuCommand.openMemos(.day(DayKey("2026-10-30")!)).demoName == "openMemos:day:2026-10-30")
        #expect(MenuCommand.openMemos(.note(n)).demoName == "openMemos:note:N1")
        #expect(MenuCommand.openMemos(.notes).demoName == "openMemos:notes" && MenuCommand.openMemos(.dDay).demoName == "openMemos:dDay")
        #expect(MenuCommand.arrangeDesk.demoName == "arrangeDesk" && MenuCommand.inventory.demoName == "inventory")
        #expect(MenuCommand.putAway(.cabinet).demoName == "\(MenuCommand.putAway(.cabinet))", "the rest as Swift prints them")
    }

    @Test("Nothing on the 0.3.0 menus changes files except Save as Text File, which is a request")
    func tidyMenusChangeNoFiles() {
        var s = F.mirrored(["a", "b"])
        s.tokens.move(F.key(2), to: .container(.cabinetTop, order: 0))
        s.memos.notes[NoteID(1)] = StickyNote(id: NoteID(1), text: "x", colour: .yellow, pos: ArtPoint(371, 67), z: 0,
                                              created: F.t0, edited: F.t0)
        let c = MenuSpec.Context(today: DayKey("2026-10-18"))
        let specs = [MenuSpec.desk(s, c), MenuSpec.partition(s, c), MenuSpec.note(NoteID(1), s), MenuSpec.dailyPad(s, c),
                     MenuSpec.dDayCard(s), MenuSpec.clipLight(s), MenuSpec(MenuSpec.objectPutAway(.cabinet, s))]
        for spec in specs {
            for id in spec.ids {
                guard let action = spec.item(id)?.command?.action(s) else { continue }
                var copy = s
                let effects = reduce(&copy, action, ReduceEnv(now: F.t0))
                if !action.isRequest { #expect(!effects.contains { $0.touchesFiles }, "\(id) touches files") }
                #expect(copy.violations().isEmpty, "\(id)")
            }
        }
    }
}

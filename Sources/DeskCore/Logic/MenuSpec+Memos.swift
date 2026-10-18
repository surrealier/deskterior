/// The desk partition's menus (Erratum 31): the bare felt, a note, the daily memo pad, the sticky-note cube, the
/// D-Day card, the clip light, the memo clips and the wall calendar. User text never appears in a title, so
/// `MenuBridge` can translate every one; editing happens in the Memos window (`.openMemos`, `.editNote`).
extension MenuSpec {
    /// Right-click on the bare felt, the frame or a post.
    public static func partition(_ s: DeskState, _ c: Context) -> MenuSpec {
        let addOns = StowCatalog.children(of: .partition).map { id in
            let out = s.isOut(id)
            let title = out ? putAwayTitle(id, s, named: false) : StowCatalog.spec(id).title
            return MenuItem("addOn.\(id.rawValue)", title, out ? .putAway(id) : .bringBack(id), checked: out)
        }
        var items = [
            MenuItem("newNote", "New Sticky Note", .newNote, enabled: hasRoom(s)),
            MenuItem("todayMemo", "Today's Memo…", .openMemos(.today)),
            MenuItem("calendar", "Calendar…", .openMemos(.today)),
            .separator,
            MenuItem("addOns", "Add-ons", submenu: addOns),
        ]
        if s.isOut(.clipLight) { items.append(clipLightToggle(s)) }
        items.append(MenuItem("setDDay", "Set D-Day…", .openMemos(.dDay)))
        items += objectPutAway(.partition, s)
        return MenuSpec(items)
    }

    /// Right-click on a sticky note.
    public static func note(_ id: NoteID, _ s: DeskState) -> MenuSpec {
        guard let note = s.memos.notes[id] else { return MenuSpec([]) }
        let colours = NoteColour.allCases.map { c in
            MenuItem("colour.\(c.rawValue)", c.title, .noteColour(id, c), checked: c == note.colour)
        }
        let front = s.memos.notes.values.allSatisfy { $0.id == id || $0.z < note.z }
        return MenuSpec([
            MenuItem("editNote", "Edit Note…", .editNote(id)),
            MenuItem("colour", "Colour", submenu: colours),
            MenuItem("raiseNote", "Bring to Front", .raiseNote(id), enabled: !front),
            MenuItem("saveFile", "Save as Text File on Desktop", .saveMemoFile(.note(id)),
                     enabled: s.access == .connected && !note.text.isEmpty),
            .separator,
            MenuItem("removeNote", "Remove Note", .removeNote(id)),
        ])
    }

    /// Right-click on the daily memo pad.
    public static func dailyPad(_ s: DeskState, _ c: Context) -> MenuSpec {
        let day = c.today ?? noDay
        let written = c.today.map { !(s.memos.pages[$0] ?? "").isEmpty } ?? false
        return MenuSpec([
            MenuItem("todayMemo", "Today's Memo…", .openMemos(.today)),
            MenuItem("tearOff", "Tear Off as Sticky Note", .tearOffPage(day), enabled: written && hasRoom(s)),
            MenuItem("saveFile", "Save Today's Memo as Text File", .saveMemoFile(.day(day)),
                     enabled: written && s.access == .connected),
        ] + objectPutAway(.dailyPad, s))
    }

    /// Right-click on the sticky-note cube.
    public static func cube(_ s: DeskState) -> MenuSpec {
        MenuSpec([MenuItem("newNote", "New Sticky Note", .newNote, enabled: hasRoom(s))])
    }

    /// Right-click on the D-Day card.
    public static func dDayCard(_ s: DeskState) -> MenuSpec {
        MenuSpec([
            MenuItem("setDDay", "Set D-Day…", .openMemos(.dDay)),
            MenuItem("clearDDay", "Clear D-Day", .clearDDay, enabled: s.memos.dDay != nil),
        ] + objectPutAway(.dDayCard, s))
    }

    /// Right-click on the clip light.
    public static func clipLight(_ s: DeskState) -> MenuSpec {
        MenuSpec([clipLightToggle(s)] + objectPutAway(.clipLight, s))
    }

    /// Right-click on the wall calendar (`day`: the cell under the pointer, if any).
    public static func calendar(_ s: DeskState, _ c: Context, day: DayKey?) -> MenuSpec {
        var items: [MenuItem] = []
        if let day { items.append(MenuItem("dayMemo", "Open Memo for This Day…", .openMemos(.day(day)))) }
        items += [
            MenuItem("todayMemo", "Today's Memo…", .openMemos(.today)),
            MenuItem("calendar", "Calendar…", .openMemos(.today)),
        ]
        return MenuSpec(items)
    }

    /// What the memo clips' container menu ends with: a separator and Put Away Memo Clips (or Take Out %d & Put Away
    /// Memo Clips).
    public static func memoClipsExtras(_ s: DeskState) -> [MenuItem] {
        objectPutAway(.memoClips, s)
    }

    /// The desk and status menus' New Sticky Note and Memos….
    static func memoDeskItems(_ s: DeskState) -> [MenuItem] {
        [
            MenuItem("newNote", "New Sticky Note", .newNote, enabled: hasRoom(s)),
            MenuItem("memos", "Memos…", .openMemos(.today)),
        ]
    }

    /// Turn Clip Light On / Off.
    private static func clipLightToggle(_ s: DeskState) -> MenuItem {
        let on = s.clipLightOn
        return MenuItem("clipLight.toggle", on ? "Turn Clip Light Off" : "Turn Clip Light On", .clipLight(!on))
    }

    /// Fewer than 24 notes: another fits.
    private static func hasRoom(_ s: DeskState) -> Bool { s.memos.notes.count < MemoBook.maxNotes }

    /// The day the pad's items name while the context has none (they are disabled then).
    private static let noDay = DayKey(year: 2000, month: 1, day: 1)!
}

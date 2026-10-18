import DeskCore
import DeskPixels
import Foundation
import Testing
@testable import DeskScene

/// Desks with sticky notes, day pages and a D-Day on the partition (Erratum 31).
enum MemoFixture {
    typealias F = SceneFixture

    /// The day the fixture scenes' clock shows (`WallTime`'s default date).
    static let today = DayKey(year: 2026, month: 10, day: 14)!

    static func note(_ n: Int, _ text: String = "", at pos: ArtPoint, colour: NoteColour = .yellow, day: DayKey? = nil,
                     z: Int? = nil) -> StickyNote {
        StickyNote(id: NoteID(n), text: text, colour: colour, pos: pos, z: z ?? n, day: day, created: F.t0, edited: F.t0)
    }

    /// The container fixture's desk with these notes, pages and D-Day, and `stowed` put away.
    static func state(_ notes: [StickyNote] = [], pages: [DayKey: String] = [:], dDay: DDay? = nil,
                      stowed: Set<StowID> = [], clips: [UInt64] = []) -> DeskState {
        var s = ContainerFixture.state(clips.map { ($0, ContainerID.memoClips) })
        for n in notes { s.memos.notes[n.id] = n }
        s.memos.nextNote = (notes.map(\.id.number).max() ?? 0) + 1
        s.memos.pages = pages
        s.memos.dDay = dDay
        s.stowed = stowed
        return s
    }

    /// The canvas point (pixel centre) of core point `(x, y)`.
    static func point(_ scene: DeskScene, core x: Int, _ y: Int) -> SIMD2<Float> {
        let p = scene.layout!.point(ArtPoint(x, y))
        return SIMD2(Float(p.x) + 0.5, Float(p.y) + 0.5)
    }

    static func partition(_ scene: DeskScene) throws -> PartitionElement {
        try #require(try ContainerFixture.room(scene).partitionElement)
    }

    /// The first two default spots on the tower.
    static let tower = PartitionLayout.defaultSpots[0], tower2 = PartitionLayout.defaultSpots[1]
}

@Suite("Partition element")
struct PartitionElementTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture
    typealias M = MemoFixture

    @Test("Notes hit by their pixels, the front one first; raised, the other one wins the overlap")
    func noteHits() throws {
        let a = M.note(1, "back", at: M.tower), b = M.note(2, "front", at: ArtPoint(M.tower.x + 12, M.tower.y + 6))
        let store = SceneStore(M.state([a, b]))
        let scene = store.scene
        let overlap = try #require(scene.noteRect(a.id)).intersection(try #require(scene.noteRect(b.id)))
        #expect(scene.hitTest(overlap.center)?.part == "partition.note.N2")
        let onlyA = try #require(scene.noteRect(a.id)).origin + ArtPoint(3, 10)
        #expect(scene.hitTest(onlyA)?.part == "partition.note.N1")
        // The curled corner of the front note is not the note.
        let curl = try #require(scene.noteRect(b.id))
        #expect(scene.hitTest(ArtPoint(curl.maxX - 1, curl.maxY - 1))?.part != "partition.note.N2")
        var s = store.state
        s.memos.notes[a.id]?.z = 3
        store.state = s
        scene.apply(s)
        #expect(scene.hitTest(overlap.center)?.part == "partition.note.N1")
        #expect(scene.noteRect(NoteID(9)) == nil)
    }

    @Test("Add-ons answer only while out, the D-Day card only while a D-Day is set; the felt answers behind them")
    func modulesWhileOut() throws {
        let scene = F.scene(M.state())
        let a = try #require(scene.layout).anchors
        func part(_ anchor: String) throws -> String? { scene.hitTest(try #require(a.point(anchor)))?.part }
        #expect(try part("partition.cube") == "partition.cube")
        #expect(try part("partition.pad") == "partition.pad")
        #expect(try part("partition.clipLight") == "partition.clipLight")
        #expect(try part("partition.dday") != "partition.dday", "no D-Day, no card")
        #expect(try part("partition.post") == "partition.felt")
        scene.apply(M.state(dDay: DDay(day: M.today.adding(days: 12), title: "수능")))
        #expect(try part("partition.dday") == "partition.dday")
        scene.apply(M.state(dDay: DDay(day: M.today, title: ""), stowed: [.dailyPad, .clipLight, .dDayCard]))
        #expect(try part("partition.pad") == "partition.felt")
        #expect(try part("partition.dday") != "partition.dday" && part("partition.clipLight") != "partition.clipLight")
        // The element alone, whatever the room places: away, nothing.
        let partition = try M.partition(scene)
        for anchor in ["partition.pad", "partition.dday", "partition.clipLight"] {
            #expect(partition.hitTest(try #require(a.point(anchor)))?.part != anchor)
        }
        scene.apply(M.state(stowed: [.partition]))
        #expect(partition.hitTest(try #require(a.point("partition.cube"))) == nil)
        #expect(partition.accessibilityItems().isEmpty)
    }

    @Test("A lit note's tooltip: its first wrapped line, up to four more (the last ending …), and its date")
    func tooltipBody() throws {
        let font = try #require(PixelFont.galmuri9)
        let text = "Call mom\nabout Sunday\nthree\nfour\nfive\nsix"
        let n = M.note(3, text, at: M.tower, day: M.today.adding(days: 3))
        let spec = PartitionElement.noteTooltip(n, today: M.today, lit: true, font: font, anchor: .zero)
        #expect(spec.title == "Call mom")
        #expect(spec.body == ["about Sunday", "three", "four", "five…"])
        #expect(spec.detail?.hasSuffix(" · D-3") == true)
        // A long line wraps; the tooltip grows a line per body line.
        let long = M.note(4, String(repeating: "가나다라 ", count: 12), at: M.tower)
        let wrapped = PartitionElement.noteTooltip(long, today: M.today, lit: true, font: font, anchor: .zero)
        #expect(!wrapped.body.isEmpty && wrapped.detail == nil)
        for line in [wrapped.title] + wrapped.body { #expect(PixelText.width(line, font: font) <= TooltipArt.maxTextWidth) }
        let plain = TooltipArt.render(TooltipSpec(title: "Call mom", anchor: .zero), font: font)
        let tall = TooltipArt.render(spec, font: font)
        let line = PixelText.line("Aa", .neutral9, font: font).height + TooltipArt.lineGap
        #expect(tall.height == plain.height + line * 5, "four body lines and the detail")
        #expect(tall.pixels.contains(Ink.neutral8.color), "body lines are neutral8")
        // An empty note says what it is.
        let empty = PartitionElement.noteTooltip(M.note(5, at: M.tower), today: M.today, lit: true, font: font, anchor: .zero)
        #expect(empty.title == "Sticky Note" && empty.body.isEmpty)
    }

    @Test("darkNoteIsAnonymous: unlit, a note's tooltip and VoiceOver label are only Sticky Note; a click still opens it")
    func darkNoteIsAnonymous() throws {
        var s = M.state([M.note(1, "우유 사기", at: M.tower, day: M.today)])
        s.monitor.power = .off
        let store = SceneStore(s, time: WallTime(hour: 22, minute: 0))
        let scene = store.scene
        scene.lightsMode = .lampOnly
        let p = Pointer(scene: scene)
        let partition = try M.partition(scene)
        let r = try #require(scene.noteRect(NoteID(1)))
        #expect(!scene.isTokenLit(r), "the tower is dark in Lamp Only")
        let hit = Hit(element: "partition", part: "partition.note.N1", rect: r)
        let spec = try #require(partition.tooltip(hit))
        #expect(spec.title == "Sticky Note" && spec.body.isEmpty && spec.detail == nil)
        #expect(partition.accessibilityItems().first { $0.id == "note.N1" }?.label == "Sticky Note")
        p.click(F.centre(r))
        #expect(store.requests.contains(.command(.editNote(NoteID(1)))))
        // By day the same note shows its text.
        scene.lightsMode = .auto
        scene.clock = .fixed(WallTime(hour: 10, minute: 0))
        #expect(partition.tooltip(hit)?.title == "우유 사기")
        #expect(partition.accessibilityItems().first { $0.id == "note.N1" }?.label == "Sticky note: 우유 사기")
    }

    @Test("A click on the cube adds a note and opens it; on the pad today's memo, the D-Day card its editor, the clip light switches")
    func clicks() throws {
        let store = SceneStore(M.state(dDay: DDay(day: M.today, title: "D")))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let a = try #require(scene.layout).anchors
        p.click(F.centre(try #require(a["partition.cube"])))
        #expect(store.actions.first { $0.hasPrefix("addNote") } == "\(DeskAction.addNote(NewNote(id: NoteID(1), text: "", colour: .yellow), session: nil))")
        #expect(store.requests.contains(.command(.editNote(NoteID(1)))))
        p.click(F.centre(try #require(a["partition.pad"])))
        #expect(store.requests.contains(.command(.openMemos(.today))))
        p.click(F.centre(try #require(a["partition.dday"])))
        #expect(store.requests.contains(.command(.openMemos(.dDay))))
        p.click(F.centre(try #require(a["partition.clipLight"])))
        #expect(store.actions.contains("\(DeskAction.clipLight(true))"))
    }

    @Test("The element's gestures, straight: the cube's click (none opened when full), a note's click, the felt passes")
    func gestures() throws {
        let store = SceneStore(M.state([M.note(1, "x", at: M.tower)]))
        let partition = try M.partition(store.scene)
        let cube = Hit(element: "partition", part: PartitionElement.cubePart, rect: partition.cubeRect)
        _ = partition.handle(.click(.zero, [], count: 1), cube)
        #expect(store.actions.last == "\(DeskAction.addNote(NewNote(id: NoteID(2), text: "", colour: .yellow), session: nil))")
        #expect(store.requests.last == .command(.editNote(NoteID(2))))
        let note = Hit(element: "partition", part: "partition.note.N1", rect: partition.cubeRect)
        _ = partition.handle(.click(.zero, [], count: 1), note)
        #expect(store.requests.last == .command(.editNote(NoteID(1))))
        let felt = Hit(element: "partition", part: PartitionElement.feltPart, rect: partition.partitionRect)
        if case .pass = partition.handle(.click(.zero, [], count: 1), felt) {} else { Issue.record("the felt passes") }
        #expect(partition.hoverStyle(felt).isNone && partition.tooltip(felt) == nil)
        // Full: the reducer refuses the note (and toasts), so no editor opens.
        let full = (1...MemoBook.maxNotes).map { M.note($0, at: M.tower) }
        let fullStore = SceneStore(M.state(full))
        let fullPartition = try M.partition(fullStore.scene)
        _ = fullPartition.handle(.click(.zero, [], count: 1), cube)
        #expect(fullStore.requests.isEmpty)
    }

    @Test("Files dropped on the felt clip up to the memo clips; full, they bonk; away, the felt takes none")
    func feltDrop() throws {
        let store = SceneStore(M.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        // Bare felt on the right wing, below the D-Day card's hook and right of the clips.
        let felt = M.point(scene, core: 480, 150)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(1)))), felt)
        #expect(store.actions.last == "move([\(F.key(1))], to: memoClips#0)")
        let partition = try M.partition(scene)
        let point = ArtPoint(Int(felt.x), Int(felt.y))
        let full = M.state(clips: [1, 2, 3, 4, 5])
        scene.apply(full)
        #expect(partition.dropVerdict([F.key(6)], at: point) == .bonk(.memoClipsFull))
        #expect(partition.dropVerdict([F.key(1)], at: point) == .accept(.container(.memoClips, order: 5)), "a clipped file moves along")
        scene.apply(M.state(stowed: [.memoClips]))
        #expect(partition.dropVerdict([F.key(6)], at: point) == nil)
    }

    @Test("VoiceOver: each note a button, the cube, the pad with its day, the D-Day card, the clip light, the partition")
    func accessibility() throws {
        var s = M.state([M.note(1, "우유 사기\n두 번째", at: M.tower), M.note(2, at: M.tower2)],
                        pages: [M.today: "회의"], dDay: DDay(day: M.today.adding(days: 12), title: "수능"))
        s.clipLightOn = false
        let scene = F.scene(s)
        let items = try M.partition(scene).accessibilityItems()
        #expect(items.map(\.id) == ["note.N2", "note.N1", "partition.cube", "partition.pad", "partition.dday",
                                    "partition.clipLight", "partition"])
        let label = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.label) })
        #expect(label["note.N1"] == "Sticky note: 우유 사기" && label["note.N2"] == "Sticky Note")
        #expect(label["partition.cube"] == "New Sticky Note")
        #expect(label["partition.pad"]?.hasPrefix("Daily memo pad, ") == true)
        #expect(label["partition.pad"]?.hasSuffix(", has a memo") == true)
        #expect(label["partition.dday"] == "D-Day: 수능, 12 days left")
        #expect(label["partition.clipLight"] == "Clip light, Off")
        #expect(label["partition"] == "Desk partition")
        #expect(items.first { $0.id == "partition" }?.role == .group)
    }

    @Test("At rest nothing animates; a new note pops for three frames (none with Reduce Motion)")
    func idleAndPop() throws {
        let store = SceneStore(M.state([M.note(1, "a", at: M.tower)]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        C.settle(p)
        #expect(!scene.needsFrames)
        let partition = try M.partition(scene)
        scene.play(.notePop, .note(NoteID(1)))
        #expect(partition.needsFrames)
        let frames = C.settle(p)
        #expect(frames >= 14 && frames <= 16, "three 12 fps frames: \(frames)")
        scene.reduceMotion = true
        scene.play(.notePop, .note(NoteID(1)))
        #expect(!partition.needsFrames)
    }

    @Test("NoteSprite: the first line clipped to whole glyphs in 26 px, a rule per further line (two at most)")
    func noteSprite() throws {
        let font = try #require(PixelFont.galmuri9)
        let look = NoteSprite.look(M.note(1, "우유 사기\n둘\n셋\n넷", at: M.tower), font: font)
        #expect(look.line == "우유 " && look.scribbles == 2 && look.pinned && !look.dated)
        #expect(font.measure(look.line) <= 26)
        #expect(NoteSprite.look(M.note(2, "  \n\nCall", at: M.tower, colour: .sky), font: font).line == "Call")
        let image = NoteSprite.image(M.note(2, "Call mom", at: M.tower), font: font)
        #expect(image.size == PartitionLayout.noteSize)
        #expect(image.pixels.allSatisfy { $0.a == 0 || ($0.a == 255 && Apollo.index(of: $0) != nil) })
        #expect(NoteSprite.grown(image).size == ArtSize(32, 26))
    }

    /// The partition (core 8…504 × 44…176) as the scene draws it, lit, with notes and the pad's line.
    func partitionImage(_ scene: DeskScene) throws -> PixelBuffer {
        let room = try C.room(scene)
        let layout = room.layout
        let state = room.state
        let art = try M.partition(scene).compose(over: RoomPlan.compose(layout, state))
        let tod = state.timeOfDay
        let lit = LightMask.room(layout, lights: state.effectiveLights, time: tod).apply(to: art, ambient: tod.ambient)
        return lit.cropped(to: layout.rect(ArtRect(8, 44, 496, 132)))
    }

    static func goldenState() -> DeskState {
        M.state([M.note(1, "우유 사기", at: PartitionLayout.defaultSpots[0]),
                 M.note(2, "택배 반품", at: PartitionLayout.defaultSpots[1], colour: .pink),
                 M.note(3, "Call mom\nabout Sunday", at: PartitionLayout.defaultSpots[2], colour: .sky),
                 M.note(4, "회의 3시\n자료 준비", at: PartitionLayout.defaultSpots[4], colour: .cream, day: M.today),
                 M.note(5, "D-12", at: PartitionLayout.defaultSpots[7], colour: .lime)],
                pages: [M.today: "회의 3시\n자료 준비"], dDay: DDay(day: M.today.adding(days: 12), title: "중간고사"))
    }

    @Test("CPU golden: the partition with notes by day")
    func goldenDay() throws {
        let scene = F.scene(Self.goldenState())
        #expect(Golden.match(try partitionImage(scene), "partition-notes-day"))
    }

    @Test("CPU golden: the partition with notes at night, the clip light on (Korean text)")
    func goldenNightClipLight() throws {
        var s = Self.goldenState()
        s.clipLightOn = true
        let scene = F.scene(s, time: WallTime(hour: 22, minute: 0))
        #expect(Golden.match(try partitionImage(scene), "partition-notes-night-cliplight"))
    }
}

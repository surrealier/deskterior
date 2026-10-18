import Foundation
import Testing
@testable import DeskCore

@Suite("DeskDocument")
struct DeskDocumentTests {
    typealias F = ModelFixture

    static func fixture(_ name: String = "desk-v1.json", filePath: String = #filePath) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true).appendingPathComponent(name))
    }

    static func json(_ s: String) -> Data { Data(s.utf8) }

    /// A state with tokens in every kind of place plus non-default element state.
    static func richState() -> DeskState {
        var s = F.mirrored(["a.txt", "b.png", "c.zip", "d.md", "e.pdf", "f.txt", "g.txt"])
        s.tokens.move(F.key(2), to: .container(.cabinetMiddle, order: 0))
        s.tokens.move(F.key(6), to: .container(.cabinetMiddle, order: 1))
        s.piles["P2"] = [281, 44]
        s.tokens.move(F.key(3), to: .desk(pile: "P2", order: 0))
        s.tokens.move(F.key(4), to: .floor(x: 210))
        s.tokens.move(F.key(5), to: .screen(page: 1, col: 3, row: 4))
        s.tokens.updateMeta(F.key(1), TokenMeta(
            name: "보고서.pdf".decomposedStringWithCanonicalMapping, kind: .pdf, added: F.t0, modified: F.t0 + 0.125,
            size: 4096, tags: ["Red", "Work"], isPackage: false, isDataless: true, isAlias: false, hidesExtension: true
        ))
        s.monitor = { var m = MonitorState(); m.power = .off; m.page = 1; m.pendingNew = 2; return m }()
        s.drawers[.cabinetTop] = DrawerState(p: 12)
        s.phone.faceDown = true
        s.penCup = PenCupState(state: "lying", pos: [300, 90])
        s.wastebasket = BasketState(state: "upright", swishes: 12)
        s.chair = ChairState(x: 320.5, facing: 3)
        s.lights = LightsState(mode: .lampOnly, room: false, lamp: true)
        s.brush = BrushState(pos: [400, 50])
        s.mat.angle = 0.25
        s.mat.particles = "AAAA"
        s.hostDisplayUUID = "37D8"
        s.flags.onboardingStep = 4
        s.flags.askedCoverDisplays = true
        // MARK: tidy (0.3.0)
        s.stowed = [.plant, .wallShelf, .clipLight]
        s.clipLightOn = true
        s.tombstones = [Tombstone(
            key: F.key(99), name: "gone.png", kind: .image, loc: .container(.riserLeft, order: 0), until: F.t0 + 3600,
            pilePos: [1, 2]
        )]
        return s
    }

    @Test("The §13 schema-1 example decodes")
    func v1Fixture() throws {
        let doc = try DeskDocument.decode(try Self.fixture())
        #expect(doc.schema == 1 && doc.layoutVersion == 1 && doc.app == "0.1.0")
        #expect(doc.savedAt == ISODate.parse("2026-10-13T12:00:00Z"))
        #expect(doc.root == DesktopRoot(path: "/Users/x/Desktop", volume: "8F1C…"))
        #expect(doc.monitor.power == .off && doc.monitor.page == 1 && doc.monitor.pendingNew == 2)
        #expect(doc.drawers["cabinetTop"]?.p == 12 && doc.drawers["cabinetMiddle"]?.p == 2)
        #expect(doc.phone.faceDown && doc.wastebasket.swishes == 12 && doc.penCup.pos == [367, 120])
        #expect(doc.mat.angle == 0.12 && doc.mat.grid == [35, 15] && doc.mat.particles == "<base64 Float32LE xyz × 525>")
        #expect(doc.piles == [.init(id: "P1", pos: [281, 44])])
        #expect(doc.tokens.map(\.loc) == [
            .screen(page: 0, col: 2, row: 1), .container(.cabinetMiddle, order: 3), .desk(pile: "P1", order: 0), .floor(x: 210),
        ])
        #expect(doc.tokens[0].meta.name == "보고서.pdf" && doc.tokens[0].meta.kind == .pdf && doc.tokens[0].meta.added != nil)
        #expect(doc.tokens[1].key == TokenKey(volume: "8F1C…", inode: 2_345_678))
        #expect(doc.tombstones.count == 1 && doc.tombstones[0].loc == .container(.riserLeft, order: 0))
        #expect(doc.flags.onboardingStep == 5 && doc.flags.askedCoverDisplays)
        // MARK: tidy (0.3.0): a 0.1/0.2 file has everything out and the clip light off.
        #expect(doc.stowed.isEmpty && !doc.clipLight)

        let s = doc.makeState()
        #expect(s.violations().isEmpty)
        #expect(s.access == .connected)
        #expect(s.tokens.count == 4)
        // Orders are re-packed (the only cabinet item is #0) and the page is clamped to the pages in use.
        #expect(s.tokens.location(of: TokenKey(volume: "8F1C…", inode: 2_345_678)) == .container(.cabinetMiddle, order: 0))
        #expect(s.monitor.page == 0)
        #expect(s.piles == [PileID("P1"): [281, 44]])
    }

    @Test("State → JSON → state round-trips exactly")
    func roundTrip() throws {
        let state = Self.richState()
        #expect(state.violations().isEmpty)
        let doc = DeskDocument(state: state, savedAt: F.t0)
        let data = try doc.encoded()
        let back = try DeskDocument.decode(data)
        #expect(back == doc)
        #expect(back.makeState() == state)
        // Stable bytes: encoding again is identical.
        #expect(try back.encoded() == data)
        // DeskState's own Codable goes through the document.
        let viaState = try JSONDecoder().decode(DeskState.self, from: try JSONEncoder().encode(state))
        #expect(viaState.tokens == state.tokens)
    }

    @Test("Locations have the §13 JSON shapes")
    func locationJSON() throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let cases: [(Location, String)] = [
            (.screen(page: 0, col: 2, row: 1), #"{"screen":{"col":2,"page":0,"row":1}}"#),
            (.container(.cabinetMiddle, order: 3), #"{"container":{"id":"cabinetMiddle","order":3}}"#),
            (.desk(pile: "P1", order: 0), #"{"desk":{"order":0,"pile":"P1"}}"#),
            (.floor(x: 210), #"{"floor":{"x":210}}"#),
            (.carried, #"{"carried":{}}"#),
        ]
        for (loc, json) in cases {
            #expect(String(decoding: try e.encode(loc), as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(Location.self, from: Self.json(json)) == loc)
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Location.self, from: Self.json(#"{"floor":{"x":1},"carried":{}}"#)) }
    }

    @Test("Token metadata writes only what it has")
    func metaJSON() throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let meta = TokenMeta(name: "a.txt", kind: .text)
        #expect(String(decoding: try e.encode(meta), as: UTF8.self) == #"{"kind":"text","name":"a.txt"}"#)
        let unknownKind = try JSONDecoder().decode(TokenMeta.self, from: Self.json(#"{"name":"x","kind":"hologram"}"#))
        #expect(unknownKind.kind == .unknown && unknownKind.displayName == "x")
    }

    @Test("Decoding degrades per field and per token; structural damage fails")
    func lenientDecoding() throws {
        let doc = try DeskDocument.decode(Self.json("""
            {"schema": 1, "monitor": {"power": "dim", "page": "two"}, "lights": {"mode": "disco"}, "future": [1, 2],
             "tokens": [
               {"key": {"volume": "V", "inode": 1}, "meta": {"name": "ok.txt", "kind": "text"}, "loc": {"floor": {"x": 3}}},
               {"key": {"volume": "V"}, "meta": {"name": "broken"}, "loc": {"floor": {"x": 4}}},
               {"key": {"volume": "V", "inode": 2}, "meta": {"name": "nowhere"}, "loc": {"attic": {}}}
             ]}
            """))
        #expect(doc.monitor == MonitorState())
        #expect(doc.lights.mode == .auto)
        #expect(doc.tokens.map(\.meta.name) == ["ok.txt"])

        #expect(throws: (any Error).self) { try DeskDocument.decode(Self.json(#"{"schema": 1, "tokens": {"a": 1}}"#)) }
        #expect(throws: Migrations.Failure.newerSchema(2)) { try DeskDocument.decode(Self.json(#"{"schema": 2}"#)) }
        #expect(throws: Migrations.Failure.missingSchema) { try DeskDocument.decode(Self.json(#"{"tokens": []}"#)) }
        #expect(throws: Migrations.Failure.notAnObject) { try DeskDocument.decode(Self.json("[1]")) }
        #expect(throws: (any Error).self) { try DeskDocument.decode(Self.json("{\"schema\": 1, ")) }
        #expect(throws: (any Error).self) { try DeskDocument.decode(Data()) }
    }

    @Test("Rebuilding repairs impossible layouts")
    func repairs() throws {
        var doc = DeskDocument()
        func t(_ i: UInt64, _ loc: Location) -> DeskDocument.TokenEntry {
            .init(key: F.key(i), meta: TokenMeta(name: "t\(i)", kind: .text), loc: loc)
        }
        doc.tokens = [
            t(1, .screen(page: 0, col: 0, row: 0)), t(2, .screen(page: 0, col: 0, row: 0)), t(3, .screen(page: 0, col: 12, row: 0)),
            t(4, .container(.riserLeft, order: 5)), t(5, .container(.riserLeft, order: 2)), t(6, .carried),
            t(7, .desk(pile: "P9", order: 4)),
        ] + (10..<17).map { t(UInt64($0), .container(.penCup, order: $0)) }
        let s = doc.makeState()
        #expect(s.violations().isEmpty)
        #expect(s.tokens.count == 14)
        #expect(s.tokens.location(of: F.key(1)) == .screen(page: 0, col: 0, row: 0))
        #expect(s.tokens.location(of: F.key(2)) == .screen(page: 0, col: 1, row: 0))
        #expect(s.tokens.location(of: F.key(3)) == .screen(page: 0, col: 2, row: 0))
        #expect(s.tokens.members(of: .riserLeft) == [F.key(5), F.key(4)])
        #expect(s.tokens.location(of: F.key(6)) == .screen(page: 0, col: 3, row: 0))
        #expect(s.tokens.location(of: F.key(7)) == .desk(pile: "P9", order: 0))
        #expect(s.piles[PileID("P9")] == Placement.defaultPilePos)
        #expect(s.tokens.count(in: .penCup) == 6)
        #expect(s.tokens.location(of: F.key(16))?.isScreen == true)
    }

    @Test("A carried token is saved at a free cell, never as carried")
    func carriedIsNotPersisted() throws {
        var s = F.mirrored(["a", "b"])
        s.tokens.move(F.key(1), to: .carried)
        let doc = DeskDocument(state: s, savedAt: F.t0)
        #expect(doc.tokens.first { $0.key == F.key(1) }?.loc == .screen(page: 0, col: 0, row: 0))
        #expect(!String(decoding: try doc.encoded(), as: UTF8.self).contains("carried"))
    }

    @Test("A carry interrupted by a quit commits the token to its origin")
    func carriedSavesOrigin() throws {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt"])
        _ = reduce(&s, .move([F.key(1)], to: .container(.phone, order: 0)), ReduceEnv(now: F.t0))
        _ = reduce(&s, .move([F.key(1)], to: .carried), ReduceEnv(now: F.t0))
        _ = reduce(&s, .move([F.key(2)], to: .desk(pile: "P1", order: 0)), ReduceEnv(now: F.t0))
        _ = reduce(&s, .pilesSettled(["P1": [120, 30]]), ReduceEnv(now: F.t0))
        _ = reduce(&s, .move([F.key(2)], to: .carried), ReduceEnv(now: F.t0))
        #expect(s.piles[PileID("P1")] == [120, 30], "the emptied pile waits for its carried token")
        #expect(s.violations().isEmpty)
        let restored = try DeskDocument.decode(DeskDocument(state: s, savedAt: F.t0).encoded()).makeState()
        #expect(restored.tokens.location(of: F.key(1)) == .container(.phone, order: 0))
        #expect(restored.tokens.location(of: F.key(2)) == .desk(pile: "P1", order: 0))
        #expect(restored.piles[PileID("P1")] == [120, 30])
        // Dropping it elsewhere forgets the origin, and the empty pile goes.
        _ = reduce(&s, .move([F.key(2)], to: .floor(x: 30)), ReduceEnv(now: F.t0))
        #expect(s.piles.isEmpty && s.violations().isEmpty)
    }

    @Test("Non-finite element state is written as defaults, never as an encoding failure")
    func nonFiniteEncodes() throws {
        var s = Self.richState()
        s.drawers[.riserLeft] = DrawerState(p: .nan)
        s.penCup.pos = [.infinity, 1]
        s.chair.x = .nan
        s.brush.pos = [1, .nan]
        s.mat.angle = .nan
        s.piles["P2"] = [.nan, 0]
        s.tombstones[0].pilePos = [.nan, .nan]
        let doc = try DeskDocument.decode(DeskDocument(state: s, savedAt: F.t0).encoded())
        #expect(doc.drawers["riserLeft"] == DrawerState())
        #expect(doc.penCup.pos == PenCupState().pos && doc.chair.x == ChairState().x && doc.brush == BrushState())
        #expect(doc.mat.angle == MatState().angle)
        #expect(doc.piles.first { $0.id == "P2" }?.pos == Placement.defaultPilePos)
        #expect(doc.tombstones[0].pilePos == nil)
    }

    @Test("A token list of which nothing can be read is damage, not an empty desk")
    func allTokensBad() {
        #expect(throws: (any Error).self) {
            try DeskDocument.decode(Self.json(#"{"schema":1,"tokens":[{"key":7},{"loc":{}}]}"#))
        }
        #expect((try? DeskDocument.decode(Self.json(#"{"schema":1,"tokens":[]}"#)))?.tokens.isEmpty == true)
    }

    @Test("Dates round-trip exactly to the millisecond, so a reloaded layout equals a fresh scan")
    func exactMilliseconds() throws {
        for i in 0..<2000 {
            let d = ISODate.wholeMilliseconds(Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 0.0137))
            #expect(ISODate.parse(ISODate.format(d)) == d, "\(ISODate.format(d))")
        }
        #expect(ISODate.parse("2026-09-21T14:13:20.5Z") == Date(timeIntervalSince1970: 1_790_000_000.5))
        #expect(ISODate.parse("2026-09-21T14:13:20.Z") == nil)
        let meta = TokenMeta(name: "a", kind: .text, modified: Date(timeIntervalSince1970: 1_790_000_000.123456), created: F.t0 + 0.0004)
        let back = try DeskDocument.makeDecoder().decode(TokenMeta.self, from: DeskDocument.makeEncoder().encode(meta))
        #expect(back == meta)
        #expect(back.created == F.t0)
    }

    @Test("Dates keep milliseconds and print whole seconds plainly")
    func dates() {
        let whole = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(ISODate.format(whole) == "2026-09-21T14:13:20Z")
        let ms = whole.addingTimeInterval(0.25)
        #expect(ISODate.format(ms) == "2026-09-21T14:13:20.250Z")
        #expect(ISODate.parse(ISODate.format(ms)) == ms)
        #expect(ISODate.parse("2026-10-01T09:00:00Z") != nil)
        #expect(ISODate.parse("yesterday") == nil)
    }

    // MARK: tidy (0.3.0)

    @Test("What is put away and the clip light are written always, sorted; unknown values are skipped")
    func stowedJSON() throws {
        let doc = DeskDocument(state: Self.richState(), savedAt: F.t0)
        #expect(doc.stowed == ["clipLight", "plant", "wallShelf"] && doc.clipLight)
        let text = String(decoding: try DeskDocument(state: F.mirrored(["a"]), savedAt: F.t0).encoded(), as: UTF8.self)
        #expect(text.contains("\"stowed\" : [") && text.contains("\"clipLight\" : false"))
        let lenient = try DeskDocument.decode(Self.json(
            #"{"schema": 1, "stowed": ["plant", "hovercraft", 7, "plant", "cabinet"], "clipLight": "yes"}"#
        ))
        #expect(lenient.stowed == ["cabinet", "plant"] && !lenient.clipLight)
        let notList = try DeskDocument.decode(Self.json(#"{"schema": 1, "stowed": "plant", "clipLight": true}"#))
        #expect(notList.stowed.isEmpty && notList.clipLight)
        #expect(notList.makeState().clipLightOn && lenient.makeState().stowed == [.cabinet, .plant])
    }

    @Test("Loading never leaves a file inside a put-away place: its object comes back, nothing becomes visible")
    func sanitizeBringsBack() throws {
        let doc = try DeskDocument.decode(Self.json("""
            {"schema": 1, "stowed": ["cabinet", "partition", "plant", "dailyPad", "riserDrawers"],
             "drawers": {"cabinetTop": {"p": 0}, "riserLeft": {"p": 5}, "riserRight": {"p": 0}},
             "tokens": [
               {"key": {"volume": "V", "inode": 1}, "meta": {"name": "a.txt", "kind": "text"},
                "loc": {"container": {"id": "cabinetTop", "order": 0}}},
               {"key": {"volume": "V", "inode": 2}, "meta": {"name": "b.txt", "kind": "text"},
                "loc": {"container": {"id": "memoClips", "order": 0}}}
             ]}
            """))
        #expect(doc.stowed == ["dailyPad", "plant", "riserDrawers"], "the add-on keeps its own flag")
        #expect(doc.drawers["riserLeft"]?.p == 0 && doc.drawers["cabinetTop"]?.p == 0, "an away drawer rests shut")
        let s = doc.makeState()
        #expect(s.violations().isEmpty && s.tokens.location(of: TokenKey(volume: "V", inode: 2)) == .container(.memoClips, order: 0))
        #expect(s.isOut(.partition) && !s.isOut(.dailyPad) && s.isOut(.cabinet))
        // A document made in code goes through the same rule when it becomes a state.
        var raw = DeskDocument()
        raw.stowed = ["phoneStand"]
        raw.tokens = [.init(key: F.key(1), meta: TokenMeta(name: "p", kind: .text), loc: .container(.phone, order: 0))]
        #expect(raw.makeState().stowed.isEmpty && raw.makeState().violations().isEmpty)
    }
}

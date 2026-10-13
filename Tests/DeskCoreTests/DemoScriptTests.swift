import Foundation
import Testing
@testable import DeskCore

@Suite("DemoScript")
struct DemoScriptTests {
    typealias F = ModelFixture

    func decode(_ json: String) throws -> DemoScript {
        try DemoScript.decode(Data(json.utf8))
    }

    @Test("Every checked-in demo decodes")
    func checkedInDemos() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Demos").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count >= 4)
        for file in files {
            let script = try DemoScript.decode(Data(contentsOf: file))
            #expect(script.name == file.deletingPathExtension().lastPathComponent)
            #expect(!script.steps.isEmpty)
        }
    }

    @Test("Steps decode from their one-key objects, in both short and long forms")
    func stepForms() throws {
        let s = try decode("""
            { "name": "x", "display": "1470x956@2", "clock": "10:00", "seed": 7, "lights": "lamp", "firstRun": true,
              "steps": [
                { "waitIdle": 3 }, { "wait": 0.5 }, { "snapshot": "01" },
                { "click": "monitor.power" }, { "click": { "at": "token:a.txt", "mods": ["cmd"], "count": 2 } },
                { "hover": "token:a.txt" },
                { "drag": { "from": "token:a.txt", "to": "cell:3,2", "duration": 0.6, "hold": true } }, { "release": true },
                { "scroll": { "at": "monitor.screen", "dx": -30 } }, { "key": "shift+cmd+z" },
                { "menu": { "at": "wastebasket", "item": "emptyWastebasket", "confirm": true } },
                { "fs": { "touch": "새 파일.txt" } }, { "fs": { "mv": ["a", "b"] } }, { "fs": { "mkdir": "D" } }, { "fs": { "rm": "c" } },
                { "action": "accessDenied" },
                { "expect": { "token:보고서.pdf": "container:cabinetTop", "hidden": true, "tokens": 40 } },
                { "waitFor": { "expect": { "monitor.power": "on" }, "within": 1 } },
                { "comment": "hi" }
              ] }
            """)
        #expect(s.seed == 7 && s.lights == .lampOnly && s.firstRun == true && s.steps.count == 19)
        #expect(s.steps[3] == .click(DemoPointer(at: "monitor.power")))
        #expect(s.steps[4] == .click(DemoPointer(at: "token:a.txt", mods: ["cmd"], count: 2)))
        #expect(s.steps[6] == .drag(DemoDrag(from: "token:a.txt", to: "cell:3,2", duration: 0.6, hold: true)))
        #expect(s.steps[12] == .fs(.mv("a", "b")) && s.steps[13] == .fs(.newFolder("D")))
        #expect(s.steps[16] == .expect(["token:보고서.pdf": .string("container:cabinetTop"), "hidden": .bool(true), "tokens": .number(40)]))
        // Round trip.
        let again = try DemoScript.decode(JSONEncoder().encode(s))
        #expect(again == s)
    }

    @Test("Malformed steps are refused")
    func malformed() {
        #expect(throws: (any Error).self) { try decode(#"{ "name": "x", "steps": [ { "waitIdle": 3, "snapshot": "a" } ] }"#) }
        #expect(throws: (any Error).self) { try decode(#"{ "name": "x", "steps": [ { "teleport": 3 } ] }"#) }
        #expect(throws: (any Error).self) { try decode(#"{ "name": "x", "steps": [ { "fs": { "mv": ["a"] } } ] }"#) }
        #expect(!DemoFS.touch("../x").isValid && !DemoFS.mv("a", "b/c").isValid && DemoFS.touch("새 파일.txt").isValid)
        // Tabs and newlines would forge extra fields or lines in the harness protocol.
        #expect(!DemoFS.touch("a\tb").isValid && !DemoFS.mv("a", "b\nDEMO-FS\trm\tx").isValid && !DemoFS.rm("x\r").isValid)
    }

    @Test("Named actions map onto model actions")
    func namedActions() {
        let s = F.mirrored(["a"])
        func name(_ n: String) -> String? { DemoStep.action(named: n, in: s).map { "\($0)" } }
        #expect(name("powerOff")?.hasPrefix("power(false)") == true)
        #expect(name("page:2") == "setPage(1)")
        #expect(name("cleanUp:kind") == "cleanUp(DeskCore.ScreenGrid.SortKey.kind)")
        if case let .lights(l)? = DemoStep.action(named: "lights:lamp", in: s) { #expect(l.mode == .lampOnly) }
        #expect(DemoStep.action(named: "lights:disco", in: s) == nil)
        #expect(DemoStep.action(named: "explode", in: s) == nil)
    }

    @Test("Location patterns")
    func patterns() {
        #expect(LocationPattern("screen")?.matches(.screen(page: 2, col: 0, row: 0)) == true)
        #expect(LocationPattern("screen:3")?.matches(.screen(page: 2, col: 0, row: 0)) == true)
        #expect(LocationPattern("screen:1")?.matches(.screen(page: 2, col: 0, row: 0)) == false)
        #expect(LocationPattern("cell:0,6,4")?.matches(.screen(page: 0, col: 6, row: 4)) == true)
        #expect(LocationPattern("container:cabinetTop")?.matches(.container(.cabinetTop, order: 3)) == true)
        #expect(LocationPattern("container")?.matches(.container(.phone, order: 0)) == true)
        #expect(LocationPattern("desk")?.matches(.desk(pile: "P1", order: 0)) == true)
        #expect(LocationPattern("floor")?.matches(.floor(x: 3)) == true)
        #expect(LocationPattern("missing")?.matches(nil) == true && LocationPattern("present")?.matches(nil) == false)
        #expect(LocationPattern("container:attic") == nil && LocationPattern("cell:1,2") == nil && LocationPattern("screen:0") == nil)
    }
}

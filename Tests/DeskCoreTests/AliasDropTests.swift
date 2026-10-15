import Foundation
import Testing
@testable import DeskCore

/// Erratum 29: apps dropped onto the desk become aliases. The op each dropped item asks for, what the drag source is
/// told, the alias's name, the reducer's hints and effect, the undo label, the toasts and the demo script.
@Suite("Drop-in aliases (Erratum 29)")
struct AliasDropTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    // MARK: The rules

    struct OpCase: Sendable, CustomStringConvertible {
        var mode: DropMode
        var isApp: Bool
        var canMove = true
        var canAlias = true
        var expected: ImportOp
        var description: String { "\(mode) app:\(isApp) move:\(canMove) alias:\(canAlias) → \(expected)" }
    }

    static let opCases: [OpCase] = [
        // No key: an app becomes an alias; anything else moves (copied when the source offers no move).
        OpCase(mode: .standard, isApp: true, expected: .alias),
        OpCase(mode: .standard, isApp: false, expected: .move),
        OpCase(mode: .standard, isApp: false, canMove: false, expected: .copy),
        OpCase(mode: .standard, isApp: true, canMove: false, expected: .alias),
        OpCase(mode: .standard, isApp: true, canAlias: false, expected: .move),
        OpCase(mode: .standard, isApp: true, canMove: false, canAlias: false, expected: .copy),
        // ⌥: everything is copied, apps too.
        OpCase(mode: .copy, isApp: true, expected: .copy),
        OpCase(mode: .copy, isApp: false, expected: .copy),
        OpCase(mode: .copy, isApp: true, canMove: false, canAlias: false, expected: .copy),
        // ⌘: an explicit move, apps too (a copy when the source offers no move).
        OpCase(mode: .move, isApp: true, expected: .move),
        OpCase(mode: .move, isApp: false, expected: .move),
        OpCase(mode: .move, isApp: true, canMove: false, expected: .copy),
        // ⌘⌥: an alias of everything (a copy when the source allows no answer that leaves its item alone).
        OpCase(mode: .alias, isApp: true, expected: .alias),
        OpCase(mode: .alias, isApp: false, expected: .alias),
        OpCase(mode: .alias, isApp: false, canMove: false, expected: .alias),
        OpCase(mode: .alias, isApp: false, canAlias: false, expected: .copy),
    ]

    @Test("Each item's op follows the keys held, whether it is an app, and what the source allows", arguments: opCases)
    func opRules(_ c: OpCase) {
        #expect(DropIn.op(c.mode, isApp: c.isApp, canMove: c.canMove, canAlias: c.canAlias) == c.expected)
        #expect(DropIn.ops(c.mode, isApp: [c.isApp, c.isApp], canMove: c.canMove, canAlias: c.canAlias)
            == [c.expected, c.expected])
    }

    @Test("The keys: none, ⌥ copies, ⌘ moves, ⌘⌥ makes aliases (Finder's convention)")
    func modes() {
        let table: [(option: Bool, command: Bool, mode: DropMode)] = [
            (false, false, .standard), (true, false, .copy), (false, true, .move), (true, true, .alias),
        ]
        for row in table { #expect(DropMode(option: row.option, command: row.command) == row.mode) }
        #expect(DropIn.ops(.standard, isApp: [true, false, true]) == [.alias, .move, .alias])
        #expect(DropIn.ops(.move, isApp: [true, false]) == [.move, .move])
        #expect(DropIn.ops(.standard, isApp: []) == [])
    }

    struct DragCase: Sendable, CustomStringConvertible {
        var bonks = false
        var ops: [ImportOp]
        var crosses: [Bool]
        var expected: ImportOp?
        var description: String { "bonks:\(bonks) \(ops) crosses:\(crosses) → \(expected.map { "\($0)" } ?? "nil")" }
    }

    static let dragCases: [DragCase] = [
        DragCase(bonks: true, ops: [.alias], crosses: [false], expected: nil),
        DragCase(bonks: true, ops: [.move], crosses: [false], expected: nil),
        DragCase(ops: [.alias], crosses: [false], expected: .alias),
        DragCase(ops: [.alias, .alias], crosses: [true, false], expected: .alias),
        DragCase(ops: [.move], crosses: [false], expected: .move),
        DragCase(ops: [.move], crosses: [true], expected: .copy),
        DragCase(ops: [.move], crosses: [], expected: .copy),
        DragCase(ops: [.copy], crosses: [false], expected: .copy),
        // Aliases beside other items do not change today's answer.
        DragCase(ops: [.alias, .move], crosses: [true, false], expected: .move),
        DragCase(ops: [.alias, .move], crosses: [false, true], expected: .copy),
        DragCase(ops: [.alias, .copy], crosses: [false, false], expected: .copy),
        DragCase(ops: [], crosses: [], expected: .move),
    ]

    @Test("What a drag is told: a link only when every item becomes an alias, else as before", arguments: dragCases)
    func dragOperation(_ c: DragCase) {
        #expect(DropIn.dragOperation(bonks: c.bonks, ops: c.ops, crosses: c.crosses) == c.expected)
    }

    @Test("The old answer still holds for a drop without aliases")
    func oldDragOperation() {
        for (forced, crosses) in [(false, false), (true, false), (false, true), (true, true)] {
            let old = DropIn.dragOperation(bonks: false, forcedCopy: forced, crossesVolumes: crosses)
            let ops: [ImportOp] = [forced ? .copy : .move]
            #expect(DropIn.dragOperation(bonks: false, ops: ops, crosses: [crosses]) == old)
        }
    }

    @Test("An app's alias is named without .app; a folder or document keeps its full name")
    func names() {
        #expect(DropIn.aliasName("Safari.app") == "Safari")
        #expect(DropIn.aliasName("Visual Studio Code.app") == "Visual Studio Code")
        #expect(DropIn.aliasName("Foo.Bar.app") == "Foo.Bar")
        #expect(DropIn.aliasName("Mail.APP") == "Mail")
        #expect(DropIn.aliasName("report.pdf") == "report.pdf")
        #expect(DropIn.aliasName("Photos") == "Photos")
        #expect(DropIn.aliasName(".app") == ".app")
        #expect(DropIn.landingName("Safari.app", op: .alias) == "Safari")
        #expect(DropIn.landingName("Safari.app", op: .move) == "Safari.app")
        #expect(DropIn.landingName("Safari.app", op: .copy) == "Safari.app")
        #expect(DropIn.isAppName("Safari.app") && !DropIn.isAppName("Safari") && !DropIn.isAppName("a.txt"))
    }

    @Test("A drop's headline op: the items' op when they agree, else a copy when any is, else a move")
    func headline() {
        #expect(ImportOp.headline([.alias, .alias]) == .alias)
        #expect(ImportOp.headline([.copy]) == .copy)
        #expect(ImportOp.headline([.alias, .move]) == .move)
        #expect(ImportOp.headline([.alias, .copy, .move]) == .copy)
        #expect(ImportOp.headline([]) == .move)
        let d = DropIn(urls: [URL(fileURLWithPath: "/a/A.app"), URL(fileURLWithPath: "/a/b.txt")], location: .floor(x: 0),
                       ops: [.alias, .move])
        #expect(d.op == .move && d.op(at: 0) == .alias && d.op(at: 1) == .move && d.op(at: 7) == .move)
        #expect(DropIn(urls: [URL(fileURLWithPath: "/a/b.txt")], location: .floor(x: 0), op: .copy).ops == [.copy])
    }

    // MARK: The reducer

    @Test("A drop asks for each item's op; an alias's hint carries its name without .app; desk items only move")
    func reducerDrop() {
        var s = F.mirrored(["a.txt", "Safari"])
        let app = URL(fileURLWithPath: "/Applications/Safari.app")
        let mail = URL(fileURLWithPath: "/Applications/Mail.app")
        let doc = URL(fileURLWithPath: "/elsewhere/new.txt")
        let desk = URL(fileURLWithPath: F.rootPath).appendingPathComponent("a.txt")
        let at = Location.container(.riserRight, order: 0)
        let d = DropIn(urls: [app, doc, desk, mail], location: at, ops: [.alias, .move, .alias, .alias])
        var journal = UndoJournal()
        let effects = Reducer.reduce(&s, journal: &journal, .requestDropIn(d), env)
        #expect(effects.contains(.importFiles([app, doc, mail], ops: [.alias, .move, .alias],
                                              hints: ["Safari": at, "new.txt": at, "Mail": at])))
        #expect(s.hints.map(\.name) == ["Safari", "new.txt", "Mail"])
        #expect(s.hints.map(\.source) == [app.path, doc.path, mail.path])
        // "Safari" is taken on the desk: that hint never claims a file by name; the result places it by identity.
        #expect(s.hints.map(\.matchesName) == [false, true, true])
        #expect(s.tokens.location(of: F.key(1))?.container == .riserRight, "a desk item only moves, whatever the keys")
        #expect(s.violations().isEmpty)

        // The result: the alias landed as "Safari 2" and goes where it was dropped, by identity.
        let landed = FileReport.Placed(source: app.path, name: "Safari 2", key: F.key(40), aliased: true)
        _ = reduce(&s, .fileResult(FileReport(kind: .importItems, count: 1, placed: [landed], undo: FileUndoRef(1))), env)
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("Safari", 2), F.entry("Safari 2", 40)],
                                            at: F.t0 + 1), now: F.t0 + 1)
        #expect(s.tokens.location(of: F.key(40))?.container == .riserRight)
    }

    @Test("A drop-in's label: Make Alias while it runs and after, Drop In beside moves or copies")
    func undoLabels() {
        #expect(FileReport.Kind.importItems.undoLabel(op: .alias) == "Make Alias")
        #expect(FileReport.Kind.importItems.undoLabel(op: .copy) == "Copy In")
        #expect(FileReport.Kind.importItems.undoLabel(op: .move) == "Move In")
        let alias = FileReport.Placed(source: "/a/Safari.app", name: "Safari", aliased: true)
        let moved = FileReport.Placed(source: "/a/b.txt", name: "b.txt")
        let copied = FileReport.Placed(source: "/v/c.txt", name: "c.txt", copied: true)
        func label(_ placed: [FileReport.Placed]) -> String {
            FileReport(kind: .importItems, count: placed.count, placed: placed, undo: FileUndoRef(1)).undoLabel
        }
        #expect(label([alias]) == "Make Alias" && label([alias, alias]) == "Make Alias")
        #expect(label([alias, moved]) == "Drop In" && label([alias, copied]) == "Drop In")
        #expect(label([moved]) == "Move In" && label([copied]) == "Copy In" && label([moved, copied]) == "Drop In")

        // In the journal: the entry takes "Make Alias" when the drop starts, and keeps it when it is in.
        var s = F.mirrored(["z"])
        var j = UndoJournal()
        _ = Reducer.reduce(&s, journal: &j, .fileStarted(FileUndoRef(3), .importItems, op: .alias), env)
        #expect(j.undoLabel == "Make Alias")
        let r = FileReport(kind: .importItems, count: 1, placed: [alias], undo: FileUndoRef(3), ticket: FileUndoRef(3))
        _ = Reducer.reduce(&s, journal: &j, .fileResult(r), env)
        #expect(j.undoLabel == "Make Alias")
        #expect(L10n.tr("Undo Make Alias", .ko) == "실행 취소: 별칭 만들기")
    }

    @Test("Toasts: an alias that landed unverified says so; done toasts come only when nothing was refused")
    func toasts() {
        #expect(FileReport(kind: .importItems, count: 1, problems: [.aliasUnverified]).toast == .aliasNoUndo)
        #expect(FileReport(kind: .importItems, count: 3, problems: [.gone, .aliasUnverified]).toast == .aliasNoUndo)
        #expect(FileReport(kind: .importItems, count: 2, problems: [.landedUnverified, .aliasUnverified]).toast
            == .copiedNoUndo)
        #expect(FileReport(kind: .importItems, count: 1, done: .aliasMade).toast == .aliasMade)
        #expect(FileReport(kind: .importItems, count: 2, problems: [.gone], done: .aliasMade).toast == .someGone)
        #expect(FileReport(kind: .undo, count: 1, undoOf: .importItems, done: .undidAlias).toast == .undidAlias)
    }

    @Test("The alias strings are in the table, in natural Korean")
    func strings() {
        let pairs: [(String, String)] = [
            ("Make Alias", "별칭 만들기"),
            ("Made an alias; the app stayed put.", "별칭을 만들었어요. 앱은 그대로예요."),
            ("Made aliases; the apps stayed put.", "별칭을 만들었어요. 앱은 모두 그대로예요."),
            ("Made an alias; the original stayed put.", "별칭을 만들었어요. 원본은 그대로예요."),
            ("Made aliases; the originals stayed put.", "별칭을 만들었어요. 원본은 모두 그대로예요."),
            ("The app became an alias; the rest came in.", "앱은 별칭만 만들고 나머지는 가져왔어요."),
            ("Apps became aliases; the rest came in.", "앱은 별칭만 만들고 나머지는 가져왔어요."),
            ("Made an alias, but it can't be undone.", "별칭을 만들었지만 실행 취소할 수 없어요."),
            ("The alias went to the Trash.", "별칭을 휴지통으로 옮겼어요."),
            ("The aliases went to the Trash.", "별칭을 모두 휴지통으로 옮겼어요."),
            ("Undone; the alias went to the Trash.", "되돌리고 별칭은 휴지통으로 옮겼어요."),
            ("Undone; the aliases went to the Trash.", "되돌리고 별칭은 모두 휴지통으로 옮겼어요."),
            ("Alias", "별칭"),
        ]
        for (en, ko) in pairs {
            #expect(L10n.knows(en), "\(en)")
            #expect(L10n.tr(en, .ko) == ko, "\(en)")
            #expect(!ko.contains("휴지통") || en.contains("Trash"), "the system Trash is 휴지통, never 쓰레기통")
        }
        #expect(L10n.text(.kindAlias, .en) == "Alias" && L10n.text(.undoMakeAlias, .ko) == "별칭 만들기")
    }

    // MARK: Demo scripts

    @Test("Demo scripts: a sourceApp step names an app; a dropIn step takes cmd and opt")
    func demoScript() throws {
        let decoder = JSONDecoder()
        let app = try decoder.decode(DemoFS.self, from: Data(#"{"sourceApp": "Calculator.app"}"#.utf8))
        #expect(app == .sourceApp("Calculator.app") && app.parts == ["sourceApp", "Calculator.app"] && app.isValid)
        let back = try decoder.decode(DemoFS.self, from: JSONEncoder().encode(app))
        #expect(back == app)
        #expect(throws: (any Error).self) { try decoder.decode(DemoFS.self, from: Data(#"{"sourceApp": "notes.txt"}"#.utf8)) }
        #expect(!DemoFS.sourceApp("../Evil.app").isValid)
        let drop = try decoder.decode(DemoDropIn.self, from: Data(#"{"files": ["Calculator.app"], "at": "cell:9,4", "mods": ["cmd", "opt"]}"#.utf8))
        #expect(drop.mods == ["cmd", "opt"] && drop.files == ["Calculator.app"])
    }
}

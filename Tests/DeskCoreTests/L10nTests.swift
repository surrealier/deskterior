import Foundation
import Testing
@testable import DeskCore

/// The English/Korean string table (M12): complete, consistent, and able to translate what the menus, toasts,
/// monitor cards and undo labels produce in English.
@Suite("L10n")
struct L10nTests {
    @Test("Every key has English and Korean text with the same placeholders")
    func complete() {
        for key in L10nKey.allCases {
            #expect(!key.en.isEmpty && key.en != key.rawValue, "\(key) has no English")
            #expect(!key.ko.isEmpty && key.ko != key.rawValue, "\(key) has no Korean")
            #expect(L10n.placeholders(key.en) == L10n.placeholders(key.ko), "\(key) placeholders differ")
            #expect(!key.ko.unicodeScalars.contains { $0.properties.generalCategory == .control }, "\(key)")
        }
    }

    @Test("Keys that share English text agree in Korean (menus translate by their English)")
    func consistent() {
        let groups = Dictionary(grouping: L10nKey.allCases, by: \.en)
        for (en, keys) in groups where keys.count > 1 {
            #expect(Set(keys.map(\.ko)).count == 1, "\(en): \(keys)")
        }
    }

    @Test("Most Korean text is actually Korean")
    func translated() {
        // Brand names, input names and language names may stay as they are.
        let same: Set<L10nKey> = [.hdmi, .hdmiCount, .av, .languageEnglish, .languageKorean]
        for key in L10nKey.allCases where !same.contains(key) {
            #expect(key.ko != key.en, "\(key) is not translated")
        }
    }

    @Test("tr: exact matches, templates, nested undo labels, file names kept, unknown text unchanged")
    func translate() {
        #expect(L10n.tr("Open", .ko) == "열기")
        #expect(L10n.tr("Open", .en) == "Open")
        #expect(L10n.tr("Empty Wastebasket… (3)", .ko) == "쓰레기통 비우기… (3)")
        #expect(L10n.tr("HDMI 2 (New)", .ko) == "HDMI 2 (새 입력)")
        #expect(L10n.tr("HDMI 3 · 12", .ko) == "HDMI 3 · 12")
        #expect(L10n.tr("Undo Move", .ko) == "실행 취소: 이동")
        #expect(L10n.tr("Undo Move 3 Items", .ko) == "실행 취소: 항목 3개 이동")
        #expect(L10n.tr("Redo Take Everything Out", .ko) == "실행 복귀: 모든 파일 꺼내기")
        // A file name inside a title is not translated, even when it reads like a menu word.
        #expect(L10n.tr("Quick Look “Open”", .ko) == "“Open” 훑어보기")
        #expect(L10n.tr("Quick Look “보고서.pdf”", .ko) == "“보고서.pdf” 훑어보기")
        #expect(L10n.tr("12 More…", .ko) == "12개 더…")
        #expect(L10n.tr("no such string", .ko) == "no such string")
        #expect(L10n.format(.version, ["0.1.0"], .ko) == "버전 0.1.0")
        #expect(L10n.format(.listMore, [7], .en) == "7 More…")
    }

    @Test("The language setting follows the first of the system's preferred languages that the app speaks")
    func resolve() {
        #expect(LanguageSetting.system.resolved(preferred: ["ko-KR", "en-US"]) == .ko)
        #expect(LanguageSetting.system.resolved(preferred: ["en-US", "ko-KR"]) == .en)
        #expect(LanguageSetting.system.resolved(preferred: ["ja-JP", "ko-KR", "en-US"]) == .ko)
        #expect(LanguageSetting.system.resolved(preferred: ["ja", "zh-Hans", "en-GB", "ko"]) == .en)
        #expect(LanguageSetting.system.resolved(preferred: ["ja", "fr"]) == .en)
        #expect(LanguageSetting.system.resolved(preferred: ["kok-IN", "ko"]) == .ko, "Konkani is not Korean")
        #expect(LanguageSetting.system.resolved(preferred: []) == .en)
        #expect(LanguageSetting.en.resolved(preferred: ["ko"]) == .en)
        #expect(LanguageSetting.ko.resolved(preferred: ["en"]) == .ko)
    }

    @Test("Every title the desk, status, token, monitor and container menus show can be translated")
    func menusCovered() {
        var s = ModelFixture.mirrored(["a.txt", "b.pdf", "c.png"])
        let keys = s.tokens.sortedKeys
        var titles: Set<String> = []
        func collect(_ spec: MenuSpec) {
            for id in spec.ids {
                guard let item = spec.item(id), !item.isSeparator else { continue }
                // List Contents shows file names.
                if id.hasPrefix("list."), id != "list.more" { continue }
                titles.insert(item.title)
            }
        }
        for paused in [false, true] {
            collect(MenuSpec.desk(s, MenuSpec.Context(paused: paused, undo: "Move 2 Items", redo: "Clean Up")))
            collect(MenuSpec.status(s, MenuSpec.Context(paused: paused)))
        }
        collect(MenuSpec.token([keys[0]], s))
        collect(MenuSpec.token(keys, s))
        collect(MenuSpec.monitor(s))
        s.monitor.power = .off
        collect(MenuSpec.monitor(s))
        s.monitor.power = .on
        for id in ContainerID.allCases {
            collect(MenuSpec.container(id, s))
        }
        _ = s.tokens.move(keys[1], to: .container(.wastebasket, order: 0))
        _ = s.tokens.move(keys[2], to: .container(.riserLeft, order: 0))
        collect(MenuSpec.desk(s))
        collect(MenuSpec.token([keys[2]], s))
        for id in ContainerID.allCases {
            collect(MenuSpec.container(id, s))
        }
        // The desk mat's menu (List Items Under Mat shows file names) and the drive hub's (drive names are kept).
        var mat = MenuSpec.MatInfo()
        mat.folded = true
        mat.under = [keys[0]]
        let matMenu = MenuSpec.mat(s, mat)
        for id in matMenu.ids where !id.hasPrefix("under.") {
            if let item = matMenu.item(id), !item.isSeparator { titles.insert(item.title) }
        }
        let stick = VolumeEntry(id: "U", name: "Stick", path: "/Volumes/Stick", kind: .removable, isEjectable: true)
        for id in MenuSpec.drive(stick).ids {
            if let item = MenuSpec.drive(stick).item(id), !item.isSeparator { titles.insert(item.title) }
        }
        for t in UndoJournal.l10nCoverageLabels { titles.insert("Undo \(t)") }
        // File entries' labels (`FileReport`).
        for t in ["Move to Trash", "Empty Wastebasket", "Move In", "Copy In", "Drop In"] { titles.insert("Undo \(t)") }
        let missing = titles.filter { !L10n.knows($0) }.sorted()
        #expect(missing.isEmpty, "untranslated menu titles: \(missing)")
    }

    @Test("Dates follow the app's language: the Mac's own locale when it speaks it, else the language alone")
    func dateLocale() {
        let korean = Locale(identifier: "ko_KR"), british = Locale(identifier: "en_GB")
        #expect(Language.ko.dateLocale(current: korean) == korean)
        #expect(Language.en.dateLocale(current: korean).identifier == "en")
        #expect(Language.en.dateLocale(current: british) == british, "an English Mac keeps its region's date order")
        #expect(Language.ko.dateLocale(current: british).identifier == "ko")
        let day = Date(timeIntervalSince1970: 1_792_000_000)  // 2026-10-14 UTC
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Language.en.dateLocale(current: korean),
                                     calendar: utc, timeZone: utc.timeZone)
        #expect(!day.formatted(style).contains("년"), "\(day.formatted(style))")
    }

    @Test("Find Item's location labels and kind names are in the table")
    func inventoryCovered() {
        var labels: [String] = [
            InventoryQuery.label(for: .screen(page: 0, col: 0, row: 0)),
            InventoryQuery.label(for: .screen(page: 11, col: 2, row: 3)),
            InventoryQuery.label(for: .desk(pile: PileID("p1"), order: 0)),
            InventoryQuery.label(for: .desk(pile: PileID("p1"), order: 0), covered: true),
            InventoryQuery.label(for: .floor(x: 3)), InventoryQuery.label(for: .carried),
        ]
        labels += ContainerID.allCases.map { InventoryQuery.label(for: $0) }
        // TokenArt.kindName (DeskScene), which the window shows in its Kind column.
        let kinds = [
            "Folder", "Package", "Document", "Plain text", "PDF document", "Image", "Movie", "Audio", "Archive",
            "Application", "Source code", "Disk image", "Screenshot",
        ]
        for e in labels + kinds {
            #expect(L10n.knows(e), "\(e)")
            #expect(L10n.tr(e, .ko) != e, "\(e) is not translated")
        }
        #expect(L10n.tr("Monitor · HDMI 12", .ko) == "모니터 · HDMI 12")
        #expect(L10n.tr("Desk", .ko) == "책상" && L10n.tr("Under mat", .ko) == "매트 밑")
        #expect(L10n.format(.itemCount, [3, 500], .en) == "3 of 500")
    }

    @Test("The credits say what §6 says: independent, inspired by the prototype, not affiliated with him or GitHub")
    func credits() {
        let en = L10nKey.aboutInspired.en + " " + L10nKey.aboutIndependent.en
        #expect(en.hasPrefix("Deskterior is an independent project inspired by Terkel Gjervig's"))
        #expect(en.contains("not affiliated with or endorsed by him or GitHub"))
        #expect(en.contains("uses none of the prototype's code, name, art or branding"))
        #expect(L10nKey.aboutIndependent.ko.contains("GitHub"))
    }

    @Test("Toasts and monitor cards are in the table")
    func scenesCovered() {
        let english = [
            // ToastKey.english (DeskScene)
            "That's full.", "No access to the Desktop folder.", "Not available yet.", "Use Finder to copy to drives.",
            "Widgets cover part of the desk.",
            // File actions (M11)
            "It changed on disk. Nothing was done.", "That file is gone already.", "macOS did not allow that.",
            "Use Finder's Put Back.", "Some items stayed where they were.", "That did not work. Nothing changed.",
            "Can't drop the Desktop or a folder holding it.", "The drive could not be ejected.", "Too many items with that name.",
            "Some changed on disk, so they stayed.", "Some were gone already.", "macOS kept some items where they were.",
            "Drag files from the drive, not the drive.", "The desk isn't connected to its folder.",
            "Nothing to undo there: those items are gone.", "Still working on that.", "Stopping the copy…",
            "Put back from the Trash.", "Sent back where they came from.", "Copies moved to the Trash.",
            "Sent back; copies moved to the Trash.", "macOS would not let it go back.",
            "Copying 1 item… ⌘Z stops", "Copying 37 items… ⌘Z stops",
            // ScreenCard (DeskScene)
            "PRESS", "TO CONNECT", "DESKTOP", "Shows your Desktop files here.", "CONNECTING…", "Can't read the Desktop folder.",
            "Allow access, or choose it:", "Open Settings", "Choose Folder…", "DESKTOP HIDDEN", "Finder hides desktop items.",
            "Show them on the desk anyway?", "Show", "Keep Hidden",
        ]
        for e in english { #expect(L10n.knows(e), "\(e)") }
    }
}

extension UndoJournal {
    /// The labels the journal records (L10n coverage).
    static var l10nCoverageLabels: [String] {
        let k = TokenKey(volume: "v", inode: 1)
        let actions: [DeskAction] = [
            .move([k], to: .floor(x: 0)), .move([k, k], to: .floor(x: 0)), .takeAllOut(.riserLeft), .takeEverythingOut,
            .cleanUp(.name), .clearDesk,
        ]
        return actions.compactMap { label(for: $0) }
    }
}

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

    @Test("The language setting follows the system's first preferred language")
    func resolve() {
        #expect(LanguageSetting.system.resolved(preferred: ["ko-KR", "en-US"]) == .ko)
        #expect(LanguageSetting.system.resolved(preferred: ["en-US", "ko-KR"]) == .en)
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
        for t in UndoJournal.l10nCoverageLabels { titles.insert("Undo \(t)") }
        let missing = titles.filter { !L10n.knows($0) }.sorted()
        #expect(missing.isEmpty, "untranslated menu titles: \(missing)")
    }

    @Test("Toasts and monitor cards are in the table")
    func scenesCovered() {
        let english = [
            // ToastKey.english (DeskScene)
            "That's full.", "No access to the Desktop folder.", "Not available yet.", "Use Finder to copy to drives.",
            "Widgets cover part of the desk.",
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

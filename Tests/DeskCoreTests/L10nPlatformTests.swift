import Foundation
import Testing
@testable import DeskCore

/// Windows wording (docs/WINDOWS.md, WP1). The tests pass the platform explicitly and never set `L10n.platform`,
/// which other suites running in parallel read.
@Suite("L10n on Windows")
struct L10nPlatformTests {
    /// Words that name a part of macOS; a key whose text has one needs Windows wording.
    static let macWords = try! NSRegularExpression(
        pattern: "⌘|⌥|⌃|Finder|Trash|\\bmacOS\\b|\\bMac\\b|Quick Look|iCloud|[Aa]lias|별칭|훑어보기|System Settings|Login Items"
    )
    /// Shown only by the Mac app (App Translocation).
    static let macOnly: Set<L10nKey> = [.translocationTitle, .translocationBody, .loginTranslocated]

    static func namesMac(_ s: String) -> Bool {
        macWords.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    @Test("Every key that names a Mac part has Windows wording")
    func coverage() {
        for key in L10nKey.allCases where !Self.macOnly.contains(key) && (Self.namesMac(key.en) || Self.namesMac(key.ko)) {
            #expect(key.hasWindowsText, "\(key) needs Windows wording: \(key.en)")
        }
    }

    @Test("Windows wording names no Mac part and keeps the placeholders")
    func wording() {
        for key in L10nKey.allCases where key.hasWindowsText {
            for l in Language.allCases {
                let w = key.string(l, platform: .windows)
                #expect(!Self.namesMac(w), "\(key) \(l): \(w)")
                #expect(L10n.placeholders(w) == L10n.placeholders(key.string(l, platform: .mac)), "\(key) \(l)")
            }
        }
    }

    @Test("The Mac reads exactly as before")
    func macUnchanged() {
        for key in L10nKey.allCases {
            #expect(key.string(.en, platform: .mac) == key.en)
            #expect(key.string(.ko, platform: .mac) == key.ko)
        }
        #expect(L10n.tr("Show in Finder", .en, platform: .mac) == "Show in Finder")
        #expect(L10n.text(.showInFinder, .ko, platform: .mac) == "Finder에서 보기")
    }

    @Test("text, format and tr give the Windows wording, in English too")
    func windowsLookups() {
        let w = Platform.windows
        #expect(L10n.text(.showInFinder, .en, platform: w) == "Show in File Explorer")
        #expect(L10n.text(.showInFinder, .ko, platform: w) == "파일 탐색기에서 보기")
        #expect(L10n.format(.sheetEmptyMany, [3], .en, platform: w) == "Move the 3 items in the wastebasket to the Recycle Bin?")
        // English built by MenuSpec and toasts goes through the table on Windows.
        #expect(L10n.tr("Show in Finder", .en, platform: w) == "Show in File Explorer")
        #expect(L10n.tr("Quick Look “notes.txt”", .en, platform: w) == "Preview “notes.txt”")
        #expect(L10n.tr("Quick Look “notes.txt”", .ko, platform: w) == "“notes.txt” 미리 보기")
        #expect(L10n.tr("Undo Make Alias", .en, platform: w) == "Undo Create Shortcut")
        #expect(L10n.tr("Monitor Power", .en, platform: w) == "Monitor Power")
        #expect(L10n.tr("Something the table does not know", .en, platform: w) == "Something the table does not know")
    }

    @Test("Peek Desk on Windows is Ctrl+Alt+Shift+D")
    func hotkey() {
        let b = HotKeyBinding.peekDeskWindows
        #expect(b.keyCode == 0x44)
        #expect(b.modifiers == HotKeyBinding.control | HotKeyBinding.option | HotKeyBinding.shift)
    }
}

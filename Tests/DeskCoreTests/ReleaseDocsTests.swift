import Foundation
import Testing

/// The release's packaging template and documents agree with each other (M13; DESIGN §6, §11, Errata 24).
@Suite("Release docs and packaging")
struct ReleaseDocsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..")
        .standardizedFileURL

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("Info.plist: an agent app for macOS 14 with build-time placeholders")
    func infoPlist() throws {
        let info = try Self.plist("Packaging/Info.plist")
        #expect(info["LSUIElement"] as? Bool == true)
        #expect(info["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(try Self.text("Package.swift").contains(".macOS(.v14)"))
        #expect(info["CFBundleIdentifier"] as? String == "__BUNDLE_ID__")
        #expect(info["CFBundleShortVersionString"] as? String == "__VERSION__")
        #expect(info["CFBundleVersion"] as? String == "__BUILD__")
        #expect((info["NSHumanReadableCopyright"] as? String)?.contains("__COPYRIGHT_OWNER__") == true)
        #expect(info["CFBundleLocalizations"] as? [String] == ["en", "ko"])
    }

    @Test("Every purpose string is in both InfoPlist.strings, and the Korean one is translated")
    func usageStrings() throws {
        let info = try Self.plist("Packaging/Info.plist")
        let keys = info.keys.filter { $0.hasSuffix("UsageDescription") }.sorted()
        #expect(keys.contains("NSDesktopFolderUsageDescription"))
        let en = try Self.plist("Packaging/en.lproj/InfoPlist.strings")
        let ko = try Self.plist("Packaging/ko.lproj/InfoPlist.strings")
        for key in keys {
            #expect(en[key] as? String == info[key] as? String, "\(key) in en.lproj")
            let k = try #require(ko[key] as? String, "\(key) in ko.lproj")
            #expect(k != info[key] as? String && k.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) })
        }
        #expect(Set(en.keys).isSubset(of: Set(keys)) && Set(ko.keys).isSubset(of: Set(keys)))
    }

    @Test("Both READMEs show the same media, link releases relatively and credit the inspiration")
    func readmes() throws {
        let en = try Self.text("README.md"), ko = try Self.text("README.ko.md")
        let pattern = try NSRegularExpression(pattern: #"\(docs/media/([A-Za-z0-9.-]+)\)"#)
        func media(_ s: String) -> Set<String> {
            Set(pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Range($0.range(at: 1), in: s).map { String(s[$0]) }
            })
        }
        #expect(media(en) == media(ko))
        // scripts/make-gif.sh writes these.
        #expect(media(en) == ["hero.gif", "desk.png", "mat-peel.png", "hiding.png", "lamp-only.png"])
        for file in media(en) {
            #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("docs/media/\(file)").path), "\(file)")
        }
        for doc in [en, ko] {
            #expect(doc.contains("](../../releases/latest)"))
            #expect(doc.contains("README.md") || doc.contains("README.ko.md"))
            #expect(doc.contains("Terkel Gjervig") && doc.contains("Desktop Cleaning"))
            #expect(doc.contains("Galmuri") || doc.contains("갈무리"))
            #expect(doc.contains("AdamCYounis"))
        }
        // Never the name of the original's product line.
        for path in ["README.md", "README.ko.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md", ".github/release-notes.md"] {
            #expect(!(try Self.text(path)).contains("Rugs"), "\(path)")
        }
        #expect(try Self.text("CHANGELOG.md").contains("## [0.1.0]"))
    }
}

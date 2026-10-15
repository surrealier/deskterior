import Foundation
import Testing
@testable import DeskCore

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

    /// The `<img src="docs/media/…" width="…">` tags of a README: file name → width.
    static func images(_ s: String) throws -> [String: Int] {
        let pattern = try NSRegularExpression(pattern: #"<img src="docs/media/([A-Za-z0-9.-]+)" width="([0-9]+)""#)
        var found: [String: Int] = [:]
        for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let file = Range(m.range(at: 1), in: s), let width = Range(m.range(at: 2), in: s) else { continue }
            found[String(s[file])] = Int(s[width])
        }
        return found
    }

    /// A PNG's or GIF's width in pixels, from its header.
    static func pixelWidth(_ file: String) throws -> Int {
        let b = [UInt8](try Data(contentsOf: root.appendingPathComponent("docs/media/\(file)")).prefix(24))
        if file.hasSuffix(".gif") { return Int(b[6]) | Int(b[7]) << 8 }
        return b[16...19].reduce(0) { $0 << 8 | Int($1) }
    }

    /// The lines of each ```sh block in a Markdown document.
    static func shellBlocks(_ s: String) -> [[String]] {
        var blocks: [[String]] = [], current: [String]?
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if current == nil, t == "```sh" {
                current = []
            } else if current != nil, t == "```" {
                blocks.append(current ?? [])
                current = nil
            } else {
                current?.append(t)
            }
        }
        return blocks
    }

    /// The README in every language, English first.
    static let readmeFiles = ["README.md", "README.ko.md", "README.zh-CN.md", "README.ja.md", "README.es.md"]

    @Test("Every README shows the same media, offers every language, links releases relatively and credits the inspiration")
    func readmes() throws {
        let docs = try Self.readmeFiles.map { try Self.text($0) }
        let en = docs[0], ko = docs[1]
        let media = try Self.images(en)
        for (path, doc) in zip(Self.readmeFiles, docs) {
            #expect(try Self.images(doc) == media, "\(path) shows other media")
        }
        // scripts/make-gif.sh writes the stills; the hero and the feature GIFs are real screen recordings.
        let stills: Set<String> = ["hero.gif", "desk.png", "mat-peel.png", "hiding.png", "lamp-only.png"]
        #expect(stills.isSubset(of: Set(media.keys)))
        #expect(media.keys.filter { $0.hasPrefix("feat-") }.count >= 10, "the feature gallery")
        for (file, width) in media {
            // Half the pixels: each art pixel covers whole screen pixels on 1x and 2x screens (no resampling blur).
            #expect(try Self.pixelWidth(file) == 2 * width, "\(file)")
        }
        func flat(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let names = ["English", "한국어", "简体中文", "日本語", "Español"]
        for (i, (path, doc)) in zip(Self.readmeFiles, docs).enumerated() {
            #expect(!doc.contains("](docs/media/"), "\(path)")
            #expect(doc.contains("](../../releases/latest)"), "\(path)")
            #expect(doc.contains("Galmuri") || doc.contains("갈무리"), "\(path)")
            #expect(doc.contains("AdamCYounis"), "\(path)")
            // The language selector: this language in bold, every other one linked.
            let selector = doc.components(separatedBy: "\n").first ?? ""
            for (j, (other, name)) in zip(Self.readmeFiles, names).enumerated() {
                #expect(selector.contains(i == j ? "**\(name)**" : "[\(name)](\(other))"), "\(path): \(name)")
            }
            // Every edition credits the original and its author.
            #expect(doc.contains("Terkel Gjervig") && doc.contains("*Desktop Cleaning*") && doc.contains("desktop.cleaning"),
                    "\(path) credits the inspiration")
        }
        // The credit as DESIGN §6 item 10, the About window and THIRD_PARTY_NOTICES word it.
        #expect(flat(en).contains("inspired by Terkel Gjervig's desktop-rug prototype *Desktop Cleaning* (desktop.cleaning)"))
        #expect(flat(ko).contains("Terkel Gjervig의 데스크톱 러그 프로토타입 *Desktop Cleaning*(desktop.cleaning)"))
        #expect(L10nKey.aboutInspired.ko.contains("데스크톱 러그 프로토타입"))
        // The mat's list is a submenu, named as the menu names it.
        #expect(en.contains("\(L10nKey.listItemsUnderMat.en) ▸") && ko.contains("\(L10nKey.listItemsUnderMat.ko)’ ▸"))
        // Never the name of the original's product line.
        for path in Self.readmeFiles + ["CHANGELOG.md", "THIRD_PARTY_NOTICES.md", ".github/release-notes.md"] {
            #expect(!(try Self.text(path)).contains("Rugs"), "\(path)")
        }
        #expect(try Self.text("CHANGELOG.md").contains("## [0.1.0]"))
        // Release notes are not a page of their own: in-page anchors there go nowhere.
        #expect(!(try Self.text(".github/release-notes.md")).contains("](#"))
    }

    @Test("A release version has a dated CHANGELOG entry (the release workflow checks the tag the same way)")
    func version() throws {
        let log = try Self.text("CHANGELOG.md")
        if !DeskCore.version.contains("-") {
            let heading = try NSRegularExpression(pattern: #"(?m)^## \[\#(NSRegularExpression.escapedPattern(for: DeskCore.version))\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$"#)
            #expect(heading.firstMatch(in: log, range: NSRange(log.startIndex..., in: log)) != nil, "\(DeskCore.version)")
        }
        #expect(!log.contains("Unreleased]") || DeskCore.version.contains("-"))
    }

    @Test("Pasted shell blocks have no # comments (interactive zsh passes them on as arguments)")
    func noShellComments() throws {
        for path in Self.readmeFiles + [".github/release-notes.md", "docs/SIGNING.md", "docs/SPIKES.md"] {
            for line in Self.shellBlocks(try Self.text(path)).joined() {
                #expect(!line.hasPrefix("#") && !line.contains(" #"), "\(path): \(line)")
            }
        }
    }

    @Test("The owner's checklist reads Finder's keys so an unset key prints the same line before and after")
    func finderReads() throws {
        let reads = Self.shellBlocks(try Self.text("docs/SPIKES.md")).joined().filter { $0.contains("defaults read com.apple.") }
        #expect(reads.count == 2, "a before and an after line")
        for line in reads {
            // `defaults` stamps the time and its pid on "does not exist": captured, the diff could never pass.
            #expect(!line.contains("2>&1") && line.components(separatedBy: "2>/dev/null || echo unset").count == 3, "\(line)")
        }
    }

    @Test("The uninstall block removes nothing unless it read Deskterior's own bundle id")
    func uninstallGuard() throws {
        var blocks: [[String]] = []
        for path in Self.readmeFiles {
            let block = try #require(Self.shellBlocks(try Self.text(path)).first { $0.contains { $0.hasPrefix("rm -rf") } })
            blocks.append(block)
            let read = try #require(block.firstIndex { $0.contains("defaults read /Applications/Deskterior.app") })
            #expect(block[read].hasSuffix("&&"), "\(path): a failed read must stop the block")
            let guardLine = try #require(block.firstIndex { $0.hasPrefix("case \"$ID\" in ") })
            #expect(guardLine == read + 1)
            #expect(block[guardLine] == #"case "$ID" in io.github.*.deskterior | io.github.deskterior.dev)"#)
            let end = try #require(block.lastIndex(of: "esac"))
            for (i, line) in block.enumerated() where line.contains("$ID") && i != read && i != guardLine {
                #expect(i > guardLine && i < end, "\(path): \(line) runs outside the guard")
            }
            #expect(block.filter { $0.contains("$ID") }.count == 4)
        }
        #expect(blocks.allSatisfy { $0 == blocks[0] }, "the uninstall block is the same in every README")
    }

    @Test("Bold text in the docs closes (CommonMark's flanking rules), Korean particles included")
    func boldFlanking() throws {
        func punctuation(_ c: Character?) -> Bool { c.map { $0.isPunctuation || $0.isSymbol } ?? false }
        func alphanumeric(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        for path in Self.readmeFiles + ["CHANGELOG.md", ".github/release-notes.md", "docs/SIGNING.md"] {
            // Paragraphs outside code fences, code spans blanked.
            var paragraphs: [String] = [], current = "", fenced = false
            for line in try Self.text(path).components(separatedBy: "\n") {
                if line.hasPrefix("```") { fenced.toggle(); continue }
                if fenced { continue }
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    paragraphs.append(current)
                    current = ""
                } else {
                    current += " " + line.replacingOccurrences(of: #"`[^`]*`"#, with: "x", options: .regularExpression)
                }
            }
            paragraphs.append(current)
            for p in paragraphs {
                let chars = Array(p)
                var runs: [Int] = []
                var i = 0
                while i + 1 < chars.count {
                    if chars[i] == "*", chars[i + 1] == "*" { runs.append(i); i += 2 } else { i += 1 }
                }
                #expect(runs.count % 2 == 0, "\(path): unpaired ** in \(p.prefix(60))")
                for (k, at) in runs.enumerated() {
                    let before = at > 0 ? chars[at - 1] : nil, after = at + 2 < chars.count ? chars[at + 2] : nil
                    let opens = k % 2 == 0
                    let broken = opens ? alphanumeric(before) && punctuation(after) : punctuation(before) && alphanumeric(after)
                    #expect(!broken, "\(path): ** at \(String(chars[max(0, at - 8)..<min(chars.count, at + 10)]))")
                }
            }
        }
    }
}

import DeskCore
import Foundation
import Testing
@testable import DeskFiles

@Suite("DesktopScanner")
struct ScannerTests {
    @Test("Fetches the §3.1 resource keys")
    func resourceKeys() {
        let keys = Set(DesktopScanner.resourceKeys)
        let required: [URLResourceKey] = [
            .fileIdentifierKey, .volumeUUIDStringKey, .isDirectoryKey, .isPackageKey, .localizedNameKey,
            .hasHiddenExtensionKey, .contentTypeKey, .addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey,
            .tagNamesKey, .isAliasFileKey, .ubiquitousItemDownloadingStatusKey, .creationDateKey,
        ]
        #expect(keys == Set(required))
    }

    @Test("Top level only, hidden items skipped, identity and metadata filled in")
    func scansTopLevel() throws {
        let d = try TempDesk()
        try d.write("notes.txt", "hello")
        let nfd = "보고서 final.pdf".decomposedStringWithCanonicalMapping
        try d.write(nfd, "%PDF-1.4")
        try d.write("Screenshot 2026-10-12 at 10.15.32.png", "png")
        try d.write("archive.zip", "zip")
        try d.mkdir("Projects")
        try d.write("Projects/inner.txt", "deep")
        try d.mkdir("Notes.rtfd")
        try d.write("Notes.rtfd/TXT.rtf", "{\\rtf1}")
        try d.write(".hidden", "dot")
        try d.write("flagged.txt", "hidden flag")
        #expect(chflags(d.url("flagged.txt").path, UInt32(UF_HIDDEN)) == 0)
        try FileManager.default.createSymbolicLink(at: d.url("link"), withDestinationURL: d.url("Projects"))
        try (d.url("notes.txt") as NSURL).setResourceValue(["Red", "Work"], forKey: .tagNamesKey)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snap = try DesktopScanner(root: d.root).scan(now: now)
        #expect(snap.scannedAt == now)
        #expect(snap.rootPath == DesktopLocator.canonicalPath(d.root))
        #expect(!snap.rootVolume.isEmpty)

        let byName = Dictionary(uniqueKeysWithValues: snap.entries.map { ($0.meta.name, $0) })
        #expect(Set(byName.keys) == [
            "notes.txt", nfd, "Screenshot 2026-10-12 at 10.15.32.png", "archive.zip", "Projects", "Notes.rtfd", "link",
        ])
        #expect(snap.entries.map(\.meta.name) == snap.entries.map(\.meta.name).sorted())

        let notes = try #require(byName["notes.txt"])
        #expect(notes.key == TokenKey(volume: snap.rootVolume, inode: d.inode("notes.txt")))
        #expect(notes.meta.kind == .text && notes.meta.size == 5)
        #expect(notes.meta.tags == ["Red", "Work"])
        #expect(notes.meta.added != nil && notes.meta.modified != nil && notes.meta.created != nil)
        #expect(!snap.continuous, "a plain scan cannot vouch for when its changes happened")
        // Dates are whole milliseconds, exactly what desk.json stores.
        let created = try #require(notes.meta.created)
        #expect((created.timeIntervalSince1970 * 1000).rounded() / 1000 == created.timeIntervalSince1970)
        #expect(!notes.meta.isDataless && !notes.meta.isPackage && !notes.meta.isAlias)

        let pdf = try #require(byName[nfd])
        #expect(Array(pdf.meta.name.unicodeScalars) == Array(nfd.unicodeScalars))
        #expect(Array(pdf.meta.displayName.unicodeScalars) == Array("보고서 final.pdf".precomposedStringWithCanonicalMapping.unicodeScalars))
        #expect(pdf.meta.kind == .pdf)

        #expect(byName["Screenshot 2026-10-12 at 10.15.32.png"]?.meta.kind == .screenshot)
        #expect(byName["archive.zip"]?.meta.kind == .zip)
        #expect(byName["Projects"]?.meta.kind == .folder)
        let rtfd = try #require(byName["Notes.rtfd"])
        #expect(rtfd.meta.isPackage && rtfd.meta.kind == .doc)
        #expect(byName["link"]?.meta.isAlias == true)
    }

    @Test("Scanning reads nothing it should not: files are byte-for-byte unchanged")
    func readOnly() throws {
        let d = try TempDesk()
        let file = try d.write("keep.txt", "unchanged")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        _ = try DesktopScanner(root: d.root).scan()
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(try Data(contentsOf: file) == Data("unchanged".utf8))
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.root.path) == ["keep.txt"])
    }

    @Test("Missing, non-folder and unreadable roots fail instead of looking empty")
    func failures() throws {
        let d = try TempDesk()
        #expect(throws: DesktopScanner.Failure.missing(d.url("nope").path)) { try DesktopScanner(root: d.url("nope")).scan() }
        let file = try d.write("file.txt")
        #expect(throws: DesktopScanner.Failure.notADirectory(file.path)) { try DesktopScanner(root: file).scan() }
        let locked = try d.mkdir("locked")
        try d.write("locked/secret.txt")
        #expect(chmod(locked.path, 0o000) == 0)
        defer { chmod(locked.path, 0o755) }
        #expect(throws: DesktopScanner.Failure.accessDenied(locked.standardizedFileURL.path)) {
            try DesktopScanner(root: locked).scan()
        }
    }

    @Test("Background scans complete on the given queue")
    func asyncScan() async throws {
        let d = try TempDesk()
        try d.write("a.txt")
        let result = await withCheckedContinuation { (c: CheckedContinuation<Result<DesktopSnapshot, DesktopScanner.Failure>, Never>) in
            DesktopScanner(root: d.root).scan(on: .global()) { c.resume(returning: $0) }
        }
        #expect(try result.get().entries.map(\.meta.name) == ["a.txt"])
    }

    @Test("Kinds from types, names and flags")
    func classifier() {
        func k(_ name: String, dir: Bool = false, pkg: Bool = false, capture: Bool = false) -> FileKind {
            FileKindClassifier.classify(name: name, contentType: nil, isDirectory: dir, isPackage: pkg, isScreenCapture: capture)
        }
        #expect(k("a.png") == .image)
        #expect(k("IMG_0001.HEIC") == .image)
        #expect(k("a.png", capture: true) == .screenshot)
        #expect(k("스크린샷 2026-10-12 오후 3.04.11.png".decomposedStringWithCanonicalMapping) == .screenshot)
        #expect(k("Screen Shot 2019-01-01 at 1.00.00 PM.png") == .screenshot)
        #expect(k("a.pdf") == .pdf)
        #expect(k("a.txt") == .text && k("a.md") == .text)
        #expect(k("a.swift") == .code && k("a.json") == .code && k("a.sh") == .code && k("a.html") == .code)
        #expect(k("a.zip") == .zip && k("a.tar.gz") == .zip)
        #expect(k("a.dmg") == .dmg)
        #expect(k("a.mov") == .video && k("a.mp4") == .video)
        #expect(k("a.mp3") == .audio)
        #expect(k("a.docx") == .doc && k("a.rtf") == .doc && k("a.xlsx") == .doc)
        #expect(k("Notes.rtfd", dir: true, pkg: true) == .doc)
        #expect(k("Safari.app", dir: true, pkg: true) == .app)
        #expect(k("Folder", dir: true) == .folder)
        #expect(k("odd.with.dots", dir: true) == .folder)
        #expect(k("noextension") == .unknown)
        #expect(k("weird.zzqq") == .unknown)
    }
}

import DeskCore
import Foundation
import Testing
#if os(Windows)
import WinSDK
#endif
@testable import DeskFiles

/// The low-level calls every file operation goes through, on the platform the tests run on (docs/WINDOWS.md WP5).
@Suite("File primitives")
struct FilePrimitivesTests {
    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskterior-prim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func put(_ text: String, _ url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("An exclusive rename never replaces: a taken name is EEXIST and both items stay; a free one keeps identity")
    func renameExclusive() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try Self.put("A", a)
        try Self.put("B", b)
        #expect(FilePrimitives.renameExclusive(a, b) == EEXIST)
        #expect(Self.text(a) == "A" && Self.text(b) == "B")
        let before = try FilePrimitives.status(a).get()
        let c = dir.appendingPathComponent("사진 🧳.txt")
        #expect(FilePrimitives.renameExclusive(a, c) == 0)
        let after = try FilePrimitives.status(c).get()
        #expect(after.inode == before.inode && after.device == before.device)
        #expect(Self.text(c) == "A" && !FileManager.default.fileExists(atPath: a.path))
        #expect(FilePrimitives.renameExclusive(a, dir.appendingPathComponent("z.txt")) == ENOENT)
    }

    @Test("A folder renames as one item; a missing source is ENOENT")
    func renameFolder() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Self.put("x", folder.appendingPathComponent("in.txt"))
        let moved = dir.appendingPathComponent("Folder 2")
        #expect(FilePrimitives.renameExclusive(folder, moved) == 0)
        #expect(Self.text(moved.appendingPathComponent("in.txt")) == "x")
        #expect(try FilePrimitives.status(moved).get().isDirectory)
    }

    @Test("A new file is written whole and never over an existing item")
    func writeNewFile() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("메모.txt")
        try FilePrimitives.writeNewFile(Data("first".utf8), to: url)
        #expect(Self.text(url) == "first")
        #expect(throws: (any Error).self) { try FilePrimitives.writeNewFile(Data("second".utf8), to: url) }
        #expect(Self.text(url) == "first")
        let st = try FilePrimitives.status(url).get()
        #expect(st.kind == .regular && st.size == 5)
    }

    @Test("Own files: append makes and extends, reads stop at the limit, a folder is refused")
    func ownFiles() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("log.txt")
        #expect(FilePrimitives.appendToOwnFile(Data("one\n".utf8), at: log) == 0)
        #expect(FilePrimitives.appendToOwnFile(Data("two\n".utf8), at: log) == 0)
        #expect(try FilePrimitives.readOwnFile(log, maxBytes: 100).get() == .data(Data("one\ntwo\n".utf8)))
        #expect(try FilePrimitives.readOwnFile(log, maxBytes: 4).get() == .tooLarge(8))
        #expect(FilePrimitives.appendToOwnFile(Data("x".utf8), at: dir) != 0)
        guard case .failure(ENOENT) = FilePrimitives.readOwnFile(dir.appendingPathComponent("none"), maxBytes: 10) else {
            Issue.record("a missing file is ENOENT")
            return
        }
        let rotated = dir.appendingPathComponent("log.txt.1")
        try Self.put("old", rotated)
        #expect(FilePrimitives.replaceOwnFile(log, with: rotated) == 0)
        #expect(Self.text(rotated) == "one\ntwo\n")
    }

    @Test("Our folders are made (hidden on Windows) and removed only when empty")
    func directories() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = dir.appendingPathComponent(FileMoves.partialPrefix + "test")
        #expect(FilePrimitives.makeDirectory(staging, hidden: true) == 0)
        #expect(FilePrimitives.makeDirectory(staging, hidden: true) == EEXIST)
        #if os(Windows)
        #expect(try FilePrimitives.status(staging).get().flags & Win32.hidden != 0)
        #endif
        try Self.put("x", staging.appendingPathComponent("f"))
        #expect(FilePrimitives.removeEmptyDirectory(staging) != 0)
        try FileManager.default.removeItem(at: staging.appendingPathComponent("f"))
        #expect(FilePrimitives.removeEmptyDirectory(staging) == 0)
    }

    @Test("A copy goes item by item through the gate, and stops where the gate says")
    func copyTree() throws {
        #if canImport(Darwin)
        // macOS copies with FileManager and its delegate (FileOperatorTests); there is no copyTree.
        #else
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Inner"), withIntermediateDirectories: true)
        try Self.put("1", source.appendingPathComponent("a.jpg"))
        try Self.put("2", source.appendingPathComponent("Inner/b.jpg"))
        var seen = 0
        try FilePrimitives.copyTree(source, to: dir.appendingPathComponent("Copy")) { _ in
            seen += 1
            return true
        }
        #expect(seen == 4)
        #expect(Self.text(dir.appendingPathComponent("Copy/Inner/b.jpg")) == "2")
        #expect(throws: (any Error).self) {
            try FilePrimitives.copyTree(source, to: dir.appendingPathComponent("Copy")) { _ in true }
        }
        var started = 0
        try FilePrimitives.copyTree(source, to: dir.appendingPathComponent("Part")) { _ in
            started += 1
            return started <= 2
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Part").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Part/Inner/b.jpg").path))
        #endif
    }

    #if os(Windows)
    @Test("Windows: an item open without delete sharing is locked: its rename is EPERM and it stays")
    func lockedWhileOpen() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("open.docx")
        try Self.put("doc", file)
        let h = Win32.withWide(Win32.path(file)) {
            CreateFileW($0, Win32.genericRead, DWORD(0x1), nil, Win32.openExisting, Win32.normal, nil)   // share read only
        }
        let handle = try #require(h.flatMap { $0 == Win32.invalidHandle ? nil : $0 })
        #expect(FilePrimitives.isLocked(file))
        #expect(FilePrimitives.renameExclusive(file, dir.appendingPathComponent("moved.docx")) == EPERM)
        CloseHandle(handle)
        #expect(!FilePrimitives.isLocked(file))
        #expect(FilePrimitives.renameExclusive(file, dir.appendingPathComponent("moved.docx")) == 0)
    }

    @Test("Windows: paths longer than 260 characters work")
    func longPaths() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var deep = dir
        for i in 0..<6 { deep = deep.appendingPathComponent(String(repeating: "폴더\(i)", count: 12)) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        #expect(Win32.path(deep).count > 260)
        let file = deep.appendingPathComponent("long.txt")
        try FilePrimitives.writeNewFile(Data("deep".utf8), to: file)
        #expect(try FilePrimitives.status(file).get().size == 4)
        #expect(FilePrimitives.renameExclusive(file, deep.appendingPathComponent("long 2.txt")) == 0)
    }

    @Test("Windows: hidden and system items are left out of a scan, desktop.ini too; shortcuts are aliases")
    func scanAttributes() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["shown.txt", "hidden.txt", "desktop.ini"] { try Self.put("x", dir.appendingPathComponent(name)) }
        _ = Win32.withWide(Win32.path(dir.appendingPathComponent("hidden.txt"))) { SetFileAttributesW($0, Win32.hidden) }
        let target = dir.appendingPathComponent("shown.txt")
        try FilePrimitives.writeLink(to: target, at: dir.appendingPathComponent("shown.txt.lnk"))
        let snapshot = try DesktopScanner(root: dir).scan()
        #expect(snapshot.entries.map(\.meta.name) == ["shown.txt", "shown.txt.lnk"])
        let link = try #require(snapshot.entries.last)
        #expect(link.meta.isAlias && link.meta.hidesExtension && link.meta.kind == .text)
    }
    #endif
}

import Foundation
import Testing
@testable import DeskFiles

/// FakeTrasher works in a scratch folder; SystemTrasher is only ever asked path questions, so the real Trash is
/// never touched.
@Suite("Trasher")
struct TrasherTests {
    @Test("FakeTrasher renames items into its folder and says where they went")
    func fakeTrash() async throws {
        let d = try TempDesk()
        let desk = try d.mkdir("Desk")
        let trasher = try FakeTrasher(folder: d.url("State/FakeTrash"), desktop: desk)
        let a = try d.write("Desk/a.txt", "first")
        let inode = d.inode("Desk/a.txt")
        let to = try #require(try await trasher.trash(a))
        #expect(to.lastPathComponent == "a.txt")
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(d.inode("State/FakeTrash/a.txt") == inode)
        #expect(trasher.trashFolder == trasher.folder)
        #expect(trasher.contains(to))

        // A second "a.txt" never replaces the first.
        let again = try d.write("Desk/a.txt", "second")
        let to2 = try #require(try await trasher.trash(again))
        #expect(to2.lastPathComponent == "a 2.txt")
        #expect(try String(contentsOf: to, encoding: .utf8) == "first")
        #expect(try String(contentsOf: to2, encoding: .utf8) == "second")

        // Folders and packages go whole; packages are numbered before their extension.
        for _ in 0..<2 {
            try d.mkdir("Desk/Notes.rtfd")
            try d.write("Desk/Notes.rtfd/TXT.rtf", "rtf")
            _ = try await trasher.trash(d.url("Desk/Notes.rtfd", isDirectory: true))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: trasher.folder.path).sorted()
        #expect(names == ["Notes 2.rtfd", "Notes.rtfd", "a 2.txt", "a.txt"])
    }

    @Test("FakeTrasher reports a missing item and changes nothing")
    func missing() async throws {
        let d = try TempDesk()
        let trasher = try FakeTrasher(folder: d.url("Trash"), desktop: d.url("Desk"))
        await #expect(throws: FileRefusal.missing) { try await trasher.trash(d.url("nope.txt")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: trasher.folder.path).isEmpty)
    }

    @Test("FakeTrasher contains only its own direct children")
    func containment() throws {
        let d = try TempDesk()
        let trasher = try FakeTrasher(folder: d.url("Trash"), desktop: d.url("Desk"))
        #expect(trasher.contains(trasher.folder.appendingPathComponent("x.txt")))
        #expect(trasher.contains(d.url("Trash/x.txt")))
        #expect(!trasher.contains(trasher.folder.appendingPathComponent("sub/x.txt")))
        #expect(!trasher.contains(trasher.folder))
        #expect(!trasher.contains(d.url("Trash/../x.txt")))
        #expect(!trasher.contains(d.url("Desk/x.txt")))
    }

    @Test("FakeTrasher refuses a folder inside the desktop folder or the mirrored folder")
    func refusesDesktop() throws {
        let d = try TempDesk()
        let desk = try d.mkdir("Desk")
        let mirrored = try d.mkdir("Mirrored")
        #expect(throws: SafetyGuard.Refusal.self) { try FakeTrasher(folder: desk.appendingPathComponent("Trash"), desktop: desk) }
        #expect(throws: SafetyGuard.Refusal.self) {
            try FakeTrasher(folder: mirrored.appendingPathComponent("Trash"), desktop: desk, mirrored: mirrored)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: mirrored.path).isEmpty)
    }

    @Test("SystemTrasher recognizes trash children by spelling only")
    func systemTrashSpelling() {
        let home = URL(fileURLWithPath: "/Users/someone/.Trash", isDirectory: true)
        func isChild(_ path: String) -> Bool {
            SystemTrasher.isTrashChild(URL(fileURLWithPath: path), homeTrash: home, uid: 501)
        }
        #expect(isChild("/Users/someone/.Trash/report.pdf"))
        #expect(isChild("/Users/someone/.Trash/Notes.rtfd"))
        #expect(isChild("/Volumes/Stick/.Trashes/501/photo.png"))
        #expect(!isChild("/Volumes/Stick/.Trashes/502/photo.png"))
        #expect(!isChild("/Users/someone/.Trash/sub/report.pdf"))
        #expect(!isChild("/Users/someone/.Trash/../Documents/report.pdf"))
        #expect(!isChild("/Users/someone/.Trash"))
        #expect(!isChild("/Users/someone/Documents/report.pdf"))
        #expect(SystemTrasher().trashFolder == nil)
    }
}

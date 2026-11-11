import DeskCore
import Foundation
import Testing
@testable import DeskteriorWin

@Suite("Windows shell options")
struct WinOptionsTests {
    @Test("Options parse; bad and unknown ones are refused")
    func parse() throws {
        let o = try WinOptions.parse(["--snapshot", "out.png", "--desktop-folder", #"C:\Desk"#, "--size", "1920x1080",
                                      "--scale", "1.5", "--frames", "60", "--connect", "--quit-after", "5"])
        #expect(o.snapshot == "out.png" && o.folder == #"C:\Desk"# && o.width == 1920 && o.height == 1080)
        #expect(o.scale == 1.5 && o.frames == 60 && o.connect && o.quitAfter == 5)
        #expect(throws: WinOptions.Failure.unknown("--nope")) { try WinOptions.parse(["--nope"]) }
        #expect(throws: WinOptions.Failure.missingValue("--snapshot")) { try WinOptions.parse(["--snapshot"]) }
        #expect(throws: WinOptions.Failure.badValue("--size", "10x10")) { try WinOptions.parse(["--size", "10x10"]) }
    }

    @Test("The grid for a window covers its client area at an integer scale")
    func grid() {
        let g = WinOptions.grid(width: 1920, height: 1080, scale: 1.5)
        #expect(g.scale >= 1 && g.artSize.w * g.scale >= 1920 && g.artSize.h * g.scale >= 1080)
    }
}

@Suite("Headless snapshot of a folder")
struct SnapshotTests {
    @Test("A folder's items land on the desk's screen and the frame is written; no item is touched")
    func snapshot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deskterior-win-\(UUID().uuidString)", isDirectory: true)
        let desk = root.appendingPathComponent("Desk", isDirectory: true)
        try fm.createDirectory(at: desk.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in ["notes.txt", "Report.pdf", "사진.png"] {
            try Data("x".utf8).write(to: desk.appendingPathComponent(name))
        }
        let before = try fm.contentsOfDirectory(atPath: desk.path).sorted()
        var o = WinOptions()
        o.folder = desk.path
        o.snapshot = root.appendingPathComponent("snap.png").path
        o.frames = 30
        let report = try Snapshot.run(o, environment: [:])
        #expect(report.tokens == 4)
        #expect(report.device.0 == 1280 && report.device.1 == 800)
        #expect(report.refused.isEmpty)
        let png = try Data(contentsOf: root.appendingPathComponent("snap.png"))
        #expect(png.count > 1000 && png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(try fm.contentsOfDirectory(atPath: desk.path).sorted() == before)
    }
}

@Suite("Windows shell session")
struct WinSessionTests {
    @Test("Connected, the watcher's snapshots arrive through pump(), and a new file shows up")
    func watcherThroughPump() async throws {
        let fm = FileManager.default
        let desk = fm.temporaryDirectory.appendingPathComponent("deskterior-win-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: desk, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: desk) }
        try Data("x".utf8).write(to: desk.appendingPathComponent("first.txt"))
        let session = try WinSession(grid: WinOptions.grid(width: 1280, height: 800, scale: 1), folder: desk,
                                     stateDirectory: nil)
        defer { session.stop() }
        session.start(connect: true)
        func wait(_ done: () -> Bool) async throws {
            let until = Date().addingTimeInterval(60)                // a busy runner delivers late
            while !done(), Date() < until {
                session.pump()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await wait { session.state.tokens.records.count == 1 }
        #expect(session.snapshots >= 1 && session.state.tokens.records.count == 1)
        try Data("y".utf8).write(to: desk.appendingPathComponent("second.txt"))
        try await wait { session.state.tokens.records.count == 2 }
        #expect(session.state.tokens.records.count == 2)
    }
}

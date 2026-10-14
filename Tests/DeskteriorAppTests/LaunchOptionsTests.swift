import DeskCore
import DeskFiles
import Foundation
import Testing
@testable import DeskteriorApp

/// A scratch folder at `FileManager.temporaryDirectory/deskterior-apptests-<uuid>`, removed on deinit; app tests
/// work only in here (a stand-in desktop and home included), never on the real ones.
final class AppTemp: @unchecked Sendable {
    let root: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskterior-apptests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: DesktopLocator.canonicalPath(base), isDirectory: true)
    }

    deinit {
        guard root.lastPathComponent.hasPrefix("deskterior-apptests-") else { return }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func dir(_ path: String) throws -> URL {
        let u = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func file(_ path: String, _ text: String = "x") throws -> URL {
        let u = root.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }
}

@Suite("Launch options")
struct LaunchOptionsTests {
    @Test("No flags is desk mode with the documented defaults")
    func defaults() throws {
        let o = try LaunchOptions.parse([])
        #expect(o.mode == .desk && o.windowed == nil && o.demo == nil && !o.headless)
        #expect(o.level == .iconPlus1 && !o.levelGiven && o.pixelSize == .normal && !o.pixelSizeGiven)
        #expect(o.icons == .live && o.frames == 30 && o.snapshotScale == 3 && o.lights == .auto)
        #expect(o.exitAfter == nil && o.desktopFolder == nil && o.stateDir == nil && !o.burst && !o.safeMode)
    }

    @Test("Modes: --windowed (with or without a size), --headless, and --demo (which is headless)")
    func modes() throws {
        #expect(try LaunchOptions.parse(["--windowed"]).windowed == .standard)
        let sized = try LaunchOptions.parse(["--windowed", "1920x1080@1"])
        #expect(sized.mode == .windowed && sized.windowed == .init(widthPt: 1920, heightPt: 1080, scale: 1))
        #expect(try LaunchOptions.parse(["--windowed=800x600@1.5"]).windowed?.description == "800x600@1.5")
        // A flag after an optional-value flag is not taken as its value.
        let then = try LaunchOptions.parse(["--windowed", "--burst"])
        #expect(then.windowed == .standard && then.burst)
        #expect(try LaunchOptions.parse(["--headless"]).mode == .headless)
        #expect(try LaunchOptions.parse(["--windowed", "--headless"]).mode == .headless)
        let demo = try LaunchOptions.parse(["--demo", "Demos/01-mirror.json"])
        #expect(demo.mode == .headless && demo.demo == "Demos/01-mirror.json")
    }

    @Test("The environment sets flags as DESKTERIOR_<NAME>; command-line flags win")
    func environment() throws {
        let env = ["DESKTERIOR_SNAPSHOT_DIR": "/tmp/shots", "DESKTERIOR_FRAMES": "9", "DESKTERIOR_HEADLESS": "yes",
                   "DESKTERIOR_WINDOWED": "1", "DESKTERIOR_EMPTY": ""]
        let o = try LaunchOptions.parse(["--frames", "5"], environment: env)
        #expect(o.snapshotDir == "/tmp/shots" && o.frames == 5 && o.headless && o.windowed == .standard)
        #expect(try LaunchOptions.parse([], environment: ["DESKTERIOR_WINDOWED": "1024x768"]).windowed?.widthPt == 1024)
        #expect(throws: LaunchOptions.UsageError.self) { try LaunchOptions.parse([], environment: ["DESKTERIOR_BURST": "maybe"]) }
        #expect(!(try LaunchOptions.parse([], environment: ["DESKTERIOR_BURST": "0"])).burst)
    }

    @Test("Bad flags are usage errors (the app prints the usage and exits 2)",
          arguments: [["--nope"], ["--frames"], ["--frames", "-1"], ["--level", "icon+2"], ["--exit-after", "0"],
                      ["--exit-after", "nan"], ["--seed", "-3"], ["--show", "bogus"], ["--show", ""], ["--headless=1"],
                      ["--windowed", "10x10"], ["--windowed", "800x600@5"], ["--pixel-size", "huge"],
                      ["--lights", "dusk"], ["--icons", "emoji"], ["--language", "fr"], ["--clock", "25:99"]])
    func usageErrors(args: [String]) {
        #expect(throws: LaunchOptions.UsageError.self) { try LaunchOptions.parse(args) }
    }

    @Test("--level and --pixel-size mark themselves as given, so they win over Settings for the run")
    func given() throws {
        let o = try LaunchOptions.parse(["--level", "icon+3", "--pixel-size", "fine", "--show", "settings, about"])
        #expect(o.level == .iconPlus3 && o.levelGiven && o.pixelSize == .fine && o.pixelSizeGiven)
        #expect(o.show == ["settings", "about"])
    }

    // MARK: The real Desktop is refused (exit 64)

    /// A stand-in user: `home/Desk` plays the real desktop, so nothing here names or reads the real one.
    struct World {
        let temp: AppTemp
        let home: URL
        let desktop: URL
        let scratch: URL

        init() throws {
            temp = try AppTemp()
            home = try temp.dir("home")
            desktop = try temp.dir("home/Desk")
            scratch = try temp.dir("scratch")
        }

        func refusal(_ args: [String], env: [String: String] = [:]) throws -> SafetyGuard.Refusal? {
            MirrorController.launchRefusal(options: try LaunchOptions.parse(args), environment: env,
                                           realDesktop: desktop, home: home)
        }
    }

    @Test("Development modes refuse the desktop, a folder in it or around it, and no folder at all, with exit 64",
          arguments: [["--windowed"], ["--headless"], ["--demo", "x.json"]])
    func refusesRealDesktop(mode: [String]) throws {
        let w = try World()
        let state = ["--state-dir", w.temp.root.appendingPathComponent("state").path]
        let inside = try w.temp.dir("home/Desk/Project")
        #expect(try w.refusal(mode + state)?.reason == .noFolderGiven)
        #expect(try w.refusal(mode + state + ["--desktop-folder", w.desktop.path])?.reason == .realDesktop)
        #expect(try w.refusal(mode + state + ["--desktop-folder", inside.path])?.reason == .insideRealDesktop)
        #expect(try w.refusal(mode + state + ["--desktop-folder", w.home.path])?.reason == .enclosesRealDesktop)
        #expect(try w.refusal(mode + state, env: ["DESKTERIOR_DESKTOP_FOLDER": w.desktop.path])?.reason == .realDesktop)
        // Spelled another way: a trailing "..", or through a symlink.
        let link = w.temp.root.appendingPathComponent("link")
        #expect(symlink(w.desktop.path, link.path) == 0)
        #expect(try w.refusal(mode + state + ["--desktop-folder", link.path])?.reason == .realDesktop)
        #expect(try w.refusal(mode + state + ["--desktop-folder", inside.path + "/.."])?.reason == .realDesktop)
        #expect(try w.refusal(mode + state + ["--desktop-folder", w.desktop.path])?.exitCode == 64)
        #expect(SafetyGuard.refusalExitCode == 64)
        // A scratch folder is fine; our own folders may not sit in the desktop or the mirrored folder.
        #expect(try w.refusal(mode + state + ["--desktop-folder", w.scratch.path]) == nil)
        #expect(try w.refusal(mode + ["--desktop-folder", w.scratch.path, "--state-dir", w.desktop.path + "/state"])?
            .reason == .insideRealDesktop)
        #expect(try w.refusal(mode + ["--desktop-folder", w.scratch.path, "--state-dir", w.scratch.path + "/state"])?
            .reason == .insideMirroredFolder)
        #expect(try w.refusal(mode + state + ["--desktop-folder", w.scratch.path + "/missing"])?.reason == .missingFolder)
        let file = try w.temp.file("plain.txt")
        #expect(try w.refusal(mode + state + ["--desktop-folder", file.path])?.reason == .notADirectory)
    }

    @Test("Desk mode mirrors the desktop itself, but never the home folder or a folder around the desktop")
    func deskMode() throws {
        let w = try World()
        let state = ["--state-dir", w.temp.root.appendingPathComponent("state").path]
        #expect(try w.refusal(state, env: ["DESKTERIOR_DESKTOP_FOLDER": w.desktop.path]) == nil)
        #expect(try w.refusal(state + ["--desktop-folder", w.scratch.path]) == nil)
        #expect(try w.refusal(state + ["--desktop-folder", w.home.path])?.reason == .enclosesRealDesktop)
        #expect(try w.refusal(state + ["--desktop-folder", "/"])?.reason == .enclosesRealDesktop)
    }

    @Test("A development run with a scratch folder keeps its state in a temporary folder and connects at once")
    func developmentConfiguration() throws {
        let w = try World()
        let o = try LaunchOptions.parse(["--windowed", "--desktop-folder", w.scratch.path])
        let c = try MirrorController.configuration(options: o, environment: [:], realDesktop: w.desktop, home: w.home)
        #expect(c.connectImmediately)
        #expect(c.stateDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(c.iconCacheDirectory.deletingLastPathComponent().path == c.stateDirectory.path)
        #expect(!DesktopLocator.isInsideDesktop(c.stateDirectory, desktop: w.desktop))
    }
}

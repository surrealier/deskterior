import Foundation
import Testing
@testable import DeskFiles

/// The real desktop is used only as a path to compare against; nothing is listed, created or written there.
@Suite("SafetyGuard and DesktopLocator")
struct SafetyGuardTests {
    static let devModes: [SafetyGuard.Mode] = [.windowed, .headless, .demo, .test, .tool]
    let real = DesktopLocator.defaultDesktopURL()

    func override(_ path: String) -> DesktopLocator.Resolution {
        DesktopLocator.resolve(override: path)
    }

    func refusal(_ r: DesktopLocator.Resolution, _ mode: SafetyGuard.Mode) -> SafetyGuard.Refusal.Reason? {
        do throws(SafetyGuard.Refusal) {
            _ = try SafetyGuard.mirrorFolder(r, mode: mode, realDesktop: real)
            return nil
        } catch {
            #expect(error.exitCode == 64)
            return error.reason
        }
    }

    @Test("Development modes refuse the real desktop, anything inside it and anything above it (exit 64)")
    func refusesRealDesktop() throws {
        let d = try TempDesk()
        let link = d.url("desk-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let home = real.deletingLastPathComponent()
        for mode in Self.devModes {
            #expect(refusal(override(real.path), mode) == .realDesktop)
            #expect(refusal(override(real.path.uppercased()), mode) == .realDesktop)
            #expect(refusal(override("~/Desktop"), mode) == .realDesktop)
            #expect(refusal(override(link.path), mode) == .realDesktop)
            #expect(refusal(override(real.appendingPathComponent("demo").path), mode) == .insideRealDesktop)
            #expect(refusal(override(real.appendingPathComponent("a/../b/c").path), mode) == .insideRealDesktop)
            #expect(refusal(override(link.appendingPathComponent("sub").path), mode) == .insideRealDesktop)
            #expect(refusal(override(home.path), mode) == .enclosesRealDesktop)
            #expect(refusal(override("/"), mode) == .enclosesRealDesktop)
            #expect(refusal(DesktopLocator.resolve(override: nil), mode) == .noFolderGiven)
        }
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("demo").path))
    }

    @Test("Development modes accept an existing scratch folder; missing folders and files are refused")
    func scratchFolders() throws {
        let d = try TempDesk()
        let fixture = try d.mkdir("fixture")
        for mode in Self.devModes {
            #expect(refusal(override(fixture.path), mode) == nil)
            #expect(refusal(override(d.url("missing").path), mode) == .missingFolder)
            #expect(refusal(override(try d.write("file.txt").path), mode) == .notADirectory)
        }
        #expect(try SafetyGuard.mirrorFolder(override(fixture.path), mode: .headless) == fixture.standardizedFileURL)
    }

    @Test("Desk mode mirrors whatever was resolved")
    func deskMode() throws {
        let d = try TempDesk()
        #expect(refusal(override(d.root.path), .desk) == nil)
        #expect(SafetyGuard.Mode.desk.requiresSandboxFolder == false)
        #expect(Self.devModes.allSatisfy { $0.requiresSandboxFolder })
    }

    @Test("Resolution: flag, then environment, then the real desktop")
    func resolution() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(DesktopLocator.resolve(override: "~/fixture").url.path == home + "/fixture")
        #expect(DesktopLocator.resolve(override: "/tmp/a/../b").url.path == "/tmp/b")
        let env = ["DESKTERIOR_DESKTOP": "/tmp/env-desk", "DESKTERIOR_DESKTOP_FOLDER": ""]
        #expect(DesktopLocator.resolve(override: nil, environment: env) == .init(url: URL(fileURLWithPath: "/tmp/env-desk", isDirectory: true), isOverride: true))
        #expect(DesktopLocator.resolve(override: "/tmp/flag", environment: env).url.path == "/tmp/flag")
        #expect(DesktopLocator.resolve(override: "", environment: [:]) == .init(url: real, isOverride: false))
        #expect(DesktopLocator.resolve(override: nil, environment: ["DESKTERIOR_DESKTOP_FOLDER": "/tmp/f"]).url.path == "/tmp/f")
    }

    @Test("Own writes stay inside their root and outside the desktop")
    func ownWrites() throws {
        let d = try TempDesk()
        let state = try d.mkdir("state")
        let fakeDesk = try d.mkdir("FakeDesk")
        #expect(throws: Never.self) { try SafetyGuard.checkOwnWrite(state.appendingPathComponent("desk.json"), root: state, desktop: fakeDesk) }
        #expect(throws: SafetyGuard.Refusal.self) { try SafetyGuard.checkOwnWrite(d.url("escape.json"), root: state, desktop: fakeDesk) }
        #expect(throws: SafetyGuard.Refusal.self) {
            try SafetyGuard.checkOwnWrite(state.appendingPathComponent("../escape.json"), root: state, desktop: fakeDesk)
        }
        #expect(throws: SafetyGuard.Refusal.self) { try SafetyGuard.checkOwnWrite(fakeDesk.appendingPathComponent("x"), root: fakeDesk, desktop: fakeDesk) }
    }

    @Test("Root confinement: only direct children count")
    func directChildren() throws {
        let d = try TempDesk()
        let desk = try d.mkdir("Desk")
        #expect(SafetyGuard.isDirectChild(desk.appendingPathComponent("a.txt"), of: desk))
        #expect(SafetyGuard.isDirectChild(URL(fileURLWithPath: desk.path.replacingOccurrences(of: "/private/var", with: "/var") + "/b"), of: desk))
        #expect(!SafetyGuard.isDirectChild(desk.appendingPathComponent("sub/a.txt"), of: desk))
        #expect(!SafetyGuard.isDirectChild(desk.appendingPathComponent("../a.txt"), of: desk))
        #expect(!SafetyGuard.isDirectChild(desk, of: desk))
        #expect(DesktopLocator.enclosesDesktop(d.root, desktop: desk))
        #expect(!DesktopLocator.enclosesDesktop(desk, desktop: desk))
    }
}

import AppKit
import DeskCore
import DeskFiles
import Foundation
import Metal
import Testing
@testable import DeskteriorApp

/// The v0.1.0 release review's fixes in the app (Erratum 28): a folder switch re-points the desk view's drop-in and
/// drag-out, a saved folder that is gone at launch shows the Desktop instead of exiting, and "Drag-out: Always copy"
/// is applied. Stand-in desktops and scratch folders only.
@Suite("Release review (app)")
struct ReleaseReviewAppTests {
    @Test("Desk mode: a saved folder that is gone (or a file) shows the Desktop this launch, Safe Mode included")
    func savedFolderMissing() throws {
        let w = try LaunchOptionsTests.World()
        let state = ["--state-dir", w.temp.root.appendingPathComponent("state").path]
        // The stand-in desktop plays the real one (the environment override desk mode accepts).
        let env = ["DESKTERIOR_DESKTOP_FOLDER": w.desktop.path]
        func launch(_ args: [String], saved: String?) throws -> Result<MirrorController.Configuration, SafetyGuard.Refusal> {
            var settings = DeskSettings()
            settings.mirroredFolder = saved
            return MirrorController.launch(options: try LaunchOptions.parse(args), environment: env,
                                           bundleID: AppIdentity.fallbackBundleID, settings: settings,
                                           realDesktop: w.desktop, home: w.home)
        }
        let file = try w.temp.file("plain.txt")
        for saved in [w.scratch.path + "/gone", file.path] {
            for args in [state, state + ["--safe-mode"]] {
                let c = try launch(args, saved: saved).get()
                #expect(DesktopLocator.canonicalPath(c.folder) == DesktopLocator.canonicalPath(w.desktop), "\(args)")
                #expect(c.savedFolderUnavailable == saved && !c.connectImmediately)
            }
        }
        // A saved folder that is there is mirrored, with nothing to say.
        let there = try launch(state, saved: w.scratch.path).get()
        #expect(DesktopLocator.canonicalPath(there.folder) == DesktopLocator.canonicalPath(w.scratch))
        #expect(there.savedFolderUnavailable == nil)
        // A folder named on the command line, and the development modes, still refuse with exit 64.
        let named = try launch(state + ["--desktop-folder", w.scratch.path + "/gone"], saved: w.scratch.path)
        if case let .failure(r) = named { #expect(r.reason == .missingFolder && r.exitCode == 64) } else {
            Issue.record("--desktop-folder pointing nowhere is refused")
        }
        let windowed = try launch(["--windowed"] + state, saved: w.scratch.path + "/gone")
        if case let .failure(r) = windowed { #expect(r.reason == .realDesktop && r.exitCode == 64) } else {
            Issue.record("a development run never falls back to the Desktop")
        }
        #expect(L10n.text(.folderMissing, .ko) != L10n.text(.folderMissing, .en))
    }
}

@Suite("Release review (app sessions)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct ReleaseReviewSessionTests {
    @Test("A folder switch hands the desk view the new session's drop-in and drag-out; the old ones go with it")
    func switchAttaches() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view = DeskView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), device: device)
        let new = try SessionRig()
        weak var oldStore: Store?
        weak var oldEffects: EffectRunner?
        try autoreleasepool {
            let old = try SessionRig()
            old.session.attach(to: view)  // launchDesk
            #expect(view.dropIn === old.session.dropIn && view.dragOut === old.session.dragOut)
            oldStore = old.session.store
            oldEffects = old.session.effects
            new.session.attach(to: view)  // switchFolder, once `session = new`
        }
        #expect(view.dropIn === new.session.dropIn && view.dragOut === new.session.dragOut)
        #expect(oldStore == nil && oldEffects == nil, "the view no longer holds controllers of a session that is gone")
    }

    @Test("Drag-out: Always copy offers only copying, from the launch's (or a folder switch's) settings")
    func dragOutMode() throws {
        #expect(try SessionRig().session.dragOut.alwaysCopy == false)
        var settings = DeskSettings()
        settings.dragOutMode = .alwaysCopy
        let rig = try SessionRig(settings: settings)
        #expect(rig.session.dragOut.alwaysCopy)
        #expect(DragOutController.mask(DragOutRule.offered(alwaysCopy: rig.session.dragOut.alwaysCopy)) == .copy)
    }
}

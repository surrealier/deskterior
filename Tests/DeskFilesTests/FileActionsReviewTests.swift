import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// M11 review fixes on the DeskFiles side: a slow eject never blocks the operator, a demo's drop source is a scratch
/// folder of its own, and the lint holds who may build file requests and name their gestures. Temp folders only; a
/// fake home stands in for the real one.
@Suite("File actions review (DeskFiles)")
struct FileActionsReviewTests {
    /// Things that happened, in order, from any thread.
    final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    /// Waits off the cooperative pool for `semaphore`, at most `seconds`: false when it never came (a hang becomes a
    /// failure with a message, never a stuck suite). Generous: on a starved pool a long synchronous test elsewhere can
    /// hold a task back for minutes.
    static func wait(_ semaphore: DispatchSemaphore, seconds: Double = 600) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                done.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success)
            }
        }
    }

    @Test("A slow eject runs off the actor: a trash asked for while it unmounts is served at once")
    func ejectOffActor() async throws {
        let rig = try FileRig()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }  // a failed run never leaves the unmount waiting
        let order = Order()
        await rig.op.setHooks(FileOperator.Hooks(ejectable: { _ in true }, unmount: { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 600)
            order.add("unmounted")
        }))
        let volume = URL(fileURLWithPath: "/Volumes/Slow", isDirectory: true)
        // Minted inside the task, as the copy tests do, so a task a busy pool starts late still holds a fresh intent.
        let eject = Task { await rig.op.eject(volume, rig.intent()) }
        try #require(await Self.wait(entered), "the eject never reached the unmount: \(rig.log.entries().map(\.outcome))")
        // An actor held by the unmount would serve the trash only after this failsafe lets the unmount go.
        let failsafe = Task {
            try? await Task.sleep(for: .seconds(5))
            release.signal()
        }
        let a = try rig.file(rig.desk, "a.txt")
        let trashed = await rig.op.trash([a], expecting: [rig.key(a)], rig.intent())
        order.add("trashed")
        failsafe.cancel()
        release.signal()
        #expect(await eject.value == .ejected(volume))
        #expect(trashed.refusals.isEmpty && !rig.exists(a))
        #expect(order.all.first == "trashed", "the trash waited for the unmount: \(order.all)")
    }

    @Test("A demo's drop source is a scratch folder inside a temporary folder, apart from the fixture and state")
    func scratchSource() throws {
        let temp = try TempDesk()
        let home = try temp.mkdir("home")
        let desktop = try temp.mkdir("home/Desktop")
        let documents = try temp.mkdir("home/Documents")
        let tmp = try temp.mkdir("tmp")
        let source = try temp.mkdir("tmp/demo/source")
        let fixture = try temp.mkdir("tmp/demo/desk")
        let state = try temp.mkdir("tmp/demo/state")
        func refused(_ url: URL, roots: [URL] = [tmp]) -> SafetyGuard.Refusal.Reason? {
            do {
                _ = try SafetyGuard.scratchSource(url.path, guarded: [fixture, state], temporaryRoots: roots,
                                                  realDesktop: desktop, home: home)
                return nil
            } catch {
                return error.reason
            }
        }
        let accepted = try SafetyGuard.scratchSource(source.path, guarded: [fixture, state], temporaryRoots: [tmp],
                                                     realDesktop: desktop, home: home)
        #expect(accepted.path == DesktopLocator.canonicalPath(source))
        #expect(refused(documents) == .notScratch, "a folder in home (Documents) is never a drop source")
        #expect(refused(tmp) == .notScratch, "the temporary folder itself is not a scratch folder of its own")
        #expect(refused(fixture) == .notScratch && refused(state) == .notScratch)
        #expect(refused(temp.url("tmp/demo", isDirectory: true)) == .notScratch, "it holds the fixture")
        #expect(refused(home) == .enclosesRealDesktop && refused(desktop) == .realDesktop)
        let inHome = try temp.mkdir("home/tmp/x")
        #expect(refused(inHome, roots: [temp.url("home/tmp", isDirectory: true)]) == .notScratch,
                "a TMPDIR inside home does not count")
        #expect(refused(temp.url("tmp/missing", isDirectory: true)) == .missingFolder)
    }

    @Test("The lint flags a file request built, or a gesture named, outside the allowed files")
    func lintGestureChecks() throws {
        let script = try String(contentsOf: FileSafetyLintTests.scriptURL, encoding: .utf8)
        let lint = try Lint(script: script)
        let planted = """
            store.dispatch(.requestTrash(keys))
            context.dispatch(.requestEmptyWastebasket)
            effects.withOrigin(.drop) { store.dispatch(.importDropped(urls, at: loc, op: .move)) }
            session.perform(.moveToTrash(keys), from: .menuItem)
            if case .requestTrash = action { return }
            let kind = FileReport.Kind.emptyWastebasket
            """
        func lines(_ file: String) -> [Int] {
            lint.violations(dirVar: "SRC", files: [(file, planted)]).filter { ["file-request", "origin"].contains($0.label) }
                .map(\.line).uniqued()
        }
        #expect(lines("DeskScene/Planted.swift") == [1, 2, 3, 4])
        #expect(lines("DeskteriorApp/UI/StatusMenu.swift") == [1, 2, 3, 4])
        #expect(lines("DeskteriorApp/Files/DragOutController.swift") == [])
        #expect(lines("DeskCore/Logic/MenuSpec.swift") == [3, 4], "menus build requests but name no gesture")
        #expect(lines("DeskteriorApp/AppDelegate.swift") == [1, 2, 3], "the app delegate names gestures only")
    }
}

import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// A one-way flag a GCD thread can wait on (never a Swift task: tasks poll `opened(within:)`).
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var isOpen: Bool { lock.withLock { isSet } }

    func open() { lock.withLock { isSet = true } }

    /// Blocks the calling thread until open; false after `seconds`.
    func wait(seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !isOpen {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    /// Polls from a task until open; false after `seconds`.
    func opened(within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !isOpen {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}

/// Values recorded from hooks and callbacks.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ t: T) { lock.withLock { items.append(t) } }
    var all: [T] { lock.withLock { items } }
}

/// A trash that lets an editor's safe-save replace the item between FileOperator's check and the move.
struct SwapTrasher: Trasher {
    let inner: FakeTrasher
    var trashFolder: URL? { inner.trashFolder }

    func trash(_ url: URL) async throws -> URL? {
        let save = url.deletingLastPathComponent().appendingPathComponent(".sb-save")
        try Data("newer version".utf8).write(to: save)
        guard rename(save.path, url.path) == 0 else { throw FileRefusal.failed(Int(errno)) }
        return try await inner.trash(url)
    }

    func contains(_ url: URL) -> Bool { inner.contains(url) }
}

/// Clears Finder locks under `url` so TempDesk can remove it.
private func unlockAll(_ url: URL) {
    _ = lchflags(url.path, 0)
    let e = FileManager.default.enumerator(atPath: url.path)
    while let rel = e?.nextObject() as? String { _ = lchflags(url.appendingPathComponent(rel).path, 0) }
}

private func isLocked(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0 && st.st_flags & UInt32(UF_IMMUTABLE) != 0
}

@Suite("FileOperator guards")
struct FileOperatorGuardTests {
    // MARK: Intents

    @Test("An intent is good for one request: a second use, on any operator, and a forged value are refused")
    func spentAndForged() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let b = try rig.file(rig.desk, "b.txt")
        let once = rig.intent()
        #expect(await rig.op.trash([a], expecting: [rig.key(a)], once).refusals.isEmpty)
        #expect(await rig.op.trash([b], expecting: [rig.key(b)], once).refusals == [.spentIntent])
        #expect(await rig.makeOperator().trash([b], expecting: [rig.key(b)], once).refusals == [.spentIntent])

        // The same bytes as a real intent, but an id the ledger never issued.
        struct Twin {
            var origin: ExplicitIntent.Origin
            var issuedAt: Date
            var instant: ContinuousClock.Instant
            var id: UUID
        }
        try #require(MemoryLayout<Twin>.size == MemoryLayout<ExplicitIntent>.size)
        let forged = unsafeBitCast(
            Twin(origin: .menuItem, issuedAt: rig.clock.now, instant: rig.clock.instant, id: UUID()), to: ExplicitIntent.self
        )
        #expect(forged.origin == .menuItem && forged.isFresh(at: rig.clock.instant))
        #expect(await rig.op.trash([b], expecting: [rig.key(b)], forged).refusals == [.spentIntent])
        #expect(await rig.op.importItems([try rig.file(rig.elsewhere, "c.txt")], op: .move, once).refusals == [.spentIntent])
        #expect(rig.exists(b))
        #expect(rig.trashNames == ["a.txt"])
        #expect(rig.log.entries().map(\.outcome) == ["ok"] + Array(repeating: "refused: spent-intent", count: 4))
    }

    @Test("A request refuses an intent whose origin does not fit it")
    func wrongOrigin() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let b = try rig.file(rig.elsewhere, "b.txt", "drop")
        #expect(FileOperator.Method.trash.origins == [.menuItem, .sheetConfirm, .dragToTrash, .inventory])
        #expect(FileOperator.Method.importItems.origins == [.drop])
        #expect(FileOperator.Method.undo.origins == [.undo])
        #expect(FileOperator.Method.eject.origins == [.menuItem, .inventory])

        for origin in [ExplicitIntent.Origin.drop, .undo] {
            #expect(await rig.op.trash([a], expecting: [rig.key(a)], rig.intent(origin)).refusals == [.wrongOrigin])
        }
        for origin in [ExplicitIntent.Origin.undo, .menuItem, .sheetConfirm, .dragToTrash, .inventory] {
            #expect(await rig.op.importItems([b], op: .move, rig.intent(origin)).refusals == [.wrongOrigin])
        }
        #expect(await rig.op.eject(rig.desk, rig.intent(.drop)) == .refused(rig.desk, .wrongOrigin))
        #expect(rig.exists(a) && rig.text(b) == "drop")

        let trashed = await rig.op.trash([a], expecting: [rig.key(a)], rig.intent(.dragToTrash))
        let record = try #require(trashed.undo)
        #expect(await rig.op.undo(record, rig.intent(.menuItem)).refusals == [.wrongOrigin])
        // The refused undo left the record open.
        #expect(await rig.op.undo(record, rig.intent(.undo)).refusals.isEmpty)
        #expect(rig.exists(a))
    }

    @Test("Undo takes only records this operator issued, once each; a stale intent leaves the record open")
    func recordRedemption() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let record = try #require(await rig.op.trash([a], expecting: [rig.key(a)], rig.intent()).undo)
        #expect(await rig.makeOperator().undo(record, rig.intent(.undo)).refusals == [.unknownRecord])
        #expect(await rig.op.undo(record, rig.intent(.undo, age: 60)).refusals == [.staleIntent])
        #expect(rig.trashNames == ["a.txt"])
        #expect(await rig.op.undo(record, rig.intent(.undo)).refusals.isEmpty)
        #expect(rig.exists(a))
        #expect(await rig.op.undo(record, rig.intent(.undo)).refusals == [.unknownRecord])
        #expect(rig.exists(a))
    }

    @Test("The public initializer refuses a trash folder inside the desk and trashes into one outside it")
    func publicInit() async throws {
        let rig = try FileRig()
        #expect(throws: SafetyGuard.Refusal.self) {
            try FileOperator(root: rig.desk, trash: .folder(rig.at(rig.desk, "Trash")), log: rig.log, sandboxRoots: [rig.temp.root])
        }
        #expect(rig.names(rig.desk).isEmpty)
        let folder = rig.state.appendingPathComponent("OtherTrash", isDirectory: true)
        let op = try FileOperator(root: rig.desk, trash: .folder(folder), log: rig.log, sandboxRoots: [rig.temp.root])
        let a = try rig.file(rig.desk, "a.txt")
        let result = await op.trash([a], expecting: [rig.key(a)], rig.intent())
        #expect(result.refusals.isEmpty)
        #expect(rig.names(folder) == ["a.txt"])
    }

    // MARK: Identity, not spelling

    @Test("A drop of the desk folder or a folder holding it is refused under any spelling (case, firmlink)",
          arguments: [ImportOp.copy, .move])
    func containsDesktopByIdentity(op: ImportOp) async throws {
        let rig = try FileRig()
        let outer = URL(fileURLWithPath: DesktopLocator.canonicalPath(try rig.temp.mkdir("Outer")), isDirectory: true)
        let desk = try rig.temp.mkdir("Outer/Desk")
        try rig.file(desk, "a.txt", "mine")
        let firmlink = "/System/Volumes/Data" + DesktopLocator.canonicalPath(rig.temp.root)
        let hasFirmlink = FileManager.default.fileExists(atPath: firmlink + "/Outer/Desk/a.txt")
        let fo = rig.makeOperator(
            root: desk, sandboxRoots: [rig.temp.root] + (hasFirmlink ? [URL(fileURLWithPath: firmlink)] : [])
        )
        var drops = [
            outer.deletingLastPathComponent().appendingPathComponent("OUTER", isDirectory: false),
            outer.appendingPathComponent("DESK", isDirectory: false),
            outer.appendingPathComponent("desk", isDirectory: false),
        ].filter { FileManager.default.fileExists(atPath: $0.path) } // case-insensitive volumes only
        if hasFirmlink {
            drops += [URL(fileURLWithPath: firmlink + "/Outer/Desk"), URL(fileURLWithPath: firmlink + "/Outer")]
        }
        try #require(!drops.isEmpty)
        let result = await fo.importItems(drops, op: op, rig.intent(.drop))
        #expect(result.outcomes == drops.map { .refused($0, .containsDesktop) })
        #expect(rig.names(desk) == ["a.txt"])
        #expect(rig.names(outer) == ["Desk"])

        // Another spelling of an item already on the desk is placement only.
        if hasFirmlink {
            let item = URL(fileURLWithPath: firmlink + "/Outer/Desk/A.TXT")
            let placed = await fo.importItems([item], op: op, rig.intent(.drop))
            #expect(placed.outcomes == [.unchanged(item)])
            #expect(placed.undo == nil)
            #expect(rig.names(desk) == ["a.txt"])
        }
    }

    // MARK: After the act

    @Test("An item swapped in between the check and the trash is put straight back and the trash refused")
    func swapBeforeTrash() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt", "old")
        let op = rig.makeOperator(trasher: SwapTrasher(inner: rig.trasher))
        let result = await op.trash([a], expecting: [rig.key(a)], rig.intent())
        #expect(result.outcomes == [.refused(a, .identityChanged)])
        #expect(result.undo == nil)
        #expect(rig.text(a) == "newer version")
        #expect(rig.trashNames.isEmpty)
        #expect(rig.log.entries().map(\.outcome) == ["refused: identity-changed"])
    }

    @Test("A drop source swapped right before the move goes back where it was and the drop is refused")
    func swapBeforeMoveIn() async throws {
        let rig = try FileRig()
        let source = try rig.file(rig.elsewhere, "a.txt", "original")
        let elsewhere = rig.elsewhere
        let once = Once()
        await rig.op.setHooks(.init(beforeRename: { _ in
            once {
                let save = elsewhere.appendingPathComponent(".sb-save")
                try? Data("impostor".utf8).write(to: save)
                _ = rename(save.path, source.path)
            }
        }))
        let result = await rig.op.importItems([source], op: .move, rig.intent(.drop))
        #expect(result.outcomes == [.refused(source, .identityChanged)])
        #expect(result.undo == nil)
        #expect(rig.names(rig.desk).isEmpty)
        #expect(rig.text(source) == "impostor")
    }

    @Test("Put Back of an item swapped inside the trash returns the impostor to the trash")
    func swapBeforePutBack() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt", "mine")
        let record = try #require(await rig.op.trash([a], expecting: [rig.key(a)], rig.intent()).undo)
        let trashFolder = rig.trasher.folder
        let once = Once()
        await rig.op.setHooks(.init(beforeRename: { _ in
            once {
                let save = trashFolder.appendingPathComponent(".sb-save")
                try? Data("impostor".utf8).write(to: save)
                _ = rename(save.path, trashFolder.appendingPathComponent("a.txt").path)
            }
        }))
        let undone = await rig.op.undo(record, rig.intent(.undo))
        #expect(undone.refusals == [.identityChanged])
        #expect(!rig.exists(a))
        #expect(rig.trashNames == ["a.txt"])
        #expect(rig.text(trashFolder.appendingPathComponent("a.txt")) == "impostor")
    }

    // MARK: Copies

    @Test("A copy is staged outside the desk folder; a failed one leaves nothing, even read-only folders and locked files")
    func stagingCleanup() async throws {
        let rig = try FileRig()
        let album = try rig.temp.mkdir("Elsewhere/Album")
        defer { unlockAll(rig.temp.root) } // also keeps the rig alive until then
        let ro = try rig.temp.mkdir("Elsewhere/Album/ro")
        try rig.file(ro, "inside.txt")
        let locked = try rig.file(album, "locked.txt", "locked")
        #expect(lchflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chmod(ro.path, 0o555) == 0)
        let staged = Recorder<URL>()
        let desk = rig.desk
        await rig.op.setHooks(.init(
            beforeRename: { destination in try? Data("planted".utf8).write(to: destination) },
            afterCopy: { url in
                staged.append(url)
                #expect(!DesktopLocator.isInsideDesktop(url, desktop: desk))
            }
        ))
        let result = await rig.op.importItems([album], op: .copy, rig.intent(.drop))
        #expect(result.outcomes == [.refused(album, .noFreeName)])
        let stagedCopy = try #require(staged.all.first)
        #expect(!FileManager.default.fileExists(atPath: stagedCopy.deletingLastPathComponent().path))
        #expect(rig.names(rig.desk).count == 100)
        #expect(!rig.names(rig.desk).contains { $0.hasPrefix(".") })
        #expect(rig.names(album) == ["locked.txt", "ro"])
    }

    @Test("A Finder-locked file dropped in lands as a locked copy; the source stays", arguments: [ImportOp.copy, .move])
    func lockedSource(op: ImportOp) async throws {
        let rig = try FileRig()
        let source = try rig.file(rig.elsewhere, "contract.pdf", "signed")
        defer { unlockAll(rig.temp.root) } // also keeps the rig alive until then
        #expect(lchflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        let result = await rig.op.importItems([source], op: op, rig.intent(.drop))
        let placed = rig.at(rig.desk, "contract.pdf")
        #expect(result.outcomes == [.copied(source, to: placed)])
        #expect(isLocked(placed))
        #expect(rig.text(placed) == "signed")
        #expect(isLocked(source) && rig.text(source) == "signed")
        #expect(rig.names(rig.desk) == ["contract.pdf"])
    }

    @Test("A copy reports each file and folder it starts")
    func copyProgress() async throws {
        let rig = try FileRig()
        let album = try rig.temp.mkdir("Elsewhere/Album")
        try rig.file(album, "a.jpg")
        try rig.file(album, "b.jpg")
        try rig.file(try rig.temp.mkdir("Elsewhere/Album/sub"), "c.jpg")
        let seen = Recorder<FileOperator.CopyProgress>()
        let result = await rig.op.importItems([album], op: .copy, rig.intent(.drop), progress: { seen.append($0) })
        #expect(result.outcomes == [.copied(album, to: rig.at(rig.desk, "Album"))])
        #expect(seen.all.map(\.items) == Array(1...5))
        #expect(seen.all.allSatisfy { $0.source == album })
    }

    @Test("A long copy runs off the actor: a trash issued meanwhile is served at once, not left to go stale")
    func copyDoesNotBlock() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let big = try rig.file(rig.elsewhere, "big.bin")
        let started = Latch(), release = Latch(), resumed = Latch()
        let drop = Task {
            await rig.op.importItems([big], op: .copy, rig.intent(.drop), progress: { _ in
                started.open()
                _ = release.wait(seconds: 30)
                resumed.open()
            })
        }
        #expect(await started.opened(within: 30))
        let trashed = await rig.op.trash([a], expecting: [rig.key(a)], rig.intent())
        let copyWasRunning = !resumed.isOpen
        release.open()
        let dropped = await drop.value
        #expect(copyWasRunning)
        #expect(trashed.refusals.isEmpty)
        #expect(dropped.outcomes == [.copied(big, to: rig.at(rig.desk, "big.bin"))])
    }

    @Test("Cancelling a drop stops its copy: the items left are refused as cancelled and nothing lands")
    func cancelledCopy() async throws {
        let rig = try FileRig()
        let album = try rig.temp.mkdir("Elsewhere/Album")
        for i in 0..<5 { try rig.file(album, "p\(i).jpg") }
        let other = try rig.file(rig.elsewhere, "other.txt")
        let started = Latch(), release = Latch()
        let drop = Task {
            await rig.op.importItems([album, other], op: .copy, rig.intent(.drop), progress: { _ in
                started.open()
                _ = release.wait(seconds: 30)
            })
        }
        #expect(await started.opened(within: 30))
        drop.cancel()
        release.open()
        let result = await drop.value
        #expect(result.outcomes == [.refused(album, .cancelled), .refused(other, .cancelled)])
        #expect(result.undo == nil)
        #expect(rig.names(rig.desk).isEmpty)
        #expect(rig.names(album).count == 5)
        #expect(rig.log.entries().map(\.outcome) == ["refused: cancelled", "refused: cancelled"])
    }

    // MARK: Eject

    @Test("Eject only targets a browsable volume the drive hub would eject, never the system's own volumes")
    func ejectableVolumes() {
        for path in [
            "/", "/System/Volumes/Data", "/System/Volumes/Preboot", "/System/Volumes/VM", "/System/Volumes/Update",
            "/System/Volumes/xarts", "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware", "/SYSTEM/VOLUMES/VM",
            "/dev", "/Volumes", NSTemporaryDirectory(),
        ] {
            #expect(!FileOperator.isEjectableVolume(URL(fileURLWithPath: path)), "\(path)")
        }
        typealias Facts = VolumeWatcher.Facts
        #expect(FileOperator.isEjectable(Facts(isInternal: false, isLocal: true, isRemovable: true, isEjectable: true)))
        #expect(FileOperator.isEjectable(Facts(isInternal: false, isLocal: true, isRemovable: false, isEjectable: true)))
        #expect(FileOperator.isEjectable(Facts(isInternal: nil, isLocal: false, isRemovable: false, isEjectable: false)))
        #expect(!FileOperator.isEjectable(Facts(isInternal: true, isLocal: true, isRemovable: false, isEjectable: false)))
        #expect(!FileOperator.isEjectable(
            Facts(isInternal: true, isLocal: true, isRemovable: false, isEjectable: true, isBrowsable: false)
        ))
        #expect(!FileOperator.isEjectable(
            Facts(isInternal: false, isLocal: true, isRemovable: true, isEjectable: true, isRoot: true)
        ))
    }
}

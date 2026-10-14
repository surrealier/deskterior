import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// Clears every lock and restores write permission under `url`, so TempDesk can remove it.
private func release(_ url: URL) {
    _ = lchflags(url.path, 0)
    chmod(url.path, 0o755)
    let e = FileManager.default.enumerator(atPath: url.path)
    while let rel = e?.nextObject() as? String {
        let p = url.appendingPathComponent(rel).path
        _ = lchflags(p, 0)
        var st = stat()
        if lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { chmod(p, 0o755) }
    }
}

private func lockFlag(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0 && st.st_flags & UInt32(UF_IMMUTABLE) != 0
}

/// Pre-release hardening of the file actions (wave 6, Errata 25): a locked item is never duplicated by a move, a move
/// macOS refused that came in as a copy says so, a copy is reported only once the item at its destination is the copy
/// it wrote, and leftovers of an interrupted copy are found, never touched, and trashed only on request.
@Suite("FileOperator hardening (wave 6)")
struct HardeningFileTests {
    // MARK: Locked items

    @Test("A move of a Finder-locked item is refused as locked: nothing lands and the source stays where it was")
    func lockedMove() async throws {
        let rig = try FileRig()
        let source = try rig.file(rig.elsewhere, "contract.pdf", "signed")
        defer { release(rig.temp.root) }
        #expect(lchflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        let result = await rig.op.importItems([source], op: .move, rig.intent(.drop))
        #expect(result.outcomes == [.refused(source, .locked)])
        #expect(result.undo == nil)
        #expect(rig.names(rig.desk).isEmpty, "no silent duplicate")
        #expect(lockFlag(source) && rig.text(source) == "signed")
        #expect(rig.log.entries().map(\.outcome) == ["refused: locked"])
        let report = FileReport(import: result, undo: nil, requested: .move)
        #expect(report.problems == [.locked] && report.toast == .fileLocked && report.placed.isEmpty)
    }

    @Test("A move out of a locked folder is refused as locked too; nothing in it moves or is copied")
    func lockedFolder() async throws {
        let rig = try FileRig()
        let folder = try rig.temp.mkdir("Elsewhere/Signed")
        let source = try rig.file(folder, "deed.txt", "x")
        defer { release(rig.temp.root) }
        #expect(lchflags(folder.path, UInt32(UF_IMMUTABLE)) == 0)
        let result = await rig.op.importItems([source], op: .move, rig.intent(.drop))
        #expect(result.outcomes == [.refused(source, .locked)])
        #expect(rig.names(rig.desk).isEmpty)
        #expect(rig.names(folder) == ["deed.txt"])
    }

    @Test("A move macOS refuses for another reason comes in as a copy, and the report says the original stayed")
    func refusedMoveCopies() async throws {
        let rig = try FileRig()
        let folder = try rig.temp.mkdir("Elsewhere/ReadOnly")
        let source = try rig.file(folder, "a.txt", "keep")
        defer { release(rig.temp.root) }
        #expect(chmod(folder.path, 0o555) == 0)
        let result = await rig.op.importItems([source], op: .move, rig.intent(.drop))
        let placed = rig.at(rig.desk, "a.txt")
        #expect(result.outcomes == [.copied(source, to: placed)])
        #expect(rig.text(placed) == "keep" && rig.text(source) == "keep")
        #expect(FileReport(import: result, undo: nil, requested: .move).toast == .copiedInstead)
        #expect(FileReport(import: result, undo: nil, requested: .copy).toast == nil, "an asked-for copy is no news")
    }

    // MARK: A copy's landing

    @Test("An item swapped in right after a copy's final rename is left alone, and the copy is not reported as landed")
    func swappedAfterPlace() async throws {
        let rig = try FileRig()
        let source = try rig.file(rig.elsewhere, "a.txt", "ours")
        let aside = rig.at(rig.elsewhere, "moved-away.txt")
        await rig.op.setHooks(.init(afterPlace: { placed in
            _ = rename(placed.path, aside.path)
            try? Data("theirs".utf8).write(to: placed)
        }))
        let result = await rig.op.importItems([source], op: .copy, rig.intent(.drop))
        #expect(result.outcomes == [.refused(source, .identityChanged)])
        #expect(result.undo == nil, "nothing to take back: what is there is not ours")
        #expect(rig.text(rig.at(rig.desk, "a.txt")) == "theirs", "never moved or removed")
        #expect(rig.text(source) == "ours")
    }

    @Test("A copy whose file changed size after it landed is not reported as landed; the file is left as it is")
    func resizedAfterPlace() async throws {
        let rig = try FileRig()
        let source = try rig.file(rig.elsewhere, "log.txt", "12345")
        await rig.op.setHooks(.init(afterPlace: { placed in
            if let h = try? FileHandle(forWritingTo: placed) {
                h.seekToEndOfFile()
                h.write(Data("678".utf8))
                try? h.close()
            }
        }))
        let result = await rig.op.importItems([source], op: .copy, rig.intent(.drop))
        #expect(result.outcomes == [.refused(source, .identityChanged)])
        #expect(rig.text(rig.at(rig.desk, "log.txt")) == "12345678")
    }

    @Test("A copy that lands intact is reported with an undo step, from either staging place", arguments: [false, true])
    func intactCopy(stageInDesk: Bool) async throws {
        let rig = try FileRig()
        let album = try rig.temp.mkdir("Elsewhere/Album")
        try rig.file(album, "p.jpg", "pixels")
        let staged = Recorder<URL>()
        await rig.op.setHooks(.init(afterCopy: { staged.append($0) }, stageInDesk: stageInDesk))
        let result = await rig.op.importItems([album], op: .copy, rig.intent(.drop))
        #expect(result.outcomes == [.copied(album, to: rig.at(rig.desk, "Album"))])
        #expect(result.undo != nil)
        let stagedIn = try #require(staged.all.first).deletingLastPathComponent()
        #expect(DesktopLocator.isInsideDesktop(stagedIn, desktop: rig.desk) == stageInDesk)
        #expect(rig.names(rig.desk) == ["Album"], "the staging folder is gone")
        #expect(PartialCopies.find(in: rig.desk).isEmpty)
    }

    // MARK: Leftovers of an interrupted copy

    @Test("Leftovers are found at the desk folder's top level only, by their exact name, and nothing is changed")
    func findLeftovers() throws {
        let rig = try FileRig()
        let id = UUID().uuidString
        let leftover = try rig.temp.mkdir("Desk/.deskterior-partial-\(id)")
        try rig.file(leftover, "half.mov", "half")
        try rig.temp.mkdir("Desk/.deskterior-partial-not-a-uuid")
        try rig.file(rig.desk, ".deskterior-partial-\(UUID().uuidString)", "a file, not ours")
        try rig.temp.mkdir("Desk/Folder/.deskterior-partial-\(UUID().uuidString)")
        let elsewhere = try rig.temp.mkdir("Elsewhere/.deskterior-partial-\(UUID().uuidString)")
        #expect(symlink(elsewhere.path, rig.desk.appendingPathComponent(".deskterior-partial-\(UUID().uuidString)").path) == 0)
        let before = rig.names(rig.desk)
        let inode = rig.inode(leftover)
        let found = PartialCopies.find(in: rig.desk)
        #expect(found.map(\.url.lastPathComponent) == [".deskterior-partial-\(id)"])
        #expect(found.first?.key == rig.key(leftover))
        #expect(found.first?.contents.map(\.lastPathComponent) == ["half.mov"])
        #expect(rig.names(rig.desk) == before && rig.inode(leftover) == inode && rig.text(leftover.appendingPathComponent("half.mov")) == "half")
        #expect(PartialCopies.isLeftoverName(".deskterior-partial-\(id)"))
        #expect(!PartialCopies.isLeftoverName(".deskterior-partial-") && !PartialCopies.isLeftoverName("deskterior-partial-\(id)"))
    }

    @Test("A leftover goes to the trash only on a menu intent, and only while it is the folder that was found")
    func trashLeftover() async throws {
        let rig = try FileRig()
        let leftover = try rig.temp.mkdir("Desk/.deskterior-partial-\(UUID().uuidString)")
        try rig.file(leftover, "half.mov")
        let item = try #require(PartialCopies.find(in: rig.desk).first)
        let fromDrop = await rig.op.trash([item.url], expecting: [item.key], rig.intent(.drop))
        #expect(fromDrop.refusals == [.wrongOrigin] && rig.exists(leftover))
        let stale = PartialCopies.Leftover(url: item.url, key: TokenKey(volume: item.key.volume, inode: item.key.inode + 1),
                                           contents: [])
        let changed = await rig.op.trash([stale.url], expecting: [stale.key], rig.intent())
        #expect(changed.refusals == [.identityChanged] && rig.exists(leftover))
        let trashed = await rig.op.trash([item.url], expecting: [item.key], rig.intent())
        #expect(trashed.refusals.isEmpty)
        #expect(!rig.exists(leftover) && rig.trashNames == [leftover.lastPathComponent])
        #expect(PartialCopies.find(in: rig.desk).isEmpty)
    }

    @Test("A copy staging in the desk folder right now is not a leftover the trash may take")
    func inFlightStaging() async throws {
        let rig = try FileRig()
        let big = try rig.file(rig.elsewhere, "big.bin", "data")
        await rig.op.setHooks(.init(stageInDesk: true))
        let started = Latch(), release = Latch()
        let drop = Task {
            await rig.op.importItems([big], op: .copy, rig.intent(.drop), progress: { _ in
                started.open()
                _ = release.wait(seconds: 30)
            })
        }
        #expect(await started.opened(within: 30))
        let staging = try #require(PartialCopies.find(in: rig.desk).first, "the copy stages in the desk folder")
        let refused = await rig.op.trash([staging.url], expecting: [staging.key], rig.intent())
        release.open()
        let dropped = await drop.value
        #expect(refused.refusals == [.failed(Int(EBUSY))])
        #expect(dropped.outcomes == [.copied(big, to: rig.at(rig.desk, "big.bin"))])
        #expect(rig.names(rig.desk) == ["big.bin"] && rig.trashNames.isEmpty)
    }
}

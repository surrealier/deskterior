import DeskCore
import DeskFiles
import DeskScene
import Foundation
import Metal
import Testing
@testable import DeskteriorApp

/// A solid photo (another photo than `FramePhoto.sample`).
let solidFramePhoto = FramePhoto(PixelBuffer(width: 26, height: 34, fill: Ink.blue3.color))!

/// `frame.json`'s saver (Erratum 33): nothing before `arm()`, debounced, "no photo" written as a document without
/// one, stopped by a newer file, and scheduled by the store only for dispatched changes. Scratch state folders only.
@Suite("Frame saver")
struct FrameSaverTests {
    func frameFile(_ dir: URL) -> URL { dir.appendingPathComponent(StateStore.frameFileName) }

    @Test("Nothing is written before arm(): not a scheduled photo, not a flushed one")
    func notBeforeArm() throws {
        let temp = try AppTemp()
        let dir = try temp.dir("State")
        let saver = FrameSaver(store: try StateStore(directory: dir, mirrored: try temp.dir("Desk")), delay: 0.01,
                               maxWait: 0.05)
        saver.schedule(FramePhoto.sample)
        saver.schedule(nil)
        saver.flush()
        Thread.sleep(forTimeInterval: 0.1)
        saver.flush()
        #expect(!saver.isArmed && saver.saveCount == 0)
        #expect(!FileManager.default.fileExists(atPath: frameFile(dir).path))
    }

    @Test("Once armed, a stream of changes is one debounced write, and a flush writes what is pending at once")
    func debounced() async throws {
        let temp = try AppTemp()
        let store = try StateStore(directory: try temp.dir("State"), mirrored: try temp.dir("Desk"))
        // A debounce no run outlasts: the burst is one pending photo, the last, and one write.
        let saver = FrameSaver(store: store, delay: 600, maxWait: 600)
        saver.arm()
        for photo in [FramePhoto.sample, nil, solidFramePhoto, nil, FramePhoto.sample] { saver.schedule(photo) }
        #expect(saver.saveCount == 0, "nothing before the pause is over")
        saver.flush()
        #expect(saver.saveCount == 1, "five changes in a row, one write")
        #expect(store.loadFrame().photo == FramePhoto.sample)
        saver.flush()
        #expect(saver.saveCount == 1, "nothing pending: nothing to write")
        saver.schedule(solidFramePhoto)
        saver.flush()
        #expect(saver.saveCount == 2 && store.loadFrame().photo == solidFramePhoto)
        // With nothing flushing, the debounce writes by itself once the pause is over (the last of a burst in the end).
        let timed = FrameSaver(store: store, delay: 0.05, maxWait: 1)
        timed.arm()
        for photo in [solidFramePhoto, nil, FramePhoto.sample] { timed.schedule(photo) }
        #expect(await eventually { timed.saveCount >= 1 && store.loadFrame().photo == FramePhoto.sample })
    }

    @Test("schedule(nil) writes frame.json without a photo: the frame was emptied, and it loads as none")
    func noPhoto() throws {
        let temp = try AppTemp()
        let dir = try temp.dir("State")
        let store = try StateStore(directory: dir, mirrored: try temp.dir("Desk"))
        let saver = FrameSaver(store: store, delay: 600, maxWait: 600)
        saver.arm()
        saver.schedule(FramePhoto.sample)
        saver.flush()
        #expect(store.loadFrame().photo == FramePhoto.sample)
        saver.schedule(nil)
        saver.flush()
        #expect(saver.saveCount == 2)
        let text = try String(contentsOf: frameFile(dir), encoding: .utf8)
        #expect(text.contains("\"schema\"") && !text.contains("\"photo\""))
        let loaded = store.loadFrame()
        #expect(loaded.photo == nil && loaded.writable)
    }

    @Test("A frame.json that a newer Deskterior wrote mid-session stops the saves: it is never written over")
    func newerFileDisarms() throws {
        let temp = try AppTemp()
        let dir = try temp.dir("State")
        let store = try StateStore(directory: dir, mirrored: try temp.dir("Desk"))
        let refusals = CallCount()
        let saver = FrameSaver(store: store, onRefusal: { refusals.bump() })
        saver.arm()
        saver.schedule(FramePhoto.sample)
        saver.flush()
        #expect(saver.saveCount == 1)
        let future = Data("{\"schema\": 2, \"photo\": null}".utf8)
        try future.write(to: frameFile(dir))
        saver.schedule(solidFramePhoto)
        saver.flush()
        #expect(!saver.isArmed && saver.saveCount == 1)
        saver.schedule(nil)
        saver.flush()
        #expect(try Data(contentsOf: frameFile(dir)) == future)
        #expect(refusals.value == 1, "the user is told once (the session shows a toast)")
    }

    @Test("The store schedules a dispatched hang (undo included); a replace (a load) never")
    @MainActor
    func storeSchedules() throws {
        let temp = try AppTemp()
        let store = try StateStore(directory: try temp.dir("State"), mirrored: try temp.dir("Desk"))
        let saver = FrameSaver(store: store, delay: 600, maxWait: 600)
        saver.arm()
        let model = Store(frameSaver: saver)
        #expect(model.frameSaver === saver)
        model.replace { $0.framePhoto = FramePhoto.sample }
        model.flush()
        #expect(saver.saveCount == 0, "a replace is a load: not saved")
        model.replace { $0.framePhoto = nil }
        model.dispatch(.hangPhoto(FramePhoto.sample))
        #expect(model.state.framePhoto == FramePhoto.sample)
        model.flush()
        #expect(saver.saveCount == 1 && store.loadFrame().photo == FramePhoto.sample)
        model.dispatch(.hangPhoto(FramePhoto.sample))  // the same photo again: no change, nothing to save
        model.flush()
        #expect(saver.saveCount == 1)
        model.dispatch(.undo)
        #expect(model.state.framePhoto == nil)
        model.flush()
        #expect(saver.saveCount == 2 && store.loadFrame().photo == nil, "an undo is saved too")
    }
}

/// The load and save order of `frame.json` (Erratum 33), as memos.json's: it loads after every desk load, the saver arms
/// only after it, a stop flushes, a folder switch keeps it, and a newer file is never written; through
/// `StateStore.loadFrame` / `saveFrame` in a temporary state folder.
@Suite("Frame across sessions", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct FrameSessionSaverTests {
    @Test("A session loads frame.json as it starts, before anything can save; a stop flushes a pending change")
    func loadThenFlushOnStop() throws {
        let rig = try MemoRig()
        try rig.stateStore.saveFrame(FramePhoto.sample)
        let session = try rig.session()
        let saver = try #require(session.store.frameSaver)
        #expect(session.store.state.framePhoto == nil && !saver.isArmed, "nothing is loaded or armed before start")
        session.start()
        #expect(session.store.state.framePhoto == FramePhoto.sample)
        #expect(saver.isArmed)
        #expect(session.host.scene.roomState?.framePhoto == FramePhoto.sample.image, "the room shows it")
        // A change on its way to disk is written as the session stops, without waiting for the debounce.
        session.store.dispatch(.hangPhoto(solidFramePhoto))
        session.stop()
        #expect(saver.saveCount == 1)
        #expect(try rig.stateStore.loadFrame().photo == solidFramePhoto)
    }

    @Test("A folder switch (a new session on another folder) sees the same photo and never writes an empty one")
    func folderSwitch() throws {
        let rig = try MemoRig()
        try rig.stateStore.saveFrame(FramePhoto.sample)
        let old = try rig.session("Desk")
        old.start()
        old.store.dispatch(.hangPhoto(solidFramePhoto))
        // AppDelegate.switchFolder: the old session stops (and saves), then the new one is made and started.
        old.stop()
        let new = try rig.session("Other")
        #expect(new.store.state.framePhoto == nil)
        new.store.flush()  // an unarmed saver writes nothing, so "no photo" never reaches the file
        #expect(try rig.stateStore.loadFrame().photo == solidFramePhoto)
        new.start()
        #expect(new.store.state.framePhoto == solidFramePhoto)
        new.stop()
        #expect(new.store.frameSaver?.saveCount == 0, "nothing changed in the new session")
        #expect(try rig.stateStore.loadFrame().photo == solidFramePhoto)
    }

    @Test("A frame.json from a newer Deskterior: the session says the photo is not saved, and never writes it")
    func newerFileToast() throws {
        let rig = try MemoRig()
        let file = rig.state.appendingPathComponent(StateStore.frameFileName)
        let future = Data("{\"schema\": 2, \"photo\": null}".utf8)
        try future.write(to: file)
        let session = try rig.session()
        session.start()
        #expect(session.host.scene.toastShown == .frameNotSaved)
        let saver = try #require(session.store.frameSaver)
        #expect(!saver.isArmed)
        #expect(session.store.state.framePhoto == nil)
        session.store.dispatch(.hangPhoto(FramePhoto.sample))
        #expect(session.store.state.framePhoto == FramePhoto.sample, "it still hangs, for this session")
        session.stop()
        #expect(saver.saveCount == 0)
        #expect(try Data(contentsOf: file) == future)
    }
}

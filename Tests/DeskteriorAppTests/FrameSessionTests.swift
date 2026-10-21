import AppKit
import DeskCore
import DeskFiles
import DeskPixels
import Foundation
import Metal
import Testing
@testable import DeskScene
@testable import DeskteriorApp

/// The picture frame through a real `DeskSession` (Erratum 33), on a scratch desk the mirror really scans (so tokens
/// carry their files' real inodes): Hang in Picture Frame reads the token's file once and journals one hang, a Finder
/// drop on the frame goes through the session's own wiring and imports nothing, a hang under a desktop widget is kept
/// and toasted, and a desk not connected says so. `p.png` and `t.txt` lie on the desk, `q.png` outside it.
@Suite("Picture frame in a session", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct FrameSessionTests {
    /// A connected session over `Desk/p.png`, `Desk/t.txt` (and `Elsewhere/q.png` outside the desk), started and
    /// scanned; `pKey` and `tKey` are the two tokens.
    struct Started {
        let rig: SessionRig
        let session: DeskSession
        let pKey: TokenKey
        let tKey: TokenKey
        let p: URL
        let q: URL
    }

    static func start() async throws -> Started {
        let rig = try SessionRig(connected: true)
        let p = try rig.temp.png("Desk/p.png")
        try rig.temp.file("Desk/t.txt", "a note")
        let q = try rig.temp.png("Elsewhere/q.png", .walnut4, .blue2)
        let session = rig.session
        session.start()
        func key(_ name: String) -> TokenKey? {
            let s = session.store.state
            return s.tokens.sortedKeys.first { s.tokens.meta(of: $0)?.name == name }
        }
        try #require(await eventually {
            session.store.state.access == .connected && key("p.png") != nil && key("t.txt") != nil
        })
        return Started(rig: rig, session: session, pKey: try #require(key("p.png")), tKey: try #require(key("t.txt")),
                       p: p, q: q)
    }

    static func centre(_ r: ArtRect) -> SIMD2<Float> { SIMD2(Float(r.midX) + 0.5, Float(r.midY) + 0.5) }

    @Test("Hang in Picture Frame reads the token's file once: one journaled hang, the file untouched; refusals say why")
    func hangToken() async throws {
        let t = try await Self.start()
        let session = t.session
        defer { session.stop() }
        let stamp = try #require(frameFileStamp(t.p))
        #expect(t.pKey.inode == stamp.inode, "the scan's key is the file's inode")
        let expected = try #require(FramePixelator.photo(contentsOf: t.p))
        session.hangPhoto(token: t.pKey)
        try #require(await eventually { session.store.state.framePhoto != nil })
        #expect(session.store.state.framePhoto == expected)
        #expect(session.store.undoLabel == "Hang Photo")
        let after = try #require(frameFileStamp(t.p))
        #expect(after.inode == stamp.inode && after.size == stamp.size && after.mtime == stamp.mtime)
        #expect(session.effects.fileLog.isEmpty && (session.files?.finished ?? 0) == 0)
        // The text token: not a photo, nothing read; the photo stays.
        session.hangPhoto(token: t.tKey)
        #expect(session.host.scene.toastShown == .notAPhoto)
        #expect(session.store.state.framePhoto == expected)
        // A key that is not on the desk (gone since its menu opened).
        session.hangPhoto(token: TokenKey(volume: "v", inode: 999))
        #expect(session.host.scene.toastShown == .fileGone)
        #expect(session.framePhotos.isIdle && session.store.state.framePhoto == expected)
    }

    @Test("A Finder drop on the frame through the session's own wiring: hung, the file still where it was, nothing imported")
    func finderDropOnFrame() async throws {
        let t = try await Self.start()
        let session = t.session
        defer { session.stop() }
        let stamp = try #require(frameFileStamp(t.q))
        let listing = t.rig.names(t.rig.desk)
        let frame = try #require(session.host.scene.pictureFrameRect)
        #expect(session.dropIn.drop([t.q], at: Self.centre(frame), copy: false))
        try #require(await eventually { session.store.state.framePhoto != nil })
        #expect(session.store.state.framePhoto == FramePixelator.photo(contentsOf: t.q))
        let after = try #require(frameFileStamp(t.q))
        #expect(after.inode == stamp.inode && after.size == stamp.size)
        #expect(t.rig.names(t.rig.desk) == listing, "nothing came onto the desk")
        #expect((session.files?.finished ?? 0) == 0 && session.effects.fileLog.isEmpty)
        // A folder is not a photo (any guard says so).
        let refused = try t.rig.temp.dir("Elsewhere/Album")
        #expect(!session.dropIn.drop([refused], at: Self.centre(frame), copy: false))
        #expect(session.host.scene.toastShown == .notAPhoto)
        // The session's drop asks its loader, whose guard (a development run: the real Desktop) answers by spelling
        // before any lookup: the guard folder itself is refused as unreadable, where the unguarded default would look
        // it up and say "not a photo" (a folder). Nothing in it is named until that holds.
        let guarded = try #require(session.framePhotos.realDesktop, "a windowed session refuses the real Desktop")
        #expect(!session.dropIn.drop([guarded], at: Self.centre(frame), copy: false))
        try #require(session.host.scene.toastShown == .photoUnreadable)
        let inside = guarded.appendingPathComponent("deskterior-test-\(UUID().uuidString).png")
        #expect(session.dropIn.photoRefusal(inside) == .photoUnreadable)
        #expect(session.store.state.framePhoto == FramePixelator.photo(contentsOf: t.q), "the photo stays")
    }

    @Test("A hang while a desktop widget covers the frame is kept, toasted, and shown once the frame is uncovered")
    func coveredFrame() async throws {
        let t = try await Self.start()
        let session = t.session
        defer { session.stop() }
        let scene = session.host.scene
        let frameRect = try #require(scene.pictureFrameRect)
        scene.avoidRects = [frameRect]
        try #require(scene.pictureFrameRect == nil)
        session.hangPhoto(token: t.pKey)
        try #require(await eventually { session.store.state.framePhoto != nil })
        #expect(scene.toastShown == .widgetsOverlap)
        scene.avoidRects = []
        let back = try #require(scene.pictureFrameRect)
        let photo = try #require(session.store.state.framePhoto)
        let placed = try #require(scene.room?.elements.first { $0.id == "frame" })
        #expect(placed.placements.map(\.image) == [DecorArt.frame(back.size, photo: photo.image).image])
        #expect(scene.roomState?.framePhoto == photo.image)
    }

    @Test("With the desk not connected, Hang in Picture Frame says the files are unavailable")
    func disconnected() async throws {
        let t = try await Self.start()
        let session = t.session
        defer { session.stop() }
        session.store.replace { $0.access = .notConnected }
        session.hangPhoto(token: t.pKey)
        #expect(session.host.scene.toastShown == .filesUnavailable)
        #expect(session.framePhotos.isIdle && session.store.state.framePhoto == nil)
    }
}

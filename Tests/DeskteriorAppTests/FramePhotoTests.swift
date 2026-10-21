import DeskCore
import DeskFiles
import DeskPixels
import Foundation
import Testing
@testable import DeskteriorApp

extension AppTemp {
    /// A real PNG (40×30, `left` beside `right`) written with `PNGCodec.encode`, for the picture frame's tests.
    @discardableResult
    func png(_ path: String, _ left: Ink = .blue3, _ right: Ink = .red3) throws -> URL {
        var b = PixelBuffer(width: 40, height: 30, fill: left.color)
        for y in 0..<30 { for x in 20..<40 { b[x, y] = right.color } }
        let u = root.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PNGCodec.encode(b).write(to: u)
        return u
    }
}

/// An item's inode, size and modification time (`lstat`): a photo that is only read keeps all three.
func frameFileStamp(_ url: URL) -> (inode: UInt64, size: Int64, mtime: Int)? {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return nil }
    return (UInt64(st.st_ino), Int64(st.st_size), st.st_mtimespec.tv_sec * 1_000_000_000 + st.st_mtimespec.tv_nsec)
}

/// The picture frame's loader (Erratum 33): what it refuses without reading the contents, the real-Desktop guard
/// before anything is looked up (a temporary folder stands for the real Desktop), the inode check, and only the
/// latest of two loads delivered. Scratch folders only; no scene.
@Suite("Frame photo loader")
@MainActor
struct FramePhotoTests {
    @Test("Refused unread: not a photo, a folder, a link, gone, not a file URL, too large; a PNG may be read")
    func refusals() throws {
        let temp = try AppTemp()
        let png = try temp.png("Pics/a.png")
        let txt = try temp.file("Pics/notes.txt")
        let folder = try temp.dir("Pics/Album")
        let link = temp.root.appendingPathComponent("Pics/link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: png)
        let gone = temp.root.appendingPathComponent("Pics/gone.png")
        func refusal(_ u: URL, maxBytes: Int = ImageThumbnail.maxSourceBytes) -> ToastKey? {
            FramePhotoLoader.refusal(u, realDesktop: nil, maxBytes: maxBytes)
        }
        #expect(refusal(png) == nil)
        #expect(refusal(txt) == .notAPhoto)
        #expect(refusal(folder) == .notAPhoto)
        #expect(refusal(link) == .notAPhoto, "a symbolic link is refused, not followed")
        #expect(refusal(gone) == .photoUnreadable)
        #expect(refusal(URL(string: "https://example.com/a.png")!) == .notAPhoto)
        #expect(refusal(png, maxBytes: 10) == .photoUnreadable, "refused by its size alone")
        // The loader's own guard is nil here (desk mode): the same answers.
        #expect(FramePhotoLoader(realDesktop: nil).refusal(png) == nil)
        #expect(FramePhotoLoader(realDesktop: nil).refusal(txt) == .notAPhoto)
    }

    @Test("Inside the (stand-in) real Desktop a photo is refused first, by its spelling; outside it is read")
    func realDesktopGuard() throws {
        let temp = try AppTemp()
        let desktop = try temp.dir("D")
        let inside = try temp.png("D/a.png")
        let outside = try temp.png("Elsewhere/b.png")
        let folder = try temp.dir("D/Album")
        #expect(FramePhotoLoader.read(inside, inode: nil, realDesktop: desktop) == .refused(.photoUnreadable))
        guard case let .photo(photo) = FramePhotoLoader.read(inside, inode: nil, realDesktop: nil) else {
            Issue.record("a real PNG with no guard is read")
            return
        }
        #expect(photo.image.size == FramePhoto.size)
        // The guard comes before any resource value: a folder inside is refused as unreadable, not as no photo.
        #expect(FramePhotoLoader.refusal(folder, realDesktop: desktop) == .photoUnreadable)
        #expect(FramePhotoLoader.refusal(folder, realDesktop: nil) == .notAPhoto)
        if case .photo = FramePhotoLoader.read(outside, inode: nil, realDesktop: desktop) {} else {
            Issue.record("a PNG outside the guarded folder is read")
        }
        let guarded = FramePhotoLoader(realDesktop: desktop)
        #expect(guarded.refusal(inside) == .photoUnreadable && guarded.refusal(outside) == nil)
        #expect(guarded.realDesktop == desktop)
    }

    @Test("A file that is no image is unreadable; a token's photo must still be the same inode")
    func read() throws {
        let temp = try AppTemp()
        let fake = try temp.file("Pics/x.png", "not a picture at all")
        #expect(FramePhotoLoader.read(fake, inode: nil, realDesktop: nil) == .refused(.photoUnreadable))
        let png = try temp.png("Pics/a.png")
        let stamp = try #require(frameFileStamp(png))
        let expected = try #require(FramePixelator.photo(contentsOf: png))
        #expect(FramePhotoLoader.read(png, inode: stamp.inode, realDesktop: nil) == .photo(expected))
        #expect(FramePhotoLoader.read(png, inode: stamp.inode &+ 1, realDesktop: nil) == .refused(.photoUnreadable))
        #expect(frameFileStamp(png)?.inode == stamp.inode && frameFileStamp(png)?.size == stamp.size, "only read")
    }

    @Test("Two loads back to back: only the second is delivered, and idle comes only after both")
    func latestWins() async throws {
        let temp = try AppTemp()
        let a = try temp.png("Pics/a.png", .blue3, .blue3)
        let b = try temp.png("Pics/b.png", .red3, .walnut4)
        let photoB = try #require(FramePixelator.photo(contentsOf: b))
        #expect(FramePixelator.photo(contentsOf: a) != photoB)
        let loader = FramePhotoLoader(realDesktop: nil)
        #expect(loader.isIdle)
        var first = 0
        var second: [FramePhotoLoader.Outcome] = []
        loader.load(a) { _ in first += 1 }
        loader.load(b) { second.append($0) }
        #expect(loader.inFlight == 2 && !loader.isIdle)
        try #require(await eventually { loader.isIdle })
        #expect(first == 0, "a newer load started: the first is never delivered")
        #expect(second == [.photo(photoB)])
    }
}

import AppKit
import DeskCore
import DeskFiles
import Foundation
import Metal
import Testing
@testable import DeskScene
@testable import DeskteriorApp

/// A file drag as AppKit hands one to a destination (a copy of AliasAppTests' `MockDrag`): its pasteboard, the
/// source's operation mask and a sequence number.
@MainActor
private final class FrameDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation
    let draggingSequenceNumber: Int
    /// Where the drag is, in the destination window's coordinates.
    let draggingLocation: NSPoint

    init(_ urls: [URL], mask: NSDragOperation, sequence: Int, location: NSPoint = .zero) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("frame-test-\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
        draggingSourceOperationMask = mask
        draggingSequenceNumber = sequence
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// Finder drops on the picture frame (Erratum 33), on the desk and on another display's wall: every file drag over the
/// frame is answered without a move (even one that will be refused), a taken drop only reads one photo and never
/// becomes `requestDropIn`, a refused one bonks with why, and the drop goes where the drag's last answer said.
@Suite("Picture frame drops", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct FrameDropTests {
    /// The canvas point at the middle of `r` (on the print's pixels).
    static func centre(_ r: ArtRect) -> SIMD2<Float> { SIMD2(Float(r.midX) + 0.5, Float(r.midY) + 0.5) }

    /// The desk's picture frame centre, and a monitor cell that takes a drop (the rig connected).
    static func points(_ rig: AppRig) throws -> (frame: SIMD2<Float>, cell: SIMD2<Float>) {
        let frame = try #require(rig.host.scene.pictureFrameRect)
        let r = try #require(rig.host.scene.screen).cellRect(5, 2)
        return (centre(frame), SIMD2(Float(r.midX) + 0.5, Float(r.midY) + 0.5))
    }

    @Test("Over the frame: a link, else a copy, else a generic drop, never a move; refusals are answered too")
    func dragAnswers() throws {
        let rig = try AppRig()
        let png = try rig.temp.png("Elsewhere/a.png")
        let png2 = try rig.temp.png("Elsewhere/b.png")
        let txt = try rig.temp.file("Elsewhere/notes.txt")
        for connected in [false, true] {
            if connected {
                rig.connect()
                rig.host.scene.apply(rig.store.state)
                // A monitor cell still answers as before, and brackets its cell; the frame clears the bracket.
                let (_, cell) = try Self.points(rig)
                #expect(rig.dropIn.dragged([txt], at: cell, copy: false, drag: 20) == .move)
                #expect(rig.host.scene.screen?.dropTarget != nil)
            }
            let (frame, _) = try Self.points(rig)
            let every = DropKeys(mode: .standard, mask: .every)
            #expect(rig.dropIn.dragged([png], at: frame, copy: false, drag: 1, keys: every) == .link, "\(connected)")
            #expect(rig.host.scene.screen?.dropTarget == nil, "no cell bracketed over the frame")
            #expect(rig.dropIn.dragged([png], at: frame, copy: false, drag: 2, keys: DropKeys(mask: [.copy])) == .copy)
            #expect(rig.dropIn.dragged([png], at: frame, copy: false, drag: 3, keys: DropKeys(mask: [.generic])) == .generic)
            #expect(rig.dropIn.dragged([png], at: frame, copy: false, drag: 4, keys: DropKeys(mask: [.move])) == [],
                    "a move-only source is told nothing")
            #expect(rig.dropIn.dragged([png], at: frame, copy: false, drag: 5, keys: DropKeys(mode: .move)) == .link,
                    "⌘ held: still never a move over the frame")
            #expect(rig.dropIn.dragged([txt], at: frame, copy: false, drag: 6) == .link, "refused, but answered")
            #expect(rig.dropIn.dragged([png, png2], at: frame, copy: false, drag: 7) == .link)
            #expect(rig.dropIn.dragged([], at: frame, copy: false, drag: 8) == [])
            #expect(rig.host.scene.screen?.dropTarget == nil)
        }
        rig.dropIn.dragEnded()
        #expect(rig.store.dispatchCount == 0 && rig.effects.fileLog.isEmpty)
    }

    @Test("A photo dropped on the frame is only read: no requestDropIn, the file stays as it was; connected or not")
    func dropHangsWithoutImport() throws {
        let rig = try AppRig()
        rig.connect()
        rig.host.scene.apply(rig.store.state)
        var got: [URL] = []
        rig.dropIn.hangPhoto = { got.append($0) }
        let png = try rig.temp.png("Elsewhere/a.png")
        let stamp = try #require(frameFileStamp(png))
        let (frame, _) = try Self.points(rig)
        let dispatched = rig.store.dispatchCount
        #expect(rig.dropIn.drop([png], at: frame, copy: false))
        #expect(got == [png])
        #expect(rig.store.dispatchCount == dispatched, "no requestDropIn")
        #expect(rig.effects.fileLog.isEmpty && rig.files.inFlight == 0 && rig.files.finished == 0)
        #expect(rig.names(rig.desk).isEmpty, "nothing imported")
        let after = try #require(frameFileStamp(png))
        #expect(after.inode == stamp.inode && after.size == stamp.size && after.mtime == stamp.mtime)
        // No connected folder is needed.
        rig.store.replace { $0.access = .notConnected }
        rig.host.scene.apply(rig.store.state)
        let (frame2, _) = try Self.points(rig)
        #expect(rig.dropIn.drop([png], at: frame2, copy: false, keys: DropKeys(mode: .move)))
        #expect(got == [png, png])
        #expect(rig.store.dispatchCount == dispatched && rig.effects.fileLog.isEmpty)
        #expect(FileManager.default.fileExists(atPath: png.path))
    }

    @Test("A refused drop on the frame bonks with why and returns false; nothing is read or dispatched")
    func refusedDropBonks() throws {
        let rig = try AppRig()
        rig.connect()
        rig.host.scene.apply(rig.store.state)
        var got: [URL] = []
        rig.dropIn.hangPhoto = { got.append($0) }
        let txt = try rig.temp.file("Elsewhere/notes.txt")
        let a = try rig.temp.png("Elsewhere/a.png"), b = try rig.temp.png("Elsewhere/b.png")
        let folder = try rig.temp.dir("Elsewhere/Album")
        let (frame, _) = try Self.points(rig)
        let scene = rig.host.scene
        let dispatched = rig.store.dispatchCount

        var bonks = scene.bonkCount
        #expect(!rig.dropIn.drop([txt], at: frame, copy: false))
        #expect(scene.bonkCount == bonks + 1 && scene.toastShown == .notAPhoto)
        bonks = scene.bonkCount
        #expect(!rig.dropIn.drop([a, b], at: frame, copy: false))
        #expect(scene.bonkCount == bonks + 1 && scene.toastShown == .onePhotoAtATime)
        bonks = scene.bonkCount
        #expect(!rig.dropIn.drop([folder], at: frame, copy: false))
        #expect(scene.bonkCount == bonks + 1 && scene.toastShown == .notAPhoto)
        #expect(got.isEmpty && rig.store.dispatchCount == dispatched && rig.effects.fileLog.isEmpty)
        #expect(FileManager.default.fileExists(atPath: txt.path), "the text file still where it was")

        // With the session's guard (a temporary folder stands for the real Desktop), a photo inside it is refused.
        let desktop = try rig.temp.dir("D")
        let inside = try rig.temp.png("D/c.png")
        rig.dropIn.photoRefusal = { FramePhotoLoader.refusal($0, realDesktop: desktop) }
        bonks = scene.bonkCount
        #expect(!rig.dropIn.drop([inside], at: frame, copy: false))
        #expect(scene.bonkCount == bonks + 1 && scene.toastShown == .photoUnreadable)
        #expect(got.isEmpty && rig.store.dispatchCount == dispatched)
        #expect(rig.dropIn.frameRefusal([]) == .notAPhoto && rig.dropIn.frameRefusal([a]) == nil)
    }

    @Test("The drop goes where the drag's last answer said: the frame's reads anywhere, the desk's over the frame bonks")
    func route() throws {
        #expect(DropInController.frameRoute(answeredFrame: true, overFrame: false) == .frame)
        #expect(DropInController.frameRoute(answeredFrame: true, overFrame: true) == .frame)
        #expect(DropInController.frameRoute(answeredFrame: false, overFrame: true) == .refuse)
        #expect(DropInController.frameRoute(answeredFrame: false, overFrame: false) == .desk)
        #expect(DropInController.frameRoute(answeredFrame: nil, overFrame: true) == .frame)
        #expect(DropInController.frameRoute(answeredFrame: nil, overFrame: false) == .desk)

        let rig = try AppRig()
        rig.connect()
        rig.host.scene.apply(rig.store.state)
        var got: [URL] = []
        rig.dropIn.hangPhoto = { got.append($0) }
        let png = try rig.temp.png("Elsewhere/a.png")
        let (frame, cell) = try Self.points(rig)
        let dispatched = rig.store.dispatchCount
        // Told the frame's answer, then let go over a monitor cell: still only read.
        #expect(rig.dropIn.dragged([png], at: frame, copy: false, drag: 7) == .link)
        #expect(rig.dropIn.drop([png], at: cell, copy: false, drag: 7))
        #expect(got == [png] && rig.store.dispatchCount == dispatched && rig.effects.fileLog.isEmpty)
        // Told the desk's answer (a move), then let go over the frame: refused, nothing read.
        #expect(rig.dropIn.dragged([png], at: cell, copy: false, drag: 8) == .move)
        let bonks = rig.host.scene.bonkCount
        #expect(!rig.dropIn.drop([png], at: frame, copy: false, drag: 8))
        #expect(rig.host.scene.bonkCount == bonks + 1)
        #expect(got == [png] && rig.store.dispatchCount == dispatched && rig.effects.fileLog.isEmpty)
        // Another drag's answer is not this drop's: the point decides.
        #expect(rig.dropIn.dragged([png], at: cell, copy: false, drag: 9) == .move)
        #expect(rig.dropIn.drop([png], at: frame, copy: false, drag: 10))
        #expect(got == [png, png])
        // No drag number (the demo runner's drop): the point decides.
        #expect(rig.dropIn.drop([png], at: frame, copy: false))
        #expect(got == [png, png, png] && rig.store.dispatchCount == dispatched && rig.effects.fileLog.isEmpty)
        #expect(FileManager.default.fileExists(atPath: png.path))
    }

    @Test("A wall's framed print answers and takes a drop as the desk's frame does, never dropOnWall's import")
    func wallFrame() throws {
        let rig = try AppRig()
        var got: [URL] = []
        rig.dropIn.hangPhoto = { got.append($0) }
        let png = try rig.temp.png("Elsewhere/a.png")
        let txt = try rig.temp.file("Elsewhere/notes.txt")
        #expect(rig.dropIn.wallFrameOperation([png], keys: DropKeys()) == .link, "not connected: still answered")
        #expect(rig.dropIn.wallFrameOperation([], keys: DropKeys()) == [])
        #expect(rig.dropIn.wallFrameOperation([png], keys: DropKeys(mask: [.move])) == [])
        #expect(rig.dropIn.wallFrameOperation([png], keys: DropKeys(mask: [.copy, .move])) == .copy)
        #expect(rig.dropIn.dropOnWallFrame([png]))
        #expect(got == [png] && rig.store.dispatchCount == 0 && rig.effects.fileLog.isEmpty)
        #expect(!rig.dropIn.dropOnWallFrame([txt]))
        #expect(rig.host.scene.toastShown == .notAPhoto, "the desk toasts why")
        #expect(got == [png] && rig.store.dispatchCount == 0)

        rig.connect()
        let wall = WallView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var dropped: [[URL]] = []
        wall.acceptsFiles = true
        wall.onDrop = { urls, _, _ in dropped.append(urls) }
        wall.operationFor = { urls, copy, drag, keys in rig.dropIn.wallOperation(urls, copy: copy, drag: drag, keys: keys) }
        wall.frameOperationFor = { urls, keys in rig.dropIn.wallFrameOperation(urls, keys: keys) }
        wall.onFrameDrop = { rig.dropIn.dropOnWallFrame($0) }
        wall.isOverFrame = { _ in true }
        let photo = FrameDrag([png], mask: .every, sequence: 1)
        #expect(wall.draggingUpdated(photo) == .link)
        #expect(wall.performDragOperation(photo))
        #expect(got == [png, png] && dropped.isEmpty, "the wall's frame only reads; onDrop is never called")
        let text = FrameDrag([txt], mask: .every, sequence: 2)
        #expect(wall.draggingUpdated(text) == .link)
        #expect(!wall.performDragOperation(text))
        #expect(dropped.isEmpty && rig.store.dispatchCount == 0)
        // Answered off the frame (a move), let go over it: refused.
        wall.isOverFrame = { _ in false }
        let moved = FrameDrag([png], mask: .every, sequence: 3)
        #expect(wall.draggingUpdated(moved) == .move)
        wall.isOverFrame = { _ in true }
        #expect(!wall.performDragOperation(moved))
        #expect(dropped.isEmpty && got == [png, png])
        // Off the frame: as today, the monitor takes it.
        wall.isOverFrame = { _ in false }
        let plain = FrameDrag([png], mask: .every, sequence: 4)
        #expect(wall.draggingUpdated(plain) == .move)
        #expect(wall.performDragOperation(plain))
        #expect(dropped == [[png]] && got == [png, png])

        // Where a wall's framed print is: the controller's hit test, from the view point (y up) to canvas px.
        let grid = PixelGrid(display: DisplayGeometry(widthPt: 1920, heightPt: 1080, backingScale: 1, topInsetPt: 25))
        let r = try #require(WallArt.frameRect(LayoutSolver.solve(grid: grid)))
        let d = grid.deviceRect(forArt: r)
        let s = grid.display.backingScale
        let height = CGFloat(Double(grid.display.frameHeightPx) / s)
        func viewPoint(deviceX x: Double, deviceY y: Double) -> NSPoint { NSPoint(x: x / s, y: Double(height) - y / s) }
        let mid = viewPoint(deviceX: Double(d.x) + Double(d.w) / 2, deviceY: Double(d.y) + Double(d.h) / 2)
        #expect(WallController.isOverFrame(viewPoint: mid, viewHeight: height, grid: grid, frame: r))
        let left = viewPoint(deviceX: Double(d.x) - 10, deviceY: Double(d.y) + Double(d.h) / 2)
        #expect(!WallController.isOverFrame(viewPoint: left, viewHeight: height, grid: grid, frame: r))
        #expect(!WallController.isOverFrame(viewPoint: mid, viewHeight: height, grid: grid, frame: nil))
        #expect(WallArt.frameRect(LayoutSolver.solve(grid: grid), stowed: [.wallShelf]) == nil)
    }
}

/// The live wiring of a wall's framed print (Erratum 33): `WallController.render` records where its last render drew
/// the print, and the view's `isOverFrame` answers from it, so a photo dragged onto another display's print is the
/// frame's (a link, read and hung) and never the monitor's import. No scene and no Metal: the wall is CPU-rendered and
/// its window is never shown.
@Suite("Wall frame wiring")
@MainActor
struct WallFrameWiringTests {
    @Test("render records the print, the view's hit test answers from it; put away, none of the wall is the frame's")
    func wiring() throws {
        let temp = try AppTemp()
        let png = try temp.png("Elsewhere/a.png")
        let display = DisplayInfo(id: 2, uuid: "LEFT", frame: PointRect(x: -1920, y: 0, width: 1920, height: 1080),
                                  backingScale: 1)
        let w = WallController(display: display, level: .normal, pixelSize: .normal)
        defer { w.close() }
        let centre = NSPoint(x: w.view.bounds.midX, y: w.view.bounds.midY)
        #expect(w.frameRect == nil, "nothing rendered yet")
        #expect(w.view.isOverFrame?(centre) == false)

        var state = RoomState(time: WallTime(year: 2026, month: 10, day: 18, hour: 10, minute: 0))
        w.render(state)
        let r = try #require(w.frameRect)
        #expect(r == WallArt.frameRect(LayoutSolver.solve(grid: w.grid)))
        // The print's centre as a view point (AppKit's, y up), from its device rect.
        let d = w.grid.deviceRect(forArt: r)
        let s = w.grid.display.backingScale
        let p = NSPoint(x: (Double(d.x) + Double(d.w) / 2) / s,
                        y: Double(w.view.bounds.height) - (Double(d.y) + Double(d.h) / 2) / s)
        #expect(w.view.isOverFrame?(p) == true)
        #expect(w.view.isOverFrame?(NSPoint(x: p.x - 200, y: p.y)) == false)

        // Wired as DisplayManager wires a wall: a drag over the print is the frame's, elsewhere the monitor's.
        var hung: [URL] = [], dropped: [[URL]] = []
        w.view.acceptsFiles = true
        w.view.onDrop = { urls, _, _ in dropped.append(urls) }
        w.view.operationFor = { _, _, _, _ in .move }
        w.view.frameOperationFor = { _, _ in .link }
        w.view.onFrameDrop = { urls in hung.append(contentsOf: urls); return true }
        let over = FrameDrag([png], mask: .every, sequence: 1, location: p)
        #expect(w.view.draggingUpdated(over) == .link)
        #expect(w.view.performDragOperation(over))
        #expect(hung == [png] && dropped.isEmpty, "the print only reads; the monitor's import is never called")
        let beside = FrameDrag([png], mask: .every, sequence: 2, location: NSPoint(x: p.x - 200, y: p.y))
        #expect(w.view.draggingUpdated(beside) == .move)
        #expect(w.view.performDragOperation(beside))
        #expect(dropped == [[png]] && hung == [png])

        // With the wall shelf put away the print is gone, and so is the frame's part of the wall.
        state.stowed = [.wallShelf]
        w.render(state)
        #expect(w.frameRect == nil)
        #expect(w.view.isOverFrame?(p) == false)
        let stowed = FrameDrag([png], mask: .every, sequence: 3, location: p)
        #expect(w.view.draggingUpdated(stowed) == .move)
        #expect(hung == [png])
    }
}

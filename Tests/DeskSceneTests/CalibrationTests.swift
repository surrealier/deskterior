import Metal
import Testing
@testable import DeskScene
import DeskCore

/// This Mac's default display: looks like 1470×956 @2, 33-pt menu bar, Dock hidden → S 5, canvas 588×383.
let calibrationDisplay = DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2, topInsetPt: 33)

@Suite("Calibration scene (CPU)")
struct CalibrationContentTests {
    let grid = PixelGrid(display: calibrationDisplay)

    @Test("Swatches sit inside the core, one per palette colour, without overlap")
    func layout() {
        let c = CalibrationContent(grid: grid)
        #expect(c.swatchRects.count == Apollo.count)
        for (i, r) in c.swatchRects.enumerated() {
            #expect(grid.coreStageRect.contains(r))
            #expect(c.swatch(at: r.center) == i)
        }
        #expect(c.swatch(at: grid.coreOrigin) == nil)
        #expect(grid.coreStageRect.contains(c.bounceBox))
    }

    @Test("Hover, click, stepping and rest")
    func behaviour() {
        let c = CalibrationContent(grid: grid)
        let swatch = c.swatchRects[9].center
        #expect(c.needsFrames)
        #expect(c.handle(InputEvent(.move, art: SIMD2(Float(swatch.x) + 0.5, Float(swatch.y) + 0.5))))
        #expect(c.hovered == 9)
        #expect(!c.handle(InputEvent(.move, art: SIMD2(Float(swatch.x), Float(swatch.y)))))   // same swatch
        #expect(c.handle(InputEvent(.move, art: SIMD2(0, 0))))
        #expect(c.hovered == nil)

        c.forceRest()
        #expect(!c.needsFrames)
        #expect(c.handle(InputEvent(.down, art: SIMD2(100.7, 200.2), clickCount: 1)))
        #expect(c.lastClick == ArtPoint(100, 200))
        #expect(c.needsFrames)
        #expect(!c.handle(InputEvent(.up, art: SIMD2(100.7, 200.2))))

        for _ in 0..<10 { c.step(FrameClock.step) }
        #expect(c.stepCount == 10)
    }
}

@Suite("Calibration snapshot", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct CalibrationSnapshotTests {
    let gpu: GPU
    let grid = PixelGrid(display: calibrationDisplay)

    init() throws {
        gpu = try GPU()
    }

    /// The scene after a click on a swatch, a hover on another and 30 fixed frames.
    func renderCalibration() throws -> (OffscreenDriver, PixelBuffer) {
        let host = try SceneHost(grid: grid, device: gpu.device)
        let swatches = host.scene.calibration.swatchRects
        func centre(_ i: Int) -> SIMD2<Float> { SIMD2(Float(swatches[i].center.x), Float(swatches[i].center.y)) }
        host.handle(InputEvent(.down, art: centre(27), clickCount: 1))
        host.handle(InputEvent(.move, art: centre(40)))
        let driver = OffscreenDriver(host: host)
        driver.run(frames: 30)
        return (driver, try driver.snapshot())
    }

    @Test("Offscreen calibration frame matches its golden exactly")
    func golden() throws {
        #expect(grid.scale == 5)
        #expect(grid.artSize == ArtSize(588, 383))
        let (driver, frame) = try renderCalibration()
        #expect(driver.host.stepCount == 30 && driver.host.simTime == 0.5)
        #expect(frame.size == grid.artSize)
        #expect(frame.pixels.allSatisfy { Apollo.index(of: $0) != nil }, "every pixel is a palette colour")
        #expect(Golden.match(frame, "calibration-1470x956@2"))
    }

    @Test("SpriteKit's art frame is already exact: the lit pass at level 7 changes nothing")
    func artEqualsLit() throws {
        let (driver, frame) = try renderCalibration()
        #expect(try driver.host.presenter.readArtFrame() == frame)
    }

    @Test("Device frame: the 1-px checker stays crisp at S = 5 (every art px is a solid 5×5 block)")
    func deviceFrame() throws {
        let (driver, frame) = try renderCalibration()
        let device = try driver.deviceFrame()
        #expect(device.width == 2940 && device.height == 1912)
        let expected = frame.scaledNearest(grid.scale)
            .cropped(to: ArtRect(grid.cropLeft, grid.cropTop, 2940, 1912))
        #expect(device == expected, "\(diffCount(device, expected)) px differ")
    }

    @Test("A grid change resizes the scene, the targets and the snapshot")
    func regrid() throws {
        let host = try SceneHost(grid: grid, device: gpu.device)
        let small = PixelGrid(display: DisplayGeometry(widthPt: 1280, heightPt: 832, backingScale: 2, topInsetPt: 33))
        try host.setGrid(small)
        #expect(host.grid == small)
        #expect(host.presenter.artSize == small.artSize)
        #expect(host.scene.size == ArtSpace(canvas: small.artSize).sceneSize)
        let driver = OffscreenDriver(host: host)
        driver.run(frames: 1)
        let frame = try driver.snapshot()
        #expect(frame.size == small.artSize)
        #expect(frame[0, 0] == Ink.red3.color)   // the canvas edge marker
    }

    @Test("A light mask dims nothing at mask level 0 and ambient 7; ambient 3 relights the whole frame")
    func ambientOnScene() throws {
        let (driver, frame) = try renderCalibration()
        let presenter = driver.host.presenter
        try presenter.setLightMask([UInt8](repeating: 0, count: grid.artSize.area))
        presenter.ambient = AmbientLight(level: 3, tint: .cool)
        presenter.renderOffscreen()
        let dim = try presenter.readLitFrame()
        #expect(dim.pixels == frame.pixels.map { LightRamp.shared.mapColor($0, level: 3, tint: .cool) })
    }
}

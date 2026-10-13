import Testing
@testable import DeskCore

/// One row of the docs/DESIGN.md §1.2 table. Assumptions: menu bar 37 pt on notched MacBook panels and 25 pt
/// elsewhere; Dock 70 pt.
struct PixelGridTableRow: CustomTestStringConvertible, Sendable {
    let name: String
    let widthPt: Double
    let heightPt: Double
    let backing: Double
    let notched: Bool
    let scale: Int
    let canvas: ArtSize
    let pointsPerArtPx: Double

    var menuBarPt: Double { notched ? 37 : 25 }
    var testDescription: String { name }

    func display(dock: PixelGridDock = .bottom) -> DisplayGeometry {
        switch dock {
        case .bottom:
            DisplayGeometry(widthPt: widthPt, heightPt: heightPt, backingScale: backing,
                            topInsetPt: menuBarPt, bottomInsetPt: 70)
        case .left:
            DisplayGeometry(widthPt: widthPt, heightPt: heightPt, backingScale: backing,
                            topInsetPt: menuBarPt, leftInsetPt: 70)
        case .right:
            DisplayGeometry(widthPt: widthPt, heightPt: heightPt, backingScale: backing,
                            topInsetPt: menuBarPt, rightInsetPt: 70)
        case .hidden:
            DisplayGeometry(widthPt: widthPt, heightPt: heightPt, backingScale: backing, topInsetPt: menuBarPt)
        }
    }
}

enum PixelGridDock: CaseIterable, Sendable {
    case bottom, left, right, hidden
}

let pixelGridDesignTable: [PixelGridTableRow] = [
    PixelGridTableRow(name: "MBA 13 default 1470x956@2", widthPt: 1470, heightPt: 956, backing: 2, notched: true,
            scale: 5, canvas: ArtSize(588, 383), pointsPerArtPx: 2.5),
    PixelGridTableRow(name: "1280x832@2", widthPt: 1280, heightPt: 832, backing: 2, notched: true,
            scale: 4, canvas: ArtSize(640, 416), pointsPerArtPx: 2),
    PixelGridTableRow(name: "1512x982@2", widthPt: 1512, heightPt: 982, backing: 2, notched: true,
            scale: 5, canvas: ArtSize(605, 393), pointsPerArtPx: 2.5),
    PixelGridTableRow(name: "1710x1112@2", widthPt: 1710, heightPt: 1112, backing: 2, notched: true,
            scale: 6, canvas: ArtSize(570, 371), pointsPerArtPx: 3),
    PixelGridTableRow(name: "1920x1080@1", widthPt: 1920, heightPt: 1080, backing: 1, notched: false,
            scale: 3, canvas: ArtSize(640, 360), pointsPerArtPx: 3),
    PixelGridTableRow(name: "2560x1440@1", widthPt: 2560, heightPt: 1440, backing: 1, notched: false,
            scale: 4, canvas: ArtSize(640, 360), pointsPerArtPx: 4),
    PixelGridTableRow(name: "5K 2560x1440@2", widthPt: 2560, heightPt: 1440, backing: 2, notched: false,
            scale: 8, canvas: ArtSize(640, 360), pointsPerArtPx: 4),
    PixelGridTableRow(name: "4K as 1920x1080@2", widthPt: 1920, heightPt: 1080, backing: 2, notched: false,
            scale: 6, canvas: ArtSize(640, 360), pointsPerArtPx: 3),
    PixelGridTableRow(name: "Portrait 1080x1920@1", widthPt: 1080, heightPt: 1920, backing: 1, notched: false,
            scale: 2, canvas: ArtSize(540, 960), pointsPerArtPx: 2),
]

@Suite("PixelGrid")
struct PixelGridTests {
    @Test("§1.2 table: scale, canvas and art-pixel size", arguments: pixelGridDesignTable)
    func designTableRow(_ row: PixelGridTableRow) {
        let grid = PixelGrid(display: row.display())
        #expect(grid.scale == row.scale)
        #expect(grid.artSize == row.canvas)
        #expect(grid.pointsPerArtPx == row.pointsPerArtPx)
        expectConsistentCrop(grid)
    }

    @Test("§1.2 table: the core stage fits the visible rect, floor line on its bottom edge",
          arguments: pixelGridDesignTable)
    func coreFitsVisibleRect(_ row: PixelGridTableRow) {
        let grid = PixelGrid(display: row.display())
        expectCoreFits(grid)
        #expect(grid.floorLineY == grid.visibleArtRect.maxY)
        // With a bottom Dock the floor strip (core rows 312–319) runs behind the Dock but stays on the canvas.
        #expect(grid.coreRect.maxY <= grid.artSize.h)
        #expect(grid.coreRect.maxY > grid.visibleArtRect.maxY)
        // Centred horizontally when nothing forces a clamp.
        #expect(grid.coreOrigin.x == grid.centredCoreX)
    }

    @Test("MBA 13 default: exact placement")
    func mbaExactPlacement() {
        let grid = PixelGrid(display: pixelGridDesignTable[0].display())
        #expect(grid.display.frameWidthPx == 2940 && grid.display.frameHeightPx == 1912)
        #expect(grid.display.visibleRectPx == DeviceRect(0, 74, 2940, 1698))
        #expect(grid.cropLeft == 0 && grid.cropRight == 0)
        #expect(grid.cropTop == 1 && grid.cropBottom == 2)     // 383·5 − 1912 = 3
        #expect(grid.visibleArtRect == ArtRect(0, 15, 588, 339))
        #expect(grid.coreOrigin == ArtPoint(38, 42))
        #expect(grid.floorLineY == 354)
    }

    @Test("1512x982: odd horizontal slack rounds half away from zero")
    func oddSlack() {
        let grid = PixelGrid(display: pixelGridDesignTable[2].display())
        #expect(grid.artSize.w - 512 == 93)
        #expect(grid.centredCoreX == 47)
        #expect(grid.cropLeft == 0 && grid.cropRight == 1)      // 605·5 − 3024 = 1
        #expect(grid.cropTop == 0 && grid.cropBottom == 1)      // 393·5 − 1964 = 1
    }

    @Test("Portrait: tall wall above the core")
    func portrait() {
        let grid = PixelGrid(display: pixelGridDesignTable[8].display())
        #expect(grid.visibleArtRect == ArtRect(0, 13, 540, 912))
        #expect(grid.coreOrigin == ArtPoint(14, 613))
    }

    @Test("Dock variants keep the core stage inside the visible rect",
          arguments: pixelGridDesignTable, PixelGridDock.allCases)
    func dockVariants(_ row: PixelGridTableRow, _ dock: PixelGridDock) {
        let grid = PixelGrid(display: row.display(dock: dock))
        expectConsistentCrop(grid)
        expectCoreFits(grid)
        #expect(grid.floorLineY == grid.visibleArtRect.maxY)
        // Only portrait loses a step: a 70-pt side Dock leaves 1010 px < 2·512 of width.
        let portraitSideDock = row.widthPt < row.heightPt && (dock == .left || dock == .right)
        #expect(grid.scale == (portraitSideDock ? 1 : row.scale))
    }

    @Test("Left Dock on the MBA 13: same scale, core clears the Dock")
    func leftDockMBA() {
        let grid = PixelGrid(display: pixelGridDesignTable[0].display(dock: .left))
        #expect(grid.display.visibleRectPx == DeviceRect(140, 74, 2800, 1838))
        #expect(grid.scale == 5)
        #expect(grid.visibleArtRect.minX == 28)
        #expect(grid.coreOrigin.x == 38)
        // No bottom Dock: the floor line sits on the screen's bottom edge.
        #expect(grid.floorLineY == 382)
        #expect(grid.visibleArtRect.maxY == 382)
    }

    @Test("A wide side Dock pushes the core off-centre")
    func wideSideDockClamps() {
        // 1280×832@2 with a 140-pt left Dock: visible 2280 px wide → art x 70..<640; centred x would be 64.
        let display = DisplayGeometry(widthPt: 1280, heightPt: 832, backingScale: 2, topInsetPt: 37, leftInsetPt: 140)
        let grid = PixelGrid(display: display)
        #expect(grid.scale == 4)
        #expect(grid.centredCoreX == 64)
        #expect(grid.visibleArtRect.minX == 70)
        #expect(grid.coreOrigin.x == 70)
        expectCoreFits(grid)
        let right = PixelGrid(display: DisplayGeometry(
            widthPt: 1280, heightPt: 832, backingScale: 2, topInsetPt: 37, rightInsetPt: 140))
        #expect(right.coreOrigin.x == 640 - 70 - 512)
        expectCoreFits(right)
    }

    @Test("Auto-hidden Dock: visible rect reaches the bottom; a 4-pt trigger strip is respected too")
    func autoHiddenDock() {
        for strip in [0.0, 4.0] {
            for row in pixelGridDesignTable {
                let display = DisplayGeometry(widthPt: row.widthPt, heightPt: row.heightPt,
                                              backingScale: row.backing, topInsetPt: row.menuBarPt,
                                              bottomInsetPt: strip)
                let grid = PixelGrid(display: display)
                expectCoreFits(grid)
                #expect(grid.scale == row.scale)
                #expect(grid.floorLineY == grid.visibleArtRect.maxY)
                #expect(grid.floorLineY <= grid.artSize.h)
                // The floor line is within one art px of the visible bottom edge.
                let edgePx = display.visibleRectPx.maxY + grid.cropTop
                #expect(grid.floorLineY * grid.scale <= edgePx && edgePx < (grid.floorLineY + 1) * grid.scale)
            }
        }
    }

    @Test("Pixel-size settings")
    func pixelSizes() {
        let mba = pixelGridDesignTable[0].display()
        #expect(PixelGrid(display: mba, pixelSize: .chunky).scale == 5)      // S_target 6, S_fit 5
        #expect(PixelGrid(display: mba, pixelSize: .normal).scale == 5)
        let fine = PixelGrid(display: mba, pixelSize: .fine)
        #expect(fine.scale == 4)
        #expect(fine.artSize == ArtSize(735, 478))

        let qhd = pixelGridDesignTable[5].display()                                    // 2560×1440@1
        #expect(PixelGrid.targetScale(frameHeightPx: 1440, pixelSize: .chunky) == 5)  // 4.5 rounds up
        #expect(PixelGrid(display: qhd, pixelSize: .chunky).scale == 4)       // capped by S_fit
        #expect(PixelGrid(display: qhd, pixelSize: .fine).artSize == ArtSize(854, 480))

        let fiveK = pixelGridDesignTable[6].display()
        #expect(PixelGrid(display: fiveK, pixelSize: .chunky).scale == 8)
        let fiveKFine = PixelGrid(display: fiveK, pixelSize: .fine)
        #expect(fiveKFine.scale == 7)
        #expect(fiveKFine.artSize == ArtSize(732, 412))
        for size in PixelSize.allCases {
            for row in pixelGridDesignTable {
                expectCoreFits(PixelGrid(display: row.display(), pixelSize: size))
            }
        }
        #expect(PixelSize.normal.targetArtHeight == 380)
    }

    @Test("Nudge moves the core and is clamped to the visible rect")
    func nudge() {
        let display = pixelGridDesignTable[0].display()
        let base = PixelGrid(display: display)
        #expect(base.nudgeRange == -38...38)
        #expect(PixelGrid(display: display, nudge: 16).coreOrigin.x == 54)
        #expect(PixelGrid(display: display, nudge: -24).coreOrigin.x == 14)
        #expect(PixelGrid(display: display, nudge: 500).coreOrigin.x == 76)
        #expect(PixelGrid(display: display, nudge: -500).coreOrigin.x == 0)
    }

    @Test("Device px ↔ art px conversions account for the crop")
    func conversions() {
        let grid = PixelGrid(display: pixelGridDesignTable[0].display())       // S 5, cropTop 1
        #expect(grid.artPoint(fromDevicePx: SIMD2(0, 0)) == ArtPoint(0, 0))
        #expect(grid.artPoint(fromDevicePx: SIMD2(4.99, 3.99)) == ArtPoint(0, 0))
        #expect(grid.artPoint(fromDevicePx: SIMD2(5, 4)) == ArtPoint(1, 1))
        #expect(grid.artPoint(fromDevicePx: SIMD2(-0.5, -1.5)) == ArtPoint(-1, -1))
        #expect(grid.artPoint(fromDevicePx: SIMD2(2939, 1911)) == ArtPoint(587, 382))
        // View points are device px / 2.
        #expect(grid.artPoint(fromViewPoint: SIMD2(2.5, 2)) == ArtPoint(1, 1))
        #expect(grid.artPoint(fromViewPoint: SIMD2(1469.9, 955.9)) == ArtPoint(587, 382))

        let r = ArtRect(10, 20, 3, 2)
        let d = grid.deviceRect(forArt: r)
        #expect(d == DeviceRect(50, 99, 15, 10))
        #expect(grid.artPoint(fromDevicePx: SIMD2(Double(d.x), Double(d.y))) == r.origin)
        #expect(grid.artPoint(fromDevicePx: SIMD2(Double(d.maxX - 1), Double(d.maxY - 1))) == ArtPoint(12, 21))
        #expect(grid.deviceRect(forArt: ArtRect(0, 0, 588, 383)) == DeviceRect(0, -1, 2940, 1915))

        // Every visible art pixel maps to device px inside the visible rect.
        let vis = grid.deviceRect(forArt: grid.visibleArtRect)
        let v = grid.display.visibleRectPx
        #expect(vis.x >= v.x && vis.y >= v.y && vis.maxX <= v.maxX && vis.maxY <= v.maxY)

        let core = ArtPoint(100, 200)
        let canvas = grid.canvasPoint(fromCore: core)
        #expect(canvas == ArtPoint(138, 242))
        #expect(grid.corePoint(fromCanvas: canvas) == core)
        #expect(grid.canvasRect(fromCore: ArtRect(0, 0, 512, 320)) == grid.coreRect)
    }

    @Test("Degenerate displays never trap")
    func degenerate() {
        let tiny = PixelGrid(display: DisplayGeometry(widthPt: 300, heightPt: 200, backingScale: 1, topInsetPt: 25))
        #expect(tiny.scale == 1)
        #expect(tiny.artSize == ArtSize(300, 200))
        let empty = PixelGrid(display: DisplayGeometry(
            frameWidthPx: 0, frameHeightPx: 0, visibleRectPx: DeviceRect(0, 0, 0, 0), backingScale: 2))
        #expect(empty.scale == 1)
        #expect(empty.artSize == ArtSize(0, 0))
        // A visible rect outside the frame is clipped to it.
        let bad = PixelGrid(display: DisplayGeometry(
            frameWidthPx: 1920, frameHeightPx: 1080, visibleRectPx: DeviceRect(-50, -50, 5000, 5000), backingScale: 1))
        #expect(bad.visibleArtRect == ArtRect(0, 0, 640, 360))
        #expect(PixelGrid.floorDiv(-7, 2) == -4 && PixelGrid.ceilDiv(-7, 2) == -3 && PixelGrid.ceilDiv(7, 2) == 4)
        #expect(PixelGrid.roundHalfAwayDiv(-3, 2) == -2 && PixelGrid.roundHalfAwayDiv(3, 2) == 2)
    }

    // MARK: Helpers

    private func expectConsistentCrop(_ grid: PixelGrid, sourceLocation: SourceLocation = #_sourceLocation) {
        let d = grid.display
        let cropX = grid.artSize.w * grid.scale - d.frameWidthPx
        let cropY = grid.artSize.h * grid.scale - d.frameHeightPx
        #expect(cropX >= 0 && cropX < grid.scale, sourceLocation: sourceLocation)
        #expect(cropY >= 0 && cropY < grid.scale, sourceLocation: sourceLocation)
        #expect(grid.cropLeft == cropX / 2 && grid.cropLeft + grid.cropRight == cropX, sourceLocation: sourceLocation)
        #expect(grid.cropTop == cropY / 2 && grid.cropTop + grid.cropBottom == cropY, sourceLocation: sourceLocation)
    }

    private func expectCoreFits(_ grid: PixelGrid, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(grid.visibleArtRect.contains(grid.coreStageRect), "\(grid.coreStageRect) not in \(grid.visibleArtRect)",
                sourceLocation: sourceLocation)
        #expect(grid.coreRect.minY >= grid.visibleArtRect.minY, sourceLocation: sourceLocation)
        #expect(ArtRect(origin: .zero, size: grid.artSize).contains(grid.coreStageRect), sourceLocation: sourceLocation)
    }
}

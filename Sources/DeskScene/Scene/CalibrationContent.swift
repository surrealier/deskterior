import DeskCore
import DeskPixels
import SpriteKit

/// M2 calibration content (DESIGN §14 M2), replaced by the room in later milestones. Everything sits at fixed
/// core-relative positions:
/// - the canvas edge (red), the core rect (blue) and the floor line (dashed oak);
/// - Galmuri9 text with `S`, canvas size, crop and core rect, plus a live step counter;
/// - a 1-px checkerboard block and the 46 Apollo swatches (framed dark; outlined light under the pointer);
/// - a square that bounces while the loop is awake, and a crosshair at the last click.
final class CalibrationContent {
    let root = SKNode()

    /// Canvas rects of the swatches, by palette index.
    let swatchRects: [ArtRect]
    let bounceBox: ArtRect
    private(set) var isBouncing = true
    private(set) var hovered: Int?
    private(set) var lastClick: ArtPoint?
    private(set) var stepCount = 0

    private let grid: PixelGrid
    private let space: ArtSpace
    private let stepsLabel = SKSpriteNode()
    private let square = SKSpriteNode()
    private let hoverOutline = SKSpriteNode()
    private let crosshair = SKSpriteNode()
    private var squareTopLeft: SIMD2<Double>
    private var squareVelocity = SIMD2<Double>(53, 37)
    private var shownSteps: Int?

    static let swatchSize = 14
    static let swatchPitch = 16
    static let squareSize = 6
    static let crosshairSize = 9
    static let textInk = Role.labelText

    init(grid: PixelGrid) {
        self.grid = grid
        space = ArtSpace(canvas: grid.artSize)
        let core = grid.coreOrigin
        func canvas(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> ArtRect { ArtRect(core.x + x, core.y + y, w, h) }

        var rects = [ArtRect](repeating: .zero, count: Apollo.count)
        for ramp in Apollo.Ramp.allCases {
            for (col, index) in ramp.indices.enumerated() {
                let p = Self.swatchPitch
                rects[index] = canvas(200 + col * p, 8 + ramp.rawValue * p, Self.swatchSize, Self.swatchSize)
            }
        }
        swatchRects = rects
        bounceBox = canvas(80, 72, 104, 64)
        squareTopLeft = SIMD2(Double(bounceBox.x + 10), Double(bounceBox.y + 7))

        let layer = SKSpriteNode(texture: TextureFactory.texture(staticArt()))
        space.place(layer, at: ArtRect(0, 0, grid.artSize.w, grid.artSize.h))
        root.addChild(layer)

        stepsLabel.zPosition = 1
        root.addChild(stepsLabel)

        square.texture = TextureFactory.solid(Ink.walnut4.color)
        square.zPosition = 2
        root.addChild(square)

        var outline = PixelCanvas(width: Self.swatchPitch, height: Self.swatchPitch)
        outline.stroke(outline.bounds, .neutral9)
        hoverOutline.texture = TextureFactory.texture(outline.buffer)
        hoverOutline.zPosition = 3
        hoverOutline.isHidden = true
        root.addChild(hoverOutline)

        let n = Self.crosshairSize
        var cross = PixelCanvas(width: n, height: n)
        cross.hline(x: 0, y: n / 2, length: n, .red4)
        cross.vline(x: n / 2, y: 0, length: n, .red4)
        cross.plot(n / 2, n / 2, .neutral9)
        crosshair.texture = TextureFactory.texture(cross.buffer)
        crosshair.zPosition = 4
        crosshair.isHidden = true
        root.addChild(crosshair)

        placeSquare()
        updateStepsLabel()
    }

    var needsFrames: Bool { isBouncing }

    func forceRest() {
        isBouncing = false
    }

    func step(_ dt: Double) {
        stepCount += 1
        if isBouncing {
            let size = Double(Self.squareSize)
            let lo = SIMD2(Double(bounceBox.minX + 1), Double(bounceBox.minY + 1))
            let hi = SIMD2(Double(bounceBox.maxX - 1) - size, Double(bounceBox.maxY - 1) - size)
            var p = squareTopLeft + squareVelocity * dt
            for axis in 0..<2 {
                if p[axis] < lo[axis] {
                    p[axis] = 2 * lo[axis] - p[axis]
                    squareVelocity[axis] = -squareVelocity[axis]
                } else if p[axis] > hi[axis] {
                    p[axis] = 2 * hi[axis] - p[axis]
                    squareVelocity[axis] = -squareVelocity[axis]
                }
            }
            squareTopLeft = p
            placeSquare()
        }
        updateStepsLabel()
    }

    /// True when something visible changed.
    func handle(_ event: InputEvent) -> Bool {
        switch event.kind {
        case .move, .drag:
            return setHovered(swatch(at: event.artPixel))
        case .down, .rightDown:
            let p = event.artPixel
            lastClick = p
            let half = Self.crosshairSize / 2
            space.place(crosshair, at: ArtRect(p.x - half, p.y - half, Self.crosshairSize, Self.crosshairSize))
            crosshair.isHidden = false
            isBouncing = true
            _ = setHovered(swatch(at: p))
            return true
        case .up, .scroll, .key:
            return false
        }
    }

    /// The palette index of the swatch containing `p`.
    func swatch(at p: ArtPoint) -> Int? {
        swatchRects.firstIndex { $0.contains(p) }
    }

    private func setHovered(_ index: Int?) -> Bool {
        guard index != hovered else { return false }
        hovered = index
        if let index {
            let r = swatchRects[index]
            let inset = (Self.swatchPitch - Self.swatchSize) / 2
            space.place(hoverOutline, at: ArtRect(r.x - inset, r.y - inset, Self.swatchPitch, Self.swatchPitch))
        }
        hoverOutline.isHidden = index == nil
        return true
    }

    private func placeSquare() {
        let p = ArtPoint(Int(squareTopLeft.x.rounded()), Int(squareTopLeft.y.rounded()))
        space.place(square, at: ArtRect(origin: p, size: ArtSize(Self.squareSize, Self.squareSize)))
    }

    private func updateStepsLabel() {
        guard shownSteps != stepCount, let font = PixelFont.galmuri9 else { return }
        shownSteps = stepCount
        let text = font.render("steps \(stepCount)", color: Self.textInk.color)
        stepsLabel.texture = TextureFactory.dynamicTexture(text)
        let o = grid.canvasPoint(fromCore: ArtPoint(8, 54))
        space.place(stepsLabel, at: ArtRect(origin: o, size: text.size))
    }

    /// Everything that never moves, in one canvas-sized buffer.
    private func staticArt() -> PixelBuffer {
        var c = PixelCanvas(width: grid.artSize.w, height: grid.artSize.h)
        let core = grid.coreOrigin
        c.stroke(c.bounds, .red3)
        for x in stride(from: 0, to: c.width, by: 4) {
            c.hline(x: x, y: grid.floorLineY, length: 2, .oak2)
        }
        c.stroke(grid.coreRect, Role.selection)

        if let font = PixelFont.galmuri9 {
            let lines = [
                "Deskterior  M2 calibration",
                "S \(grid.scale)   canvas \(grid.artSize)",
                "crop L\(grid.cropLeft) T\(grid.cropTop) R\(grid.cropRight) B\(grid.cropBottom)",
                "core \(grid.coreRect)",
            ]
            for (i, line) in lines.enumerated() {
                c.blit(font.render(line, color: Self.textInk.color), at: ArtPoint(core.x + 8, core.y + 6 + 12 * i))
            }
        }

        let checker = ArtRect(core.x + 8, core.y + 72, 64, 64)
        for y in checker.minY..<checker.maxY {
            for x in checker.minX..<checker.maxX {
                c.plot(x, y, (x - checker.x + y - checker.y) & 1 == 0 ? .neutral9 : .neutral0)
            }
        }

        // Framed, so the swatch that matches the backdrop still shows.
        for (index, r) in swatchRects.enumerated() {
            c.stroke(r.insetBy(-1, -1), .neutral0)
            c.fill(r, Ink(palette: index))
        }
        c.stroke(bounceBox, .neutral5)
        return c.buffer
    }
}

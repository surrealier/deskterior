import DeskCore
import SpriteKit

/// The desk scene (DESIGN §4.4): `size = canvas × U`, anchor `.zero`, `.fill`, never attached to an `SKView`
/// (`SKRenderer` draws it). Set up explicitly; no `didMove(to:)`. In M2 it holds the calibration content.
public final class DeskScene: SKScene {
    public private(set) var grid: PixelGrid
    public private(set) var space: ArtSpace
    /// The backdrop: the art pass clears to it and a full-canvas sprite paints it (SPIKES S5).
    public let backdropColor = Ink.neutral1.color

    private let backdrop = SKSpriteNode()
    private(set) var calibration: CalibrationContent

    public init(grid: PixelGrid) {
        self.grid = grid
        space = ArtSpace(canvas: grid.artSize)
        calibration = CalibrationContent(grid: grid)
        super.init(size: space.sceneSize)
        anchorPoint = .zero
        scaleMode = .fill
        backdrop.texture = TextureFactory.solid(backdropColor)
        backdrop.zPosition = -1
        addChild(backdrop)
        addChild(calibration.root)
        space.place(backdrop, at: ArtRect(origin: .zero, size: grid.artSize))
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("DeskScene is built in code")
    }

    /// Resizes the scene and rebuilds its content for a new grid.
    public func configure(grid newGrid: PixelGrid) {
        guard newGrid != grid else { return }
        grid = newGrid
        space = ArtSpace(canvas: newGrid.artSize)
        size = space.sceneSize
        space.place(backdrop, at: ArtRect(origin: .zero, size: newGrid.artSize))
        calibration.root.removeFromParent()
        calibration = CalibrationContent(grid: newGrid)
        addChild(calibration.root)
    }

    /// One fixed simulation step.
    public func step(_ dt: Double) {
        calibration.step(dt)
    }

    /// Routes an input event; true when something visible changed.
    @discardableResult
    public func handle(_ event: InputEvent) -> Bool {
        calibration.handle(event)
    }

    /// True while anything moves on its own.
    public var needsFrames: Bool { calibration.needsFrames }

    /// Hard sleep: settle everything immediately.
    public func forceRest() {
        calibration.forceRest()
    }
}

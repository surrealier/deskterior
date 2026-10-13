import DeskCore
import Foundation
import SpriteKit

/// What the scene shows: the room (default) or the M2 calibration card (`--calibration`).
public enum SceneContent: String, Sendable, CaseIterable {
    case room, calibration
}

/// Where the room's time comes from: the real local clock, or a fixed reading (`--clock`, tests).
public enum SceneClock: Hashable, Sendable {
    case live
    case fixed(WallTime)

    /// The current wall time (local calendar for `.live`).
    public func now() -> WallTime {
        switch self {
        case .fixed(let t): return t
        case .live: return Self.wallTime(Date())
        }
    }

    /// `date` as a local wall reading.
    public static func wallTime(_ date: Date, calendar: Calendar = .current) -> WallTime {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return WallTime(year: c.year ?? 2026, month: c.month ?? 1, day: c.day ?? 1, hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
}

/// The desk scene (DESIGN §4.4): `size = canvas × U`, anchor `.zero`, `.fill`, never attached to an `SKView`
/// (`SKRenderer` draws it). Set up explicitly; no `didMove(to:)`. Shows the room by default; pushes the room's
/// light mask and ambient level to the presenter it is connected to, and re-renders the clock each minute.
public final class DeskScene: SKScene {
    public private(set) var grid: PixelGrid
    public private(set) var space: ArtSpace
    /// The backdrop: the art pass clears to it and a full-canvas sprite paints it (SPIKES S5).
    public let backdropColor = Ink.neutral1.color
    public private(set) var content: SceneContent

    /// Time source for the clock, window, calendar and light phase.
    public var clock: SceneClock = .live {
        didSet { if clock != oldValue { refreshState() } }
    }
    /// Lights setting (auto, day, night, lamp only).
    public var lightsMode: LightsMode = .auto {
        didSet { if lightsMode != oldValue { refreshState() } }
    }
    /// Widget frames (canvas px) the core should avoid.
    public var avoidRects: [ArtRect] = [] {
        didSet { if avoidRects != oldValue { room?.relayout(grid: grid, avoid: avoidRects); pushLighting() } }
    }
    /// Asks the host to render one frame (the minute clock); set by the app.
    public var onRenderRequest: (() -> Void)?

    private let backdrop = SKSpriteNode()
    private(set) var calibration: CalibrationContent?
    private(set) var room: RoomContent?
    private weak var presenter: PixelPresenter?
    private var minuteTimer: Timer?

    public init(grid: PixelGrid, content: SceneContent = .room) {
        self.grid = grid
        space = ArtSpace(canvas: grid.artSize)
        self.content = content
        super.init(size: space.sceneSize)
        anchorPoint = .zero
        scaleMode = .fill
        backdrop.texture = TextureFactory.solid(backdropColor)
        backdrop.zPosition = -1
        addChild(backdrop)
        space.place(backdrop, at: ArtRect(origin: .zero, size: grid.artSize))
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("DeskScene is built in code")
    }

    // MARK: Content

    /// Switches between the room and the calibration card.
    public func setContent(_ new: SceneContent) {
        guard new != content else { return }
        content = new
        buildContent()
    }

    /// The room's solved layout (nil while showing calibration).
    public var layout: SceneLayout? { room?.layout }
    /// The room's state (nil while showing calibration).
    public var roomState: RoomState? { room?.state }
    /// The element and part under a canvas pixel.
    public func hitTest(_ p: ArtPoint) -> Hit? { room?.hitTest(p) }

    private func buildContent() {
        calibration?.root.removeFromParent()
        room?.root.removeFromParent()
        calibration = nil
        room = nil
        switch content {
        case .calibration:
            let c = CalibrationContent(grid: grid)
            addChild(c.root)
            calibration = c
        case .room:
            let r = RoomContent(grid: grid, state: RoomState(time: clock.now(), lightsMode: lightsMode), avoid: avoidRects)
            addChild(r.root)
            room = r
        }
        pushLighting()
    }

    /// Re-reads the clock and lights into the room; true when the picture changed.
    @discardableResult
    public func refreshState() -> Bool {
        guard let room else { return false }
        var s = room.state
        s.time = clock.now()
        s.lightsMode = lightsMode
        let changed = room.setState(s)
        if changed { pushLighting() }
        return changed
    }

    /// Resizes the scene and rebuilds its content for a new grid.
    public func configure(grid newGrid: PixelGrid) {
        guard newGrid != grid else { return }
        grid = newGrid
        space = ArtSpace(canvas: newGrid.artSize)
        size = space.sceneSize
        space.place(backdrop, at: ArtRect(origin: .zero, size: newGrid.artSize))
        buildContent()
    }

    // MARK: Lighting

    /// Sends this scene's light mask and ambient level to `presenter` now and on every change.
    public func connect(presenter: PixelPresenter) {
        self.presenter = presenter
        pushLighting()
    }

    /// The light mask bytes and ambient the lit pass should use.
    public var lighting: (mask: [UInt8], ambient: AmbientLight) {
        if let room { return (room.lightMask.bytes, room.ambient) }
        return ([UInt8](repeating: 0, count: grid.artSize.area), .identity)
    }

    private func pushLighting() {
        guard let presenter, presenter.artSize == grid.artSize else { return }
        let l = lighting
        try? presenter.setLightMask(l.mask)
        presenter.ambient = l.ambient
    }

    // MARK: Minute clock

    /// Starts re-rendering at each minute boundary (live clock only); no display link involved.
    public func startClock() {
        stopClock()
        guard case .live = clock else { return }
        let now = Date()
        let next = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60.05
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.refreshState() { self.onRenderRequest?() }
                self.startClock()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    public func stopClock() {
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    // MARK: Loop

    /// One fixed simulation step.
    public func step(_ dt: Double) {
        calibration?.step(dt)
    }

    /// Routes an input event; true when something visible changed.
    @discardableResult
    public func handle(_ event: InputEvent) -> Bool {
        calibration?.handle(event) ?? room?.handle(event) ?? false
    }

    /// True while anything moves on its own.
    public var needsFrames: Bool { calibration?.needsFrames ?? false }

    /// Hard sleep: settle everything immediately.
    public func forceRest() {
        calibration?.forceRest()
    }
}

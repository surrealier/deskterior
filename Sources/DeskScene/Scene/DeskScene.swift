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
///
/// The app drives it with committed model state (`apply`), real icons (`showIcon`), model animations (`play`)
/// and toasts; input arrives as `InputEvent`s and `KeyCommand`s, and what the user asks for leaves through
/// `onAction` (a `DeskAction` for the store) and `onRequest` (menus, Inventory). Without a model it is the bare
/// M3 room.
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
    /// Model actions the user asked for (clicks, drops, keys, menu picks on scene buttons).
    public var onAction: ((DeskAction) -> Void)? {
        didSet { wireRoom() }
    }
    /// App requests: context menus, Inventory.
    public var onRequest: ((SceneRequest) -> Void)? {
        didSet { wireRoom() }
    }
    /// The desk menu's extras (pause state, undo labels).
    public var menuContext = MenuSpec.Context() {
        didSet { room?.menuContext = menuContext }
    }
    /// Points per art px on the display (the drag threshold is capped in points); 0 keeps 3 art px.
    public var pointsPerArtPx: Double = 0 {
        didSet { room?.router.setPointsPerArtPx(pointsPerArtPx) }
    }
    /// Reduce Motion: elements skip flickers, jiggles, spring-backs and the CRT (`SceneContext.reduceMotion`).
    public var reduceMotion = false {
        didSet { room?.context.reduceMotion = reduceMotion }
    }
    /// The committed model (nil: the bare room).
    public private(set) var deskState: DeskState?
    /// Real icons by token, kept across content rebuilds.
    private var icons: [TokenKey: PixelBuffer] = [:]
    private var pushedEmissive = LitOverlay()

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
            let r = RoomContent(grid: grid, state: roomState(for: deskState), avoid: avoidRects)
            addChild(r.root)
            room = r
            r.menuContext = menuContext
            r.router.setPointsPerArtPx(pointsPerArtPx)
            r.context.reduceMotion = reduceMotion
            wireRoom()
            for (k, v) in icons { r.showIcon(k, v) }
            if let deskState { r.apply(deskState) }
        }
        pushLighting()
    }

    private func wireRoom() {
        guard let room else { return }
        room.context.onAction = { [weak self] in self?.onAction?($0) }
        room.context.onRequest = { [weak self] in self?.onRequest?($0) }
        room.context.lightOverrides.onChange = { [weak self] in self?.refreshState() }
    }

    /// The room state for the clock, the lights setting and (when known) the model's lamps, phone and drawers;
    /// the monitor glows while its screen is lit. (The chair follows the model once it rolls, M6.)
    private func roomState(for s: DeskState?) -> RoomState {
        var r = RoomState(time: clock.now(), lightsMode: lightsMode)
        guard let s else { return r }
        r.lights = RoomLightState(
            lampOn: s.lights.lamp, monitorOn: room?.monitor.isEmissive ?? (s.monitor.power == .on),
            phoneFaceUp: !s.phone.faceDown, roomLightOn: s.lights.room,
            monitorGlows: room?.monitor.glows ?? (s.monitor.power == .on)
        )
        r.riserOpen = [ContainerID.riserLeft, .riserRight].map { Int(s.drawerOpening($0).rounded()) }
        r.cabinetOpen = [ContainerID.cabinetTop, .cabinetMiddle, .cabinetFile].map { Int(s.drawerOpening($0).rounded()) }
        return r
    }

    // MARK: Model

    /// Adopts committed model state: every element follows it, and the room's lamps and monitor glow with it.
    public func apply(_ state: DeskState) {
        deskState = state
        room?.apply(state)
        refreshState()
    }

    /// A token's pixelated real icon (nil: back to the kind icon).
    public func showIcon(_ key: TokenKey, _ icon: PixelBuffer?) {
        icons[key] = icon
        room?.showIcon(key, icon)
    }

    /// Drops icons of tokens that are gone.
    public func pruneIcons(keeping live: Set<TokenKey>) {
        for k in icons.keys where !live.contains(k) {
            icons[k] = nil
            room?.showIcon(k, nil)
        }
    }

    /// Plays a model-requested animation (`Effect.play`).
    public func play(_ id: AnimationID, _ target: AnimTarget) {
        room?.play(id, target)
    }

    public func toast(_ key: ToastKey) {
        room?.showToast(key)
        syncLighting()
    }

    /// The selection (nil while showing calibration).
    public var selection: Selection? { room?.context.selection }
    public var screen: ScreenElement? { room?.screen }
    public var monitor: MonitorElement? { room?.monitor }
    /// Drops refused so far.
    public var bonkCount: Int { room?.context.bonks ?? 0 }
    /// The tooltip on show, if any.
    public var tooltipShown: TooltipSpec? { room?.tooltip.spec }
    /// The toast on show, if any.
    public var toastShown: ToastKey? { room?.toast.key }
    /// True while a drag (carry or marquee) is in hand.
    public var isDragging: Bool { room?.router.drag != nil }
    /// True while the button is down on the desk.
    public var isPressing: Bool { room?.router.isPressed ?? false }

    /// What VoiceOver should offer: the visible controls and tokens, front to back.
    public func accessibilityItems() -> [AXItem] {
        guard let room else { return [] }
        return room.routing.flatMap { $0.accessibilityItems() }
    }

    /// VoiceOver's press on an item: a click at its centre, through the same gestures as the pointer.
    public func accessibilityPress(_ item: AXItem, time: Double) {
        let p = SIMD2(Float(item.frame.midX) + 0.5, Float(item.frame.midY) + 0.5)
        handle(InputEvent(.down, art: p, clickCount: 1, t: time))
        handle(InputEvent(.up, art: p, clickCount: 1, t: time))
    }

    /// VoiceOver's Open on a token, while it is on show.
    public func accessibilityOpen(_ key: TokenKey) {
        guard let room, room.extras.contains(where: { $0.shownTokens.contains(key) }) else { return }
        onAction?(.requestOpen([key]))
    }

    /// The menu a right-click at `p` would show (demo scripts, the app's status item uses the desk menu); empty
    /// over a token in the dark, where a right-click shows none.
    public func contextMenu(at p: ArtPoint) -> MenuSpec {
        let t = room?.target(at: p)
        if t?.element is DarkTokenElement { return MenuSpec([]) }
        return t.flatMap { $0.element.menu($0.hit) } ?? MenuSpec.desk(deskState ?? DeskState(), menuContext)
    }

    /// Re-reads the clock, lights and model into the room; true when the picture changed.
    @discardableResult
    public func refreshState() -> Bool {
        guard let room else { return false }
        var s = deskState == nil ? room.state : roomState(for: deskState)
        s.time = clock.now()
        s.lightsMode = lightsMode
        room.adjustLighting(&s)
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
        guard let room else { return ([UInt8](repeating: 0, count: grid.artSize.area), .identity) }
        let overlay = room.litOverlay
        guard !overlay.isEmpty else { return (room.lightMask.bytes, room.ambient) }
        var mask = room.lightMask
        overlay.apply(to: &mask)
        return (mask.bytes, room.ambient)
    }

    private func pushLighting() {
        pushedEmissive = room?.litOverlay ?? LitOverlay()
        guard let presenter, presenter.artSize == grid.artSize else { return }
        let l = lighting
        try? presenter.setLightMask(l.mask)
        presenter.ambient = l.ambient
    }

    /// Re-pushes the mask when the UI's lit rects moved (tooltip, toast, hover ring).
    private func syncLighting() {
        if (room?.litOverlay ?? LitOverlay()) != pushedEmissive { pushLighting() }
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
        guard let room else { return }
        room.step(dt)
        if deskState != nil, room.state.lights.monitorOn != room.monitor.isEmissive
            || room.state.lights.monitorGlows != room.monitor.glows { refreshState() }
        syncLighting()
    }

    /// Routes an input event; true when something visible changed.
    @discardableResult
    public func handle(_ event: InputEvent) -> Bool {
        if let calibration { return calibration.handle(event) }
        guard let room else { return false }
        let changed = room.handle(event)
        syncLighting()
        return changed
    }

    /// Routes a keyboard command; true when it did something.
    @discardableResult
    public func handleKey(_ command: KeyCommand) -> Bool {
        room?.router.key(command) ?? false
    }

    /// When the input router next needs `advanceInput` (the tooltip delay), in event time.
    public var nextInputDeadline: Double? { room?.router.nextDeadline }

    /// Fires input timers due by `time`; true when something visible changed.
    @discardableResult
    public func advanceInput(to time: Double) -> Bool {
        let changed = room?.router.advance(to: time) ?? false
        syncLighting()
        return changed
    }

    /// Drops any press or drag in progress (carries spring back).
    public func cancelInput() {
        _ = room?.router.cancelAll()
    }

    /// True while anything moves on its own.
    public var needsFrames: Bool { calibration?.needsFrames ?? room?.needsFrames ?? false }

    /// True while a scripted, bounded animation (or a drag in hand) runs: the loop must not hard-sleep yet.
    public var scriptedAnimating: Bool { room?.scriptedAnimating ?? false }

    /// The 1-px screen shake of this frame (bonks).
    public var shake: ArtPoint { room?.shake ?? .zero }

    /// Hard sleep: settle everything immediately.
    public func forceRest() {
        calibration?.forceRest()
        room?.forceRest()
        syncLighting()
    }
}

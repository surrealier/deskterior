/// A drawer on its rail (DESIGN §2.2 E3, E5): a pure 1D simulation of the opening `p` in art px.
///
/// `p` runs from the lower stop `closedLimit` (0, or the jam gap of an overfull drawer:
/// `min(6, max(0, n − capacity))`) to the upper stop `openLimit` (the travel, or 3 px while the chair blocks a
/// cabinet drawer). A drag pulls the handle toward the pointer through a damped spring; a release coasts with
/// friction; scripts (click toggle, peek, chomp, spring-loading, knock) drive the same spring toward a target.
/// Stops bounce with `restitution`; the closed stop has a detent that catches small bounces. Events report what
/// happened for FX and sound; `settled` fires once each time the drawer comes to rest (dispatch
/// `.drawerSettled(id, p)`). Pure, deterministic and `Sendable`: time comes in through `step(_:)`.
public struct DrawerSim: Sendable, Equatable {
    /// Feel constants. Starting values from the spec; the tests are the contract, not the numbers.
    public struct Params: Hashable, Sendable {
        /// Pointer ↔ handle spring (1/s²) and its damping (1/s): a little under critical, so a toggle overshoots
        /// into the stop by about a pixel.
        public var stiffness: Float = 600
        public var damping: Float = 40
        /// Velocity lost per second while coasting.
        public var coastFriction: Float = 8
        /// End-stop restitution.
        public var restitution: Float = 0.25
        /// Closing faster than this at the closed stop is a slam (it triggers a desk knock).
        public var slamSpeed: Float = 120
        /// Slower stop contacts make no event.
        public var hitStopSpeed: Float = 24
        /// A bounce off the closed stop never leaves faster than this, so the detent can catch it.
        public var maxClosedBounce: Float = 16
        /// A bounce off the open stop never leaves faster than this (about a pixel of coast), so a drawer pulled
        /// wide open stays open.
        public var maxOpenBounce: Float = 8
        /// The detent pulls a coasting drawer shut within this distance of the closed stop (1/s²).
        public var latchDistance: Float = 2.5
        public var latchStiffness: Float = 300
        /// A jammed drawer bounces off its gap ("boing") and coasts at most this far back out, so it stays shut
        /// enough to keep its contents hidden.
        public var jamRebound: Float = 1.5
        public var jamRestitution: Float = 0.5
        /// Speed at which a drawer pushed past a moved stop (more items, the chair) slides back to it.
        public var pushOutSpeed: Float = 60
        public var maxSpeed: Float = 600
        /// At rest: slower than this for `restFrames` frames.
        public var restSpeed: Float = 1
        public var restFrames = 4
        /// A script is done within this distance of its target.
        public var arriveDistance: Float = 0.5
        /// Chomp (a drop on a closed front): opens this far past the lower stop, waits, then closes.
        public var chompOpen: Float = 6
        public var chompOpenTimeout: Float = 0.2
        public var chompHold: Float = 0.12
        /// Scroll peek range on a closed drawer.
        public var peekMax: Float = 4
        /// A desk knock snaps shut a non-jammed drawer at most this far past its lower stop.
        public var knockReach: Float = 3
        /// The chair blocks a cabinet drawer when it overlaps the front by more than this many px …
        public var chairBlockOverlap = 16
        /// … and then the drawer opens only this far.
        public var chairBlockLimit: Float = 3

        public init() {}

        public static let standard = Params()
    }

    /// What a step did, for FX, sound and commits.
    public enum Event: Hashable, Sendable {
        /// Shut at the closed stop faster than `slamSpeed` (trigger a desk knock).
        case slam(speed: Float)
        /// Caught by the detent and closed softly ("click").
        case latch
        /// Ran into the paper of an overfull drawer; it rests ajar at the gap.
        case stuffed(speed: Float)
        /// A jammed drawer refused to close and bounced back out ("boing").
        case jamThud(speed: Float)
        /// Ran into the open end.
        case hitStop(speed: Float)
        /// A cabinet drawer ran into the chair (thunk; push the chair aside).
        case hitChair(speed: Float)
        /// A chomp reached its widest: the dropped token slides in now.
        case chompSwallow
        /// Came to rest at this opening (whole px).
        case settled(Float)
    }

    enum Mode: Equatable {
        case coast
        case drag(target: Float)
        case script(target: Float)
        /// Held at a peek until `endPeek()`.
        case peek(target: Float)
        case chompOpen(elapsed: Float)
        case chompHold(elapsed: Float)
        /// Closing to whatever the lower stop is when it arrives.
        case scriptClose
    }

    public var params: Params
    public let travel: Float
    public let capacity: Int
    public let hardCap: Int
    /// Opening in art px.
    public private(set) var p: Float
    /// Opening speed in px/s (positive = opening, toward the viewer).
    public private(set) var v: Float = 0
    /// Acceleration over the last step (px/s²), stop impulses included: drives `ContentJostle`.
    public private(set) var acceleration: Float = 0
    /// Items inside.
    public private(set) var count: Int
    /// The upper stop (travel, or the chair-block limit).
    public private(set) var openLimit: Float
    public private(set) var isAsleep = true
    var mode: Mode = .coast
    var restCount = 0
    /// The stop the drawer is pressed against (one event per contact).
    var contact: Int = 0

    /// A drawer at rest at opening `p` holding `count` items.
    public init(capacity: Int, hardCap: Int, travel: Float, p: Float = 0, count: Int = 0, params: Params = .standard) {
        precondition(capacity > 0 && hardCap >= capacity && travel > 0, "invalid drawer")
        self.params = params
        self.travel = travel
        self.capacity = capacity
        self.hardCap = hardCap
        self.count = max(0, count)
        self.openLimit = travel
        self.p = p.isFinite ? min(max(p, 0), travel) : 0
        self.p = max(self.p, closedLimit)
    }

    /// The drawer of container `id` (riser or cabinet).
    public init(_ id: ContainerID, p: Float = 0, count: Int = 0, params: Params = .standard) {
        let spec = id.spec
        precondition(id.isDrawer, "\(id) is not a drawer")
        self.init(capacity: spec.capacity, hardCap: spec.hardCap, travel: spec.travel ?? 1, p: p, count: count,
                  params: params)
    }

    // MARK: Derived

    /// The lower stop: 0, or the jam gap of an overfull drawer.
    public var closedLimit: Float { Float(min(6, max(0, count - capacity))) }
    /// At its hard cap: closing bounces back and further drops bonk.
    public var isJammed: Bool { count >= hardCap }
    /// Holds more than its capacity: rests ajar with paper poking out.
    public var isOverfull: Bool { count > capacity }
    /// Opening in whole px for the sprite.
    public var pixel: Int { Int(min(max(p, 0), travel).rounded()) }
    /// The pointer is holding the handle.
    public var isDragging: Bool { if case .drag = mode { true } else { false } }
    /// Shut (at the true closed stop, not an overfull gap).
    public var isClosed: Bool { closedLimit == 0 && p <= 0 }
    /// Accepts a drop (a chomp or an open interior): not at the hard cap.
    public var acceptsDrops: Bool { !isJammed }
    public var needsFrames: Bool { !isAsleep }

    /// The upper stop of a cabinet drawer with the chair's left edge at `chairX`: `chairBlockLimit` when the chair
    /// overlaps the cabinet front by more than `chairBlockOverlap`, else the full travel.
    public static func cabinetOpenLimit(travel: Float, chairX: Float, params: Params = .standard) -> Float {
        let cab = CoreLayout.cabinet, w = Float(CoreLayout.chair.w)
        guard chairX.isFinite else { return travel }
        let overlap = min(chairX + w, Float(cab.maxX)) - max(chairX, Float(cab.minX))
        return overlap > Float(params.chairBlockOverlap) ? min(travel, params.chairBlockLimit) : travel
    }

    // MARK: Inputs

    /// The pointer grabbed the handle.
    public mutating func beginDrag() {
        mode = .drag(target: p)
        wake()
    }

    /// The handle should follow the pointer to opening `target` (the grab opening plus the pointer's travel along
    /// the rail).
    public mutating func drag(to target: Float) {
        guard target.isFinite else { return }
        mode = .drag(target: target)
        wake()
    }

    /// The pointer let go: the drawer coasts with the pointer's release velocity along the rail (px/s, positive =
    /// opening; DESIGN §2.1 fling), or its own when none is given. A flick toward closed slams.
    public mutating func endDrag(releaseVelocity: Float? = nil) {
        guard isDragging else { return }
        if let rv = releaseVelocity, rv.isFinite { v = min(max(rv, -params.maxSpeed), params.maxSpeed) }
        mode = .coast
        wake()
    }

    /// Click: closes an open drawer, opens a closed one.
    public mutating func toggle() {
        if p > closedLimit + 1 { close() } else { open() }
    }

    /// Opens to the upper stop (click, spring-loading).
    public mutating func open() { setTarget(openLimit) }

    /// Closes softly (the detent catches it).
    public mutating func close() {
        mode = .scriptClose
        wake()
    }

    /// Scripted motion to opening `target` (clamped to the stops).
    public mutating func setTarget(_ target: Float) {
        guard target.isFinite else { return }
        mode = .script(target: min(max(target, closedLimit), max(openLimit, closedLimit)))
        wake()
    }

    /// Two-finger scroll on a closed drawer: holds it `amount` (0…`peekMax`) past the lower stop until `endPeek()`.
    public mutating func peek(_ amount: Float) {
        let peeking = if case .peek = mode { true } else { false }
        guard amount.isFinite, peeking || p <= closedLimit + params.peekMax + params.arriveDistance else { return }
        mode = .peek(target: closedLimit + min(max(amount, 0), params.peekMax))
        wake()
    }

    /// The scroll ended: a peeking drawer closes softly.
    public mutating func endPeek() {
        guard case .peek = mode else { return }
        close()
    }

    /// A token dropped on the front: open `chompOpen`, swallow (`chompSwallow`), close. Refused when jammed.
    @discardableResult
    public mutating func chomp() -> Bool {
        guard !isJammed else { return false }
        mode = .chompOpen(elapsed: 0)
        wake()
        return true
    }

    /// A desk knock: an ajar drawer within `knockReach` of its lower stop snaps shut unless it is jammed. Returns
    /// whether it will close. A knock never opens a drawer.
    @discardableResult
    public mutating func knock() -> Bool {
        guard !isJammed, !isDragging, p > closedLimit, p - closedLimit <= params.knockReach else { return false }
        close()
        return true
    }

    /// Membership changed. A drawer that became overfull is pushed out to its new gap.
    public mutating func setCount(_ n: Int) {
        let n = max(0, n)
        guard n != count else { return }
        count = n
        if p < closedLimit { wake() }
    }

    /// The upper stop moved (the chair rolled in front of or away from a cabinet drawer).
    public mutating func setOpenLimit(_ limit: Float) {
        let limit = limit.isFinite ? min(max(limit, 0), travel) : travel
        guard limit != openLimit else { return }
        openLimit = limit
        if p > max(openLimit, closedLimit) { wake() }
    }

    /// Hard sleep (DESIGN §4.6): stops wherever it is (a peek or a detent closes), snapped to a whole px.
    public mutating func forceRest() -> [Event] {
        guard !isAsleep else { return [] }
        let lower = closedLimit, upper = max(openLimit, lower)
        if case .peek = mode { p = lower }
        if lower == 0, p < params.latchDistance { p = 0 }
        p = min(max(p.rounded(.down), lower), upper)
        v = 0
        acceleration = 0
        mode = .coast
        isAsleep = true
        contact = 0
        restCount = 0
        return [.settled(p)]
    }

    mutating func wake() {
        isAsleep = false
        restCount = 0
    }

    // MARK: Step

    /// Advances by `dt` seconds (the frame loop's fixed 1/60) and returns what happened.
    public mutating func step(_ dt: Float) -> [Event] {
        guard !isAsleep, dt > 0 else {
            acceleration = 0
            return []
        }
        var events: [Event] = []
        let lower = closedLimit, upper = max(openLimit, lower)
        let v0 = v

        // Drive.
        switch mode {
        case let .drag(target):
            // The pointer may pull past a stop (a flick toward closed builds speed); the stop holds the drawer.
            spring(toward: min(max(target, lower - travel), upper + travel), dt)
        case let .script(target), let .peek(target):
            spring(toward: min(max(target, lower), upper), dt)
        case .scriptClose:
            spring(toward: lower, dt)
        case let .chompOpen(elapsed):
            let target = min(lower + params.chompOpen, upper)
            spring(toward: target, dt)
            if p >= target - params.arriveDistance || elapsed + dt >= params.chompOpenTimeout {
                events.append(.chompSwallow)
                mode = .chompHold(elapsed: 0)
            } else {
                mode = .chompOpen(elapsed: elapsed + dt)
            }
        case let .chompHold(elapsed):
            spring(toward: min(lower + params.chompOpen, upper), dt)
            mode = elapsed + dt >= params.chompHold ? .scriptClose : .chompHold(elapsed: elapsed + dt)
        case .coast:
            v /= 1 + params.coastFriction * dt
            // Detent: a coasting drawer near the true closed stop is pulled shut.
            if lower == 0, p > 0, p < params.latchDistance {
                v -= params.latchStiffness * p * dt
            }
        }
        v = min(max(v, -params.maxSpeed), params.maxSpeed)

        // A stop that moved past the drawer pushes it back at `pushOutSpeed`.
        if p < lower {
            p = min(lower, p + params.pushOutSpeed * dt)
            v = max(v, 0)
        } else if p > upper {
            p = max(upper, p - params.pushOutSpeed * dt)
            v = min(v, 0)
        } else {
            p += v * dt
            resolveStops(lower: lower, upper: upper, events: &events)
        }
        acceleration = (v - v0) / dt

        // Scripts end on arrival, exactly at their target.
        switch mode {
        case let .script(target) where abs(p - min(max(target, lower), upper)) <= params.arriveDistance
            && abs(v) < params.restSpeed * 4:
            p = min(max(target, lower), upper)
            v = 0
            mode = .coast
        case .scriptClose where p <= lower + params.arriveDistance && abs(v) < params.restSpeed * 4:
            p = lower
            v = 0
            mode = .coast
        default:
            break
        }

        // Rest (never inside the detent, which is still pulling the drawer shut).
        let inDetent = lower == 0 && p > 0 && p < params.latchDistance
        if case .coast = mode, abs(v) < params.restSpeed, p >= lower, p <= upper, !inDetent {
            restCount += 1
            if restCount >= params.restFrames {
                // Whole px, rounding toward closed (a drawer never rests more open than it went).
                p = min(max(p.rounded(.down), lower), upper)
                v = 0
                isAsleep = true
                contact = 0
                events.append(.settled(p))
            }
        } else {
            restCount = 0
        }
        return events
    }

    /// Spring toward `target` with implicit damping (stable at any step).
    mutating func spring(toward target: Float, _ dt: Float) {
        v = (v + params.stiffness * (target - p) * dt) / (1 + params.damping * dt)
    }

    mutating func resolveStops(lower: Float, upper: Float, events: inout [Event]) {
        let held = isDragging
        if p <= lower, v <= 0 {
            let speed = -v
            p = lower
            if lower == 0 && !isJammed {
                if contact != -1 {
                    if speed > params.slamSpeed && !held {
                        events.append(.slam(speed: speed))
                    } else if speed > 0 && !held {
                        events.append(.latch)
                    }
                }
                v = held ? 0 : min(speed * params.restitution, params.maxClosedBounce)
                // Below the bounce floor the detent holds it shut.
                if v < params.restSpeed * 2 { v = 0 }
            } else if isJammed {
                if contact != -1, speed > params.hitStopSpeed || held {
                    events.append(.jamThud(speed: speed))
                }
                if held {
                    v = 0
                } else if speed > params.hitStopSpeed {
                    v = min(speed * params.jamRestitution, params.jamRebound * params.coastFriction)
                } else {
                    v = 0
                }
            } else {
                if contact != -1, speed > params.hitStopSpeed { events.append(.stuffed(speed: speed)) }
                v = 0
            }
            contact = -1
        } else if p >= upper, v >= 0 {
            let speed = v
            p = upper
            if contact != 1, speed > params.hitStopSpeed {
                events.append(upper < travel ? .hitChair(speed: speed) : .hitStop(speed: speed))
            }
            v = held || speed <= params.hitStopSpeed ? 0 : -min(speed * params.restitution, params.maxOpenBounce)
            contact = 1
        } else {
            contact = 0
        }
    }
}

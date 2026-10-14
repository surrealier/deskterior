import DeskCore
import DeskScene
import Foundation

/// `--burst` (windowed runs only; `scripts/measure-idle.sh`, DESIGN §5): once the mirror has put tokens on the
/// monitor, plays a short burst of real input through the scene host at 60 events a second — a token set down on
/// the desk, one flung off it, one dropped into the basket, a desk knock, a hover — then leaves the desk alone so
/// the idle tail can be measured. Prints `burst: done` when the last event is sent. With `endOnAV` (`--burst-av`) the
/// monitor then switches to its AV input, whose NO SIGNAL logo bounces for its 10 s (the loop's slow ticks, Errata 25).
@MainActor
final class BurstDriver {
    private let host: SceneHost
    private let store: Store
    private var events: [(kind: InputEvent.Kind, art: SIMD2<Float>, count: Int)] = []
    private var timer: Timer?
    private var waited = 0
    private let endOnAV: Bool

    private init(host: SceneHost, store: Store, endOnAV: Bool) {
        self.host = host
        self.store = store
        self.endOnAV = endOnAV
    }

    private static var running: BurstDriver?

    static func start(host: SceneHost, store: Store, endOnAV: Bool = false) {
        let driver = BurstDriver(host: host, store: store, endOnAV: endOnAV)
        running = driver
        driver.schedule()
    }

    private func schedule() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if events.isEmpty {
            // Wait (up to 10 s) for the first scan to put three tokens on the screen.
            waited += 1
            if !plan() {
                if waited > 600 { stop("burst: no tokens to play with") }
                return
            }
        }
        let e = events.removeFirst()
        host.handle(InputEvent(e.kind, art: e.art, clickCount: e.count, t: ProcessInfo.processInfo.systemUptime))
        guard events.isEmpty else { return }
        if endOnAV {
            store.dispatch(.selectAV)
            host.modelChanged()
        }
        stop(endOnAV ? "burst: done (AV)" : "burst: done")
    }

    private func stop(_ message: String) {
        timer?.invalidate()
        timer = nil
        print(message)
        fflush(stdout)
        Self.running = nil
    }

    /// Lays out the burst; false while the screen has too few tokens.
    private func plan() -> Bool {
        // The first scan's tokens print in one after another: start once the screen is still.
        guard let screen = host.scene.screen, let layout = host.scene.layout, !host.scene.needsFrames else { return false }
        let s = store.state
        let keys = s.tokens.keys { $0.cell?.page == s.monitor.page }.filter { screen.iconRect(of: $0) != nil }
        guard s.access == .connected, keys.count >= 3 else { return false }
        func centre(_ r: ArtRect) -> SIMD2<Float> { SIMD2(Float(r.midX) + 0.5, Float(r.midY) + 0.5) }
        func core(_ x: Int, _ y: Int) -> SIMD2<Float> {
            let p = layout.point(ArtPoint(x, y))
            return SIMD2(Float(p.x) + 0.5, Float(p.y) + 0.5)
        }
        func drag(_ from: SIMD2<Float>, _ to: SIMD2<Float>, moves: Int, rest: Int) {
            events.append((.move, from, 0))
            events.append((.down, from, 1))
            for k in 1...moves { events.append((.drag, from + (to - from) * Float(k) / Float(moves), 0)) }
            for _ in 0..<rest { events.append((.drag, to, 0)) }
            events.append((.up, to, 1))
        }
        let a = centre(screen.iconRect(of: keys[0])!), b = centre(screen.iconRect(of: keys[1])!)
        let c = centre(screen.iconRect(of: keys[2])!)
        // Set down gently on the desk; flung across it to the floor; let go over the basket.
        drag(a, core(230, 214), moves: 30, rest: 8)
        drag(b, core(320, 214), moves: 5, rest: 0)
        drag(c, core(64, 250), moves: 24, rest: 8)
        // A desk knock on the apron, left of the chair, then a hover over the new pile.
        let apron = core(100, 238)
        events += [(.move, apron, 0), (.down, apron, 1), (.up, apron, 1), (.down, apron, 2), (.up, apron, 2)]
        events.append((.move, core(230, 206), 0))
        return true
    }
}

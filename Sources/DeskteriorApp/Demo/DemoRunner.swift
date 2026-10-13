import AppKit
import DeskCore
import DeskFiles
import DeskScene
import Foundation
import Metal

/// Runs a demo script headless (DESIGN §4.11, §8.2; `docs/DEMOS.md`) through the same `DeskSession` as the app:
/// the store, mirror, effect runner (dry run: nothing reaches the system) and scene sync, with input synthesized as
/// `InputEvent`s at anchors and fed to the scene's `InputRouter`. Scene time is virtual (fixed 1/60 s frames,
/// deterministic); the mirror and icons run in real time, so `waitIdle` and `waitFor` let the main run loop turn
/// while they work. `fs` steps are performed by the harness (`scripts/run-demo.sh`, over stdin/stdout), never by
/// the app. Expectations are all checked; exit 0 pass, 1 an expectation failed, 2 script error (64 comes earlier,
/// from the folder guard).
final class DemoRunner {
    private struct ScriptError: Error, CustomStringConvertible {
        let description: String
    }

    let script: DemoScript
    let host: SceneHost
    let session: DeskSession
    let writer: ArtifactWriter?
    let scale: Int
    /// Virtual event time in seconds.
    private(set) var time: Double = 1000
    private var pointer = SIMD2<Float>(0.5, 0.5)
    private var failures: [String] = []
    private var lastMenu: MenuSpec?
    private var lastFS: Date?
    private var appCommands: [String] = []
    private let fsBridge: Bool

    /// After an `fs` step, the watcher batch (0.25 s latency + 0.25 s debounce) is waited for this long.
    static let quietPeriod = 1.0

    init(script: DemoScript, host: SceneHost, session: DeskSession, writer: ArtifactWriter?, scale: Int, fsBridge: Bool) {
        self.script = script
        self.host = host
        self.session = session
        self.writer = writer
        self.scale = scale
        self.fsBridge = fsBridge
        host.scene.onRequest = { [weak self] request in
            switch request {
            case let .menu(spec, _): self?.lastMenu = spec
            case .inventory: self?.appCommands.append("inventory")
            case let .command(c): self?.appCommands.append("\(c)")
            }
        }
    }

    // MARK: Entry

    /// Runs `--demo` on the main thread, turning the main run loop until the script finishes.
    static func runBlocking(_ options: LaunchOptions) -> Int32 {
        let box = ResultBox()
        Task { @MainActor in box.code = await run(options) }
        while box.code == nil {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return box.code ?? 2
    }

    private final class ResultBox {
        var code: Int32?
    }

    static func run(_ options: LaunchOptions) async -> Int32 {
        guard let path = options.demo else { return 2 }
        let script: DemoScript
        do {
            script = try DemoScript.decode(Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
        } catch {
            FileHandle.standardError.write(Data("Deskterior demo: cannot read \(path): \(error)\n".utf8))
            return 2
        }
        var configuration = MirrorController.configurationOrExit(options: options)
        if script.firstRun == true {
            configuration.connectImmediately = false
            configuration.finderHidesItems = script.finderHidden ?? false
        }
        var display = options.emulatedDisplay
        if let d = script.display {
            guard let parsed = LaunchOptions.EmulatedDisplay(parsing: d) else {
                FileHandle.standardError.write(Data("Deskterior demo: bad display '\(d)'\n".utf8))
                return 2
            }
            display = parsed
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write(Data("Deskterior demo: no Metal device\n".utf8))
            return 1
        }
        do {
            let grid = PixelGrid(display: display.geometry(), pixelSize: options.pixelSize)
            let host = try SceneHost(grid: grid, device: device)
            var o = options
            if let c = script.clock {
                guard let t = WallTime(parsing: c, date: SceneClock.live.now()) else { throw ScriptError(description: "bad clock '\(c)'") }
                o.clock = t
            }
            AppDelegate.configure(host, o)
            let session = DeskSession(host: host, options: o, configuration: configuration, dryRun: true,
                                      lights: script.lights, seed: script.seed)
            let writer = try options.snapshotDir.map {
                try ArtifactWriter(directory: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true),
                                   mirrored: configuration.folder)
            }
            let fsBridge = ProcessInfo.processInfo.environment["DESKTERIOR_DEMO_FS"] == "stdio"
            let runner = DemoRunner(script: script, host: host, session: session, writer: writer,
                                    scale: options.snapshotScale, fsBridge: fsBridge)
            print("demo \(script.name): \(display), S \(grid.scale), canvas \(grid.artSize)")
            return await runner.run()
        } catch {
            FileHandle.standardError.write(Data("Deskterior demo: \(error)\n".utf8))
            return 2
        }
    }

    func run() async -> Int32 {
        session.start()
        defer { session.stop() }
        do {
            for (i, step) in script.steps.enumerated() {
                try await perform(step, index: i + 1)
            }
        } catch {
            print("demo \(script.name): script error: \(error)")
            return 2
        }
        if failures.isEmpty {
            print("demo \(script.name): pass")
            return 0
        }
        for f in failures { print("demo \(script.name): FAIL \(f)") }
        return 1
    }

    // MARK: Steps

    private func perform(_ step: DemoStep, index: Int) async throws {
        switch step {
        case let .waitIdle(seconds):
            await waitIdle(seconds)
        case let .wait(seconds):
            await frames(seconds)
        case let .snapshot(name):
            try snapshot(name)
        case let .click(p):
            let at = try point(p.at)
            let mods = try modifiers(p.mods)
            send(.move, at, mods: mods)
            for n in 1...max(1, p.count) {
                send(.down, at, mods: mods, count: n)
                frame()
                send(.up, at, mods: mods, count: n)
                frame()
            }
        case let .hover(target):
            send(.move, try point(target))
        case let .drag(d):
            try await drag(d)
        case .release:
            send(.up, pointer, count: 1)
            frame()
        case let .scroll(s):
            send(.scroll, try point(s.at), scroll: SIMD2(Float(s.dx ?? 0), Float(s.dy ?? 0)))
            frame()
        case let .key(name):
            guard let command = KeyCommand(name: name) else { throw ScriptError(description: "step \(index): unknown key '\(name)'") }
            host.scene.handleKey(command)
            frame()
        case let .menu(m):
            try menu(m, index: index)
        case let .fs(op):
            try await fs(op, index: index)
        case let .action(name):
            guard let action = DemoStep.action(named: name, in: session.store.state) else {
                throw ScriptError(description: "step \(index): unknown action '\(name)'")
            }
            session.store.dispatch(action)
            frame()
        case let .expect(map):
            failures += try evaluate(map).map { "step \(index): \($0)" }
        case let .waitFor(w):
            let deadline = Date().addingTimeInterval(w.within ?? 3)
            var problems = try evaluate(w.expect)
            while !problems.isEmpty, Date() < deadline {
                if host.scene.needsFrames { frame() } else { await pause() }
                problems = try evaluate(w.expect)
            }
            failures += problems.map { "step \(index) (within \(w.within ?? 3) s): \($0)" }
        case let .comment(text):
            print("demo \(script.name): # \(text)")
        }
    }

    private func drag(_ d: DemoDrag) async throws {
        let from = try point(d.from), to = try point(d.to)
        let mods = try modifiers(d.mods ?? [])
        let n = max(2, Int(((d.duration ?? 0.4) * 60).rounded()))
        send(.move, from, mods: mods)
        send(.down, from, mods: mods, count: 1)
        frame()
        for k in 1...n {
            let t = Float(k) / Float(n)
            send(.drag, from + (to - from) * t, mods: mods)
            frame()
        }
        if d.hold != true {
            send(.up, to, mods: mods, count: 1)
            frame()
        }
    }

    private func menu(_ m: DemoMenu, index: Int) throws {
        lastMenu = nil
        send(.rightDown, try point(m.at), count: 1)
        frame()
        guard let spec = lastMenu else { throw ScriptError(description: "step \(index): no menu at \(m.at)") }
        guard let item = spec.item(m.item), let command = item.command else {
            throw ScriptError(description: "step \(index): no item '\(m.item)' in \(spec.ids)")
        }
        guard item.isEnabled else {
            failures.append("step \(index): menu item '\(m.item)' is disabled")
            return
        }
        if !session.perform(command) { appCommands.append("\(command)") }
        frame()
    }

    /// Asks the harness to change the fixture folder and waits for its answer.
    private func fs(_ op: DemoFS, index: Int) async throws {
        guard op.isValid else { throw ScriptError(description: "step \(index): fs names must be plain file names") }
        guard fsBridge else {
            throw ScriptError(description: "step \(index): fs steps need the harness (scripts/run-demo.sh)")
        }
        print("DEMO-FS\t" + op.parts.joined(separator: "\t"))
        fflush(stdout)
        let answer = await Self.readLine()
        guard answer == "ok" else { throw ScriptError(description: "step \(index): harness answered '\(answer ?? "EOF")'") }
        lastFS = Date()
    }

    private static func readLine() async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: Swift.readLine(strippingNewline: true))
            }
        }
    }

    // MARK: Time

    /// One fixed scene frame of virtual time.
    private func frame() {
        host.frameLoopStep(FrameClock.step)
        time += FrameClock.step
        host.scene.advanceInput(to: time)
    }

    private func frames(_ seconds: Double) async {
        let n = Int((seconds * 60).rounded())
        for i in 0..<n {
            frame()
            if i % 15 == 14 { await pause() }
        }
    }

    /// Lets the main run loop take mirror and icon callbacks.
    private func pause() async {
        try? await Task.sleep(for: .milliseconds(8))
    }

    /// Runs until nothing animates, no tooltip is due, the mirror has delivered what was asked and gone quiet,
    /// and icons have arrived; at most `seconds` of real time.
    private func waitIdle(_ seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        var stepped = 0
        while Date() < deadline {
            if host.scene.needsFrames {
                frame()
                stepped += 1
                if stepped % 20 == 0 { await pause() }
                continue
            }
            if let due = host.scene.nextInputDeadline {
                time = max(time, due)
                host.scene.advanceInput(to: time)
                continue
            }
            if busy() {
                await pause()
                continue
            }
            break
        }
        frame()
    }

    private func busy() -> Bool {
        if session.mirror.awaitingScan { return true }
        if let icons = session.icons, !icons.isIdle { return true }
        let now = Date()
        if let t = lastFS, now.timeIntervalSince(t) < Self.quietPeriod { return true }
        if let t = session.mirror.lastEventAt, now.timeIntervalSince(t) < 0.1 { return true }
        return false
    }

    // MARK: Input

    private func send(_ kind: InputEvent.Kind, _ p: SIMD2<Float>, mods: InputEvent.Modifiers = [], count: Int = 0,
                      scroll: SIMD2<Float> = .zero) {
        pointer = p
        host.scene.handle(InputEvent(kind, art: p, mods: mods, clickCount: count, scroll: scroll, t: time))
    }

    private func modifiers(_ names: [String]) throws -> InputEvent.Modifiers {
        var m: InputEvent.Modifiers = []
        for n in names {
            switch n.lowercased() {
            case "cmd", "command": m.insert(.command)
            case "shift": m.insert(.shift)
            case "opt", "option", "alt": m.insert(.option)
            case "ctrl", "control": m.insert(.control)
            default: throw ScriptError(description: "unknown modifier '\(n)'")
            }
        }
        return m
    }

    /// The canvas point (pixel centre) of a target (see `DemoPointer`).
    private func point(_ target: String) throws -> SIMD2<Float> {
        guard let layout = host.scene.layout, let screen = host.scene.screen else {
            throw ScriptError(description: "no room to point at")
        }
        func center(_ r: ArtRect) -> SIMD2<Float> { SIMD2(Float(r.midX) + 0.5, Float(r.midY) + 0.5) }
        func pair(_ s: Substring) throws -> (Int, Int) {
            let v = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 2 else { throw ScriptError(description: "bad coordinates in '\(target)'") }
            return (v[0], v[1])
        }
        if target.hasPrefix("token:") {
            let name = String(target.dropFirst(6))
            guard let key = tokenKey(named: name) else { throw ScriptError(description: "no token named '\(name)'") }
            guard let r = screen.iconRect(of: key) ?? host.scene.miniRect(of: key) else {
                throw ScriptError(description: "token '\(name)' is not on show")
            }
            return center(r)
        }
        if target.hasPrefix("cell:") {
            let (c, r) = try pair(target.dropFirst(5))
            return center(screen.cellRect(c, r))
        }
        if target.hasPrefix("core:") {
            let (x, y) = try pair(target.dropFirst(5))
            let p = layout.point(ArtPoint(x, y))
            return SIMD2(Float(p.x) + 0.5, Float(p.y) + 0.5)
        }
        if target.hasPrefix("point:") {
            let (x, y) = try pair(target.dropFirst(6))
            return SIMD2(Float(x) + 0.5, Float(y) + 0.5)
        }
        if target.hasPrefix("card.") {
            guard let r = host.scene.monitor?.cardButtons[target] else { throw ScriptError(description: "no card button '\(target)'") }
            return center(r)
        }
        if target == "screen.empty" {
            guard let r = screen.firstEmptyCell() else { throw ScriptError(description: "no empty cell on the page") }
            return center(r)
        }
        guard let r = host.scene.liveAnchor(target) ?? layout.anchors[target] else {
            throw ScriptError(description: "unknown target '\(target)'")
        }
        return center(r)
    }

    private func tokenKey(named name: String) -> TokenKey? {
        let s = session.store.state
        let nfc = TextLayout.nfc(name)
        return s.tokens.sortedKeys.first { s.tokens.meta(of: $0)?.displayName == nfc }
    }

    // MARK: Snapshots and expectations

    private func snapshot(_ name: String) throws {
        host.presenter.renderOffscreen(wait: true)
        let frame = try host.presenter.readLitFrame()
        let foreign = frame.pixels.reduce(0) { $0 + (Apollo.index(of: $1) == nil ? 1 : 0) }
        if foreign > 0 { failures.append("snapshot \(name): \(foreign) pixels are not Apollo colours") }
        guard let writer else {
            print("demo \(script.name): snapshot \(name) (no --snapshot-dir)")
            return
        }
        for png in Snapshotter.pngs(frame, name: name, scale: scale) {
            print("wrote \(try writer.write(png.data, named: png.name).path)")
        }
    }

    /// Failed expectations as messages (unknown keys and bad values are script errors).
    private func evaluate(_ expect: [String: DemoValue]) throws -> [String] {
        let s = session.store.state
        let scene = host.scene
        let machine = scene.monitor?.machine
        var out: [String] = []
        func check(_ key: String, _ actual: String, _ expected: DemoValue) {
            if actual != expected.text { out.append("\(key) is \(actual), expected \(expected.text)") }
        }
        for (key, value) in expect.sorted(by: { $0.key < $1.key }) {
            switch key {
            case let k where k.hasPrefix("token:"):
                let name = String(k.dropFirst(6))
                guard let pattern = LocationPattern(value.text) else {
                    throw ScriptError(description: "bad location pattern '\(value.text)'")
                }
                let loc = tokenKey(named: name).flatMap { s.tokens.location(of: $0) }
                if !pattern.matches(loc) { out.append("\(name) is \(loc.map { "\($0)" } ?? "missing"), expected \(value.text)") }
            case "hidden":
                guard case let .bool(hidden) = value else { throw ScriptError(description: "hidden takes true or false") }
                for name in expect.keys.filter({ $0.hasPrefix("token:") }).map({ String($0.dropFirst(6)) }) {
                    guard let k = tokenKey(named: name), let loc = s.tokens.location(of: k) else { continue }
                    let isHidden = Visibility.of(loc, s).isHidden
                    if isHidden != hidden { out.append("\(name) hidden is \(isHidden), expected \(hidden)") }
                }
            case "monitor.power": check(key, s.monitor.power.rawValue, value)
            case "monitor.input": check(key, s.monitor.av ? "AV" : "HDMI \(s.monitor.page + 1)", value)
            case "monitor.pendingNew": check(key, String(s.monitor.pendingNew), value)
            case "monitor.overlay": check(key, machine?.overlay.rawValue ?? "none", value)
            case "monitor.phase": check(key, machine?.phase.rawValue ?? "none", value)
            case "monitor.led": check(key, machine?.led.rawValue ?? "none", value)
            case "monitor.badge": check(key, machine?.badge ?? "none", value)
            case "access": check(key, s.access.rawValue, value)
            case "tokens": check(key, String(s.tokens.count), value)
            case "screen.tokens": check(key, String(scene.screen?.visibleTokenCount ?? 0), value)
            case "pages": check(key, String(s.pageCount()), value)
            case "selection": check(key, String(scene.selection?.count ?? 0), value)
            case "undo": check(key, session.store.undoLabel ?? "none", value)
            case "effect": check(key, session.effects.fileLog.last ?? "none", value)
            case "toast": check(key, scene.toastShown?.rawValue ?? "none", value)
            case "tooltip":
                let title = scene.tooltipShown?.title ?? "none"
                if !(title == value.text || (value.text != "none" && title.contains(TextLayout.nfc(value.text)))) {
                    out.append("tooltip is \(title), expected \(value.text)")
                }
            case "hover":
                let name = scene.screen?.hovered.flatMap { s.tokens.meta(of: $0)?.displayName } ?? "none"
                check(key, name, DemoValue.string(TextLayout.nfc(value.text)))
            case "carrying": check(key, String(scene.isDragging), value)
            case "bonks": check(key, String(scene.bonkCount), value)
            case "command": check(key, appCommands.last ?? "none", value)
            // MARK: containers (M6)
            case let k where k.hasPrefix("drawer:"):
                guard let id = ContainerID(rawValue: String(k.dropFirst(7))), id.isDrawer else {
                    throw ScriptError(description: "no drawer '\(k.dropFirst(7))'")
                }
                let p = s.drawerOpening(id)
                check(key, p >= Visibility.drawerOpen ? "open" : (p > 0 ? "ajar" : "closed"), value)
            case "phone": check(key, s.phone.faceDown ? "faceDown" : "faceUp", value)
            case "minis": check(key, String(scene.containerMinis.count), value)
            case "chair.blocksCabinet":
                check(key, String(DrawerSim.cabinetOpenLimit(travel: 12, chairX: s.chair.x) < 12), value)
            default:
                throw ScriptError(description: "unknown expectation '\(key)'")
            }
        }
        return out
    }
}

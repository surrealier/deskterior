import DeskCore
import DeskScene
import Foundation

/// Command-line flags (DESIGN §4.11). Every flag can also come from `DESKTERIOR_<FLAG>` in the environment
/// (`--snapshot-dir` → `DESKTERIOR_SNAPSHOT_DIR`; switches take `1`/`true`/`yes`); flags win over the environment.
struct LaunchOptions: Equatable {
    /// A display emulated by `--windowed` and by headless runs.
    struct EmulatedDisplay: Equatable, CustomStringConvertible {
        var widthPt: Int
        var heightPt: Int
        var scale: Double

        /// This Mac's default "looks like" mode.
        static let standard = EmulatedDisplay(widthPt: 1470, heightPt: 956, scale: 2)
        /// The menu bar the emulation reserves at the top (this Mac's notched menu bar, SPIKES).
        static let menuBarPt = 33.0

        init(widthPt: Int, heightPt: Int, scale: Double) {
            self.widthPt = widthPt
            self.heightPt = heightPt
            self.scale = scale
        }

        /// Parses `WxH` or `WxH@scale` (points; scale 1…4).
        init?(parsing s: String) {
            let parts = s.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            let size = parts[0].split(separator: "x", omittingEmptySubsequences: false)
            guard size.count == 2, let w = Int(size[0]), let h = Int(size[1]), w >= 64, h >= 64 else { return nil }
            var scale = 1.0
            if parts.count == 2 {
                guard let v = Double(parts[1]), v >= 1, v <= 4 else { return nil }
                scale = v
            }
            self.init(widthPt: w, heightPt: h, scale: scale)
        }

        /// The geometry `PixelGrid` sees at `widthPt`×`heightPt` points (the window's current content size;
        /// defaults to the emulated size).
        func geometry(widthPt: Double? = nil, heightPt: Double? = nil) -> DisplayGeometry {
            DisplayGeometry(
                widthPt: widthPt ?? Double(self.widthPt), heightPt: heightPt ?? Double(self.heightPt),
                backingScale: scale, topInsetPt: Self.menuBarPt
            )
        }

        var description: String {
            let s = scale == scale.rounded() ? String(Int(scale)) : String(scale)
            return "\(widthPt)x\(heightPt)@\(s)"
        }
    }

    enum Level: String, CaseIterable {
        case iconPlus1 = "icon+1"
        case iconPlus3 = "icon+3"
        case normal
    }

    enum Mode {
        case desk, windowed, headless
    }

    /// Where token icons come from: real pixelated icons (default), or the kind icons only (deterministic).
    enum Icons: String, CaseIterable {
        case kind, live
    }

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    var windowed: EmulatedDisplay?
    var headless = false
    var frames = 30
    var snapshotDir: String?
    var snapshotScale = 3
    var level = Level.iconPlus1
    var printWindowID = false
    var exitAfter: Double?
    var pixelSize = PixelSize.normal
    /// The folder to mirror (required, and never the real desktop, outside desk mode).
    var desktopFolder: String?
    /// Layout, icon cache and log folder (default: the app's own, or a temporary one outside desk mode).
    var stateDir: String?
    /// `--demo FILE`: run a demo script headless (implies `--headless`).
    var demo: String?
    /// `--seed N`: reducer randomness (demo scripts may set their own).
    var seed: UInt64?
    var icons = Icons.live
    var showHelp = false
    var showVersion = false
    /// `--clock HH:MM` (today's date) or an ISO 8601 local date-time; nil follows the real clock.
    var clock: WallTime?
    /// `--calibration`: the M2 calibration card instead of the room.
    var calibration = false
    /// `--lights auto|day|night|lamp`.
    var lights = LightsMode.auto
    /// `--reduce-motion`: skip flickers, jiggles, spring-backs and the CRT, whatever the system says.
    var reduceMotion = false
    /// `--burst`: windowed only, a short scripted interaction burst, then idle (`scripts/measure-idle.sh`).
    var burst = false
    // MARK: system (M12)
    /// `--safe-mode` (or ⌥ held at launch): the Safe Mode window before the desk starts.
    var safeMode = false
    /// `--language system|en|ko`: the language outside desk mode (desk mode follows Settings).
    var language: LanguageSetting?
    /// `--show settings,about,onboarding,translocation,peek,inventory`: windowed only, open these at launch.
    var show: Set<String> = []
    /// `--window-shots DIR`: windowed only, write PNGs of the app's open windows (Settings, About…) here.
    var windowShots: String?
    /// `--pixel-size` / `--level` were given: they win over Settings ▸ Pixel size and the `windowLevel` setting.
    var pixelSizeGiven = false
    var levelGiven = false
    // MARK: release (M13)
    /// `--demo-record DIR`: a demo also writes every `demoRecordEvery`-th scene frame here (`FrameRecorder`).
    var demoRecord: String?
    var demoRecordEvery = 3
    // MARK: harden
    /// `--burst-av`: the burst ends with the monitor on AV, its logo bouncing (`measure-idle.sh --av`).
    var burstAV = false

    var mode: Mode { headless || demo != nil ? .headless : (windowed != nil ? .windowed : .desk) }
    /// The scene's time source.
    var sceneClock: SceneClock { clock.map { .fixed($0) } ?? .live }
    /// The display `--windowed` and `--headless` emulate.
    var emulatedDisplay: EmulatedDisplay { windowed ?? .standard }

    static let usage = """
        Usage: Deskterior [options]          (no options: desk mode on the menu-bar display)
          --windowed [WxH[@scale]]   titled window emulating a display (default 1470x956@2)
          --headless                 render offscreen and exit (with --snapshot-dir to write PNGs)
          --frames N                 headless: fixed frames to step (default 30)
          --snapshot-dir DIR         headless: write room-<display>-<HHMM>.png (and @<N>x) here
          --snapshot-scale N         headless: nearest-neighbour factor of the second PNG (default 3)
          --level icon+1|icon+3|normal   desk window level (default: the windowLevel setting, icon+1)
          --pixel-size chunky|normal|fine   (default: Settings ▸ Pixel size, normal)
          --clock HH:MM|ISO8601      fixed room time (sky, light, clock face)
          --lights auto|day|night|lamp   lights mode (lamp = Lamp Only)
          --reduce-motion            no flickers, jiggles, spring-backs or CRT animation
          --calibration              show the M2 calibration card instead of the room
          --print-window-id          print the window number (for screencapture -l)
          --exit-after SECONDS       quit after this long
          --desktop-folder DIR       mirror this folder (required outside desk mode; never the real Desktop)
          --state-dir DIR            layout, icon cache and log folder
          --demo FILE                run a demo script headless (snapshots with --snapshot-dir)
          --seed N                   reducer randomness
          --icons kind|live          kind icons only, or pixelated real icons (default live)
          --burst                    windowed: a short scripted interaction burst, then idle (measure-idle.sh)
          --burst-av                 with --burst: end it on the monitor's AV input, its logo bouncing
          --safe-mode                start with the Safe Mode window (also: hold ⌥ while Deskterior launches)
          --language system|en|ko    the language outside desk mode (desk mode follows Settings)
          --show LIST                windowed: open settings,about,onboarding,translocation,peek,inventory
          --window-shots DIR         windowed: write PNGs of the open app windows to DIR (with --show)
          --demo-record DIR          with --demo: write frame-NNNNN.png (art px, pointer drawn) to DIR
          --demo-record-every N      with --demo-record: every Nth scene frame (default 3, 20 fps)
          --version, --help
        Every option can also be set as DESKTERIOR_<NAME> in the environment, e.g. DESKTERIOR_SNAPSHOT_DIR.
        """

    /// Parses `arguments` (without the executable) over `environment`.
    static func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> LaunchOptions {
        var o = LaunchOptions()
        for spec in specs {
            guard let raw = environment[spec.environmentKey], !raw.isEmpty else { continue }
            switch spec.arity {
            case .switch:
                guard let on = parseBool(raw) else {
                    throw UsageError(description: "\(spec.environmentKey) must be 1/0, true/false or yes/no")
                }
                if on { try spec.apply(&o, nil) }
            case .optionalValue:
                try spec.apply(&o, parseBool(raw) == true ? nil : raw)
            case .value:
                try spec.apply(&o, raw)
            }
        }

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            i += 1
            let (name, inline) = splitInline(arg)
            guard let spec = specs.first(where: { $0.names.contains(name) }) else {
                throw UsageError(description: "unknown option '\(arg)'")
            }
            switch spec.arity {
            case .switch:
                guard inline == nil else { throw UsageError(description: "\(name) takes no value") }
                try spec.apply(&o, nil)
            case .value:
                if let inline {
                    try spec.apply(&o, inline)
                } else {
                    guard i < arguments.count else { throw UsageError(description: "\(name) needs a value") }
                    try spec.apply(&o, arguments[i])
                    i += 1
                }
            case .optionalValue:
                if let inline {
                    try spec.apply(&o, inline)
                } else if i < arguments.count, !arguments[i].hasPrefix("-") {
                    try spec.apply(&o, arguments[i])
                    i += 1
                } else {
                    try spec.apply(&o, nil)
                }
            }
        }
        return o
    }

    // MARK: Specs

    private enum Arity {
        case `switch`, value, optionalValue
    }

    private struct Spec {
        let names: [String]
        let arity: Arity
        let apply: (inout LaunchOptions, String?) throws -> Void

        /// `--snapshot-dir` → `DESKTERIOR_SNAPSHOT_DIR`.
        var environmentKey: String {
            "DESKTERIOR_" + names[0].dropFirst(2).uppercased().replacingOccurrences(of: "-", with: "_")
        }
    }

    private static let specs: [Spec] = [
        Spec(names: ["--windowed"], arity: .optionalValue) { o, v in
            guard let v else { o.windowed = .standard; return }
            guard let d = EmulatedDisplay(parsing: v) else {
                throw UsageError(description: "--windowed expects WxH or WxH@scale, got '\(v)'")
            }
            o.windowed = d
        },
        Spec(names: ["--headless"], arity: .switch) { o, _ in o.headless = true },
        Spec(names: ["--frames"], arity: .value) { o, v in o.frames = try int(v, "--frames", min: 0) },
        Spec(names: ["--snapshot-dir"], arity: .value) { o, v in o.snapshotDir = v },
        Spec(names: ["--snapshot-scale"], arity: .value) { o, v in
            o.snapshotScale = try int(v, "--snapshot-scale", min: 1)
        },
        Spec(names: ["--level"], arity: .value) { o, v in
            guard let v, let level = Level(rawValue: v) else {
                throw UsageError(description: "--level expects icon+1, icon+3 or normal")
            }
            o.level = level
            o.levelGiven = true
        },
        Spec(names: ["--print-window-id"], arity: .switch) { o, _ in o.printWindowID = true },
        Spec(names: ["--exit-after"], arity: .value) { o, v in
            guard let v, let s = Double(v), s > 0, s.isFinite else {
                throw UsageError(description: "--exit-after expects a positive number of seconds")
            }
            o.exitAfter = s
        },
        Spec(names: ["--pixel-size"], arity: .value) { o, v in
            guard let v, let size = PixelSize(rawValue: v) else {
                throw UsageError(description: "--pixel-size expects chunky, normal or fine")
            }
            o.pixelSize = size
            o.pixelSizeGiven = true
        },
        Spec(names: ["--clock"], arity: .value) { o, v in
            guard let v, let t = WallTime(parsing: v, date: SceneClock.live.now()) else {
                throw UsageError(description: "--clock expects HH:MM or an ISO 8601 date-time")
            }
            o.clock = t
        },
        Spec(names: ["--lights"], arity: .value) { o, v in
            guard let v, let mode = LightsMode(rawValue: v) else {
                throw UsageError(description: "--lights expects auto, day, night or lamp")
            }
            o.lights = mode
        },
        Spec(names: ["--calibration"], arity: .switch) { o, _ in o.calibration = true },
        Spec(names: ["--reduce-motion"], arity: .switch) { o, _ in o.reduceMotion = true },
        Spec(names: ["--desktop-folder"], arity: .value) { o, v in o.desktopFolder = v },
        Spec(names: ["--demo"], arity: .value) { o, v in o.demo = v },
        Spec(names: ["--seed"], arity: .value) { o, v in
            guard let v, let n = UInt64(v) else { throw UsageError(description: "--seed expects a non-negative integer") }
            o.seed = n
        },
        Spec(names: ["--icons"], arity: .value) { o, v in
            guard let v, let icons = Icons(rawValue: v) else { throw UsageError(description: "--icons expects kind or live") }
            o.icons = icons
        },
        Spec(names: ["--state-dir"], arity: .value) { o, v in o.stateDir = v },
        Spec(names: ["--burst"], arity: .switch) { o, _ in o.burst = true },
        // MARK: system (M12)
        Spec(names: ["--safe-mode"], arity: .switch) { o, _ in o.safeMode = true },
        Spec(names: ["--language"], arity: .value) { o, v in
            guard let v, let l = LanguageSetting(rawValue: v) else {
                throw UsageError(description: "--language expects system, en or ko")
            }
            o.language = l
        },
        Spec(names: ["--show"], arity: .value) { o, v in
            let known: Set<String> = ["settings", "about", "onboarding", "translocation", "peek", "inventory"]
            let names = Set((v ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            guard !names.isEmpty, names.isSubset(of: known) else {
                throw UsageError(description: "--show expects a list of \(known.sorted().joined(separator: ", "))")
            }
            o.show = names
        },
        Spec(names: ["--window-shots"], arity: .value) { o, v in o.windowShots = v },
        // MARK: release (M13)
        Spec(names: ["--demo-record"], arity: .value) { o, v in o.demoRecord = v },
        Spec(names: ["--demo-record-every"], arity: .value) { o, v in
            o.demoRecordEvery = try int(v, "--demo-record-every", min: 1)
        },
        // MARK: harden
        Spec(names: ["--burst-av"], arity: .switch) { o, _ in o.burstAV = true },
        Spec(names: ["--help", "-h"], arity: .switch) { o, _ in o.showHelp = true },
        Spec(names: ["--version"], arity: .switch) { o, _ in o.showVersion = true },
    ]

    private static func int(_ v: String?, _ name: String, min lo: Int) throws -> Int {
        guard let v, let n = Int(v), n >= lo else {
            throw UsageError(description: "\(name) expects an integer ≥ \(lo)")
        }
        return n
    }

    private static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "1", "true", "yes": true
        case "0", "false", "no": false
        default: nil
        }
    }

    /// `--name=value` → (`--name`, `value`).
    private static func splitInline(_ arg: String) -> (String, String?) {
        guard arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") else { return (arg, nil) }
        return (String(arg[..<eq]), String(arg[arg.index(after: eq)...]))
    }
}

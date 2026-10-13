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
          --level icon+1|icon+3|normal   desk window level (default icon+1)
          --pixel-size chunky|normal|fine
          --clock HH:MM|ISO8601      fixed room time (sky, light, clock face)
          --lights auto|day|night|lamp   lights mode (lamp = Lamp Only)
          --calibration              show the M2 calibration card instead of the room
          --print-window-id          print the window number (for screencapture -l)
          --exit-after SECONDS       quit after this long
          --desktop-folder DIR       mirror this folder (required outside desk mode; never the real Desktop)
          --state-dir DIR            layout, icon cache and log folder
          --demo FILE                run a demo script headless (snapshots with --snapshot-dir)
          --seed N                   reducer randomness
          --icons kind|live          kind icons only, or pixelated real icons (default live)
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

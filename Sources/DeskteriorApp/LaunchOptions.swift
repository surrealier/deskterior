import DeskCore
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
    /// Parsed and stored only in M2.
    var desktopFolder: String?
    /// Parsed and stored only in M2.
    var stateDir: String?
    var showHelp = false
    var showVersion = false

    var mode: Mode { headless ? .headless : (windowed != nil ? .windowed : .desk) }
    /// The display `--windowed` and `--headless` emulate.
    var emulatedDisplay: EmulatedDisplay { windowed ?? .standard }

    static let usage = """
        Usage: Deskterior [options]          (no options: desk mode on the menu-bar display)
          --windowed [WxH[@scale]]   titled window emulating a display (default 1470x956@2)
          --headless                 render offscreen and exit (with --snapshot-dir to write PNGs)
          --frames N                 headless: fixed frames to step (default 30)
          --snapshot-dir DIR         headless: write calibration.png and calibration@<N>x.png here
          --snapshot-scale N         headless: nearest-neighbour factor of the second PNG (default 3)
          --level icon+1|icon+3|normal   desk window level (default icon+1)
          --pixel-size chunky|normal|fine
          --print-window-id          print the window number (for screencapture -l)
          --exit-after SECONDS       quit after this long
          --desktop-folder DIR, --state-dir DIR   (reserved; unused in this build)
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
        Spec(names: ["--desktop-folder"], arity: .value) { o, v in o.desktopFolder = v },
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

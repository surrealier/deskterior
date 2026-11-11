import DeskCore
import DeskFiles
import Foundation

/// Command-line options of `Deskterior.exe` (docs/WINDOWS.md WP6).
///
///     Deskterior [--desktop-folder <path>] [--state-folder <path>] [--connect] [--windowed]
///     Deskterior --snapshot <out.png> [--desktop-folder <path>] [--size <w>x<h>] [--scale <s>] [--frames <n>]
///
/// `--snapshot` renders the desk headless (no window, no GPU) after `--frames` simulation steps and writes the
/// frame as the display would show it; it scans the folder once and changes nothing. CI runs it on Windows.
struct WinOptions: Equatable {
    var folder: String?
    var stateFolder: String?
    var connect = false
    var windowed = false
    var snapshot: String?
    var width = 1280
    var height = 800
    var scale = 1.0
    var frames = 90
    var language: String?
    /// Closes the window after this many seconds and exits 0 when frames were shown (CI's smoke test).
    var quitAfter: Double?
    var help = false

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        case badValue(String, String)

        var description: String {
            switch self {
            case let .unknown(a): "unknown option \(a)"
            case let .missingValue(a): "\(a) needs a value"
            case let .badValue(a, v): "bad value for \(a): \(v)"
            }
        }
    }

    static let usage = """
        usage: Deskterior [--desktop-folder <path>] [--state-folder <path>] [--connect] [--language en|ko]
                          [--size <w>x<h>] [--quit-after <seconds>]
               Deskterior --snapshot <out.png> [--desktop-folder <path>] [--size <w>x<h>] [--scale <s>] [--frames <n>]
        """

    static func parse(_ arguments: [String]) throws(Failure) -> WinOptions {
        var o = WinOptions()
        var i = 0
        func value(_ name: String) throws(Failure) -> String {
            i += 1
            guard i < arguments.count else { throw .missingValue(name) }
            return arguments[i]
        }
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--desktop-folder": o.folder = try value(a)
            case "--state-folder": o.stateFolder = try value(a)
            case "--connect": o.connect = true
            case "--windowed": o.windowed = true
            case "--snapshot": o.snapshot = try value(a)
            case "--language": o.language = try value(a)
            case "--quit-after":
                let v = try value(a)
                guard let s = Double(v), s > 0, s <= 3600 else { throw .badValue(a, v) }
                o.quitAfter = s
            case "--frames":
                let v = try value(a)
                guard let n = Int(v), n >= 0, n <= 100_000 else { throw .badValue(a, v) }
                o.frames = n
            case "--scale":
                let v = try value(a)
                guard let s = Double(v), s >= 0.5, s <= 4 else { throw .badValue(a, v) }
                o.scale = s
            case "--size":
                let v = try value(a)
                let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, (320...16384).contains(parts[0]), (200...16384).contains(parts[1]) else {
                    throw .badValue(a, v)
                }
                (o.width, o.height) = (parts[0], parts[1])
            case "-h", "--help": o.help = true
            default: throw .unknown(a)
            }
            i += 1
        }
        return o
    }

    /// The folder to mirror: `--desktop-folder`, the environment overrides, else the user's desktop.
    func resolvedFolder(environment: [String: String]) -> URL {
        DesktopLocator.resolve(override: folder, environment: environment).url
    }

    /// The pixel grid for a `width`×`height` client area at `scale` device px per point.
    static func grid(width: Int, height: Int, scale: Double) -> PixelGrid {
        let display = DisplayGeometry(
            frameWidthPx: width, frameHeightPx: height, visibleRectPx: DeviceRect(0, 0, width, height),
            backingScale: scale
        )
        return PixelGrid(display: display)
    }
}

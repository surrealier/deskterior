/// A local wall-clock reading (no time zone; the app converts `Date` → components). Pure and Sendable so
/// lighting, the clock face, the window sky and the calendar are deterministic in tests.
public struct WallTime: Hashable, Sendable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int

    public init(year: Int = 2026, month: Int = 10, day: Int = 14, hour: Int, minute: Int) {
        self.year = year
        self.month = min(max(month, 1), 12)
        self.day = min(max(day, 1), 31)
        self.hour = ((hour % 24) + 24) % 24
        self.minute = ((minute % 60) + 60) % 60
    }

    /// Minutes since local midnight (0…1439).
    public var minuteOfDay: Int { hour * 60 + minute }

    /// Parses `HH:MM` (date fields from `date`) or an ISO 8601 local date-time `YYYY-MM-DDTHH:MM[:SS]`
    /// (a trailing zone designator is ignored: the wall reading is used as is). Nil when malformed.
    public init?(parsing s: String, date: WallTime? = nil) {
        let parts = s.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        var y = date?.year ?? 2026, mo = date?.month ?? 10, d = date?.day ?? 14
        let timePart: Substring
        if parts.count == 2 {
            let ymd = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard ymd.count == 3, let yy = Int(ymd[0]), let mm = Int(ymd[1]), let dd = Int(ymd[2]),
                  (1...12).contains(mm), (1...31).contains(dd)
            else { return nil }
            (y, mo, d) = (yy, mm, dd)
            timePart = parts[1]
        } else {
            timePart = parts[0]
        }
        let clock = timePart.prefix { $0.isNumber || $0 == ":" }
        let hm = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard hm.count >= 2, hm.count <= 3, let h = Int(hm[0]), let m = Int(hm[1]),
              (0...23).contains(h), (0...59).contains(m), hm[0].count <= 2, hm[1].count == 2
        else { return nil }
        if hm.count == 3 { guard let sec = Int(hm[2]), (0...60).contains(sec) else { return nil } }
        let rest = timePart.dropFirst(clock.count)
        guard rest.isEmpty || rest == "Z" || rest.first == "+" || rest.first == "-" || rest.first == "." else {
            return nil
        }
        self.init(year: y, month: mo, day: d, hour: h, minute: m)
    }

    /// Day of the week for the date, 0 = Sunday (Sakamoto's method).
    public var weekday: Int {
        let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let yy = month < 3 ? year - 1 : year
        return (yy + yy / 4 - yy / 100 + yy / 400 + t[month - 1] + day) % 7
    }

    /// Days in the month of the date.
    public var daysInMonth: Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    public var description: String {
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(year)-\(two(month))-\(two(day)) \(two(hour)):\(two(minute))"
    }
}

/// Phase of the day (DESIGN §1.4): day 08–17, dusk 17–19, night 19–06, dawn 06–08.
public enum DayPhase: String, Hashable, Sendable, CaseIterable {
    case dawn, day, dusk, night
}

/// What the window shows.
public enum SkyVariant: String, Hashable, Sendable, CaseIterable {
    case day, dusk, dawn, night
}

/// The Lights setting (DESIGN §4.9): follow the clock, force a phase, or Lamp Only. Persisted in `desk.json`
/// (`lights.mode`) and the settings by raw value, which is also the `--lights` launch flag spelling.
public enum LightsMode: String, Codable, Hashable, Sendable, CaseIterable {
    case auto, day, night
    /// Night, room light off, lamp on.
    case lampOnly = "lamp"
}

/// The light state of the room at one moment: phase, sky and the lit pass's ambient level (DESIGN §1.4 table).
public struct TimeOfDay: Hashable, Sendable {
    public let phase: DayPhase
    /// 0…1 through the current phase (dawn/dusk ramps use it).
    public let progress: Double
    public let roomLightOn: Bool
    /// Ambient level 0…7 for the lit pass.
    public let ambientLevel: Int
    /// Ambient tint (warm only under the room light at night).
    public let ambientTint: Tint

    public init(phase: DayPhase, progress: Double = 0.5, roomLightOn: Bool) {
        self.phase = phase
        self.progress = min(max(progress, 0), 1)
        self.roomLightOn = roomLightOn
        (ambientLevel, ambientTint) = Self.ambient(phase: phase, progress: self.progress, roomLightOn: roomLightOn)
    }

    /// Phase and progress for a minute of the day.
    public init(minuteOfDay m: Int, roomLightOn: Bool) {
        let p = Self.phase(minuteOfDay: m)
        self.init(phase: p.phase, progress: p.progress, roomLightOn: roomLightOn)
    }

    public init(_ time: WallTime, roomLightOn: Bool) {
        self.init(minuteOfDay: time.minuteOfDay, roomLightOn: roomLightOn)
    }

    /// The room for a Lights mode: `auto` follows `time`; `day`/`night` force the phase; `lampOnly` is night
    /// with the room light off (the lamp itself is the caller's state).
    public init(_ time: WallTime, mode: LightsMode, roomLightOn: Bool) {
        switch mode {
        case .auto: self.init(time, roomLightOn: roomLightOn)
        case .day: self.init(phase: .day, roomLightOn: roomLightOn)
        case .night: self.init(phase: .night, roomLightOn: roomLightOn)
        case .lampOnly: self.init(phase: .night, roomLightOn: false)
        }
    }

    public var sky: SkyVariant {
        switch phase {
        case .day: .day
        case .dusk: .dusk
        case .dawn: .dawn
        case .night: .night
        }
    }

    public var ambient: AmbientLevel { AmbientLevel(level: ambientLevel, tint: ambientTint) }

    /// True when it is dark enough that lamps, screens and string lights visibly glow.
    public var isDark: Bool { ambientLevel < 7 }

    // MARK: Tables

    /// `(phase, progress)` for a minute of the day.
    public static func phase(minuteOfDay raw: Int) -> (phase: DayPhase, progress: Double) {
        let m = ((raw % 1440) + 1440) % 1440
        switch m {
        case 360..<480: return (.dawn, Double(m - 360) / 120)
        case 480..<1020: return (.day, Double(m - 480) / 540)
        case 1020..<1140: return (.dusk, Double(m - 1020) / 120)
        default:
            let since = m >= 1140 ? m - 1140 : m + 300
            return (.night, Double(since) / 660)
        }
    }

    /// The §1.4 table. Room light on: 7 (6 warm at night). Off: day 6, dusk 5→3, dawn 3→5, night 1.
    public static func ambient(phase: DayPhase, progress: Double, roomLightOn: Bool) -> (Int, Tint) {
        if roomLightOn { return phase == .night ? (6, .warm) : (7, .cool) }
        switch phase {
        case .day: return (6, .cool)
        case .dusk: return (5 - Int((progress * 3).rounded(.down)).clamped(0, 2), .cool)
        case .dawn: return (3 + Int((progress * 3).rounded(.down)).clamped(0, 2), .cool)
        case .night: return (1, .cool)
        }
    }
}

/// An ambient level and tint, mirrored by DeskScene's `AmbientLight`.
public struct AmbientLevel: Hashable, Sendable {
    public var level: Int
    public var tint: Tint
}

fileprivate extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

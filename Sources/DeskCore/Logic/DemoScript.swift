import Foundation

/// A scripted demo (`Demos/*.json`; DESIGN §4.11, §8.2, `docs/DEMOS.md`). The app's `DemoRunner` drives its steps
/// through the same input router and store as real input (no CGEvents), takes snapshots and checks `expect`
/// steps. Exit codes: 0 pass, 1 expectation failed, 2 script error, 64 guard refusal.
public struct DemoScript: Codable, Sendable, Equatable {
    public var name: String
    /// Emulated display in points, `WxH` or `WxH@scale` (default 1470x956@2).
    public var display: String?
    /// Fixed room time, `HH:MM` or ISO 8601 (default: the real clock).
    public var clock: String?
    public var lights: LightsMode?
    public var seed: UInt64?
    /// Start like a first launch: the connect prompt instead of an immediate scan.
    public var firstRun: Bool?
    /// With `firstRun`: pretend Finder hides desktop items (the DESKTOP HIDDEN card).
    public var finderHidden: Bool?
    public var steps: [DemoStep]

    public init(name: String, steps: [DemoStep]) {
        self.name = name
        self.steps = steps
    }

    public static func decode(_ data: Data) throws -> DemoScript {
        try JSONDecoder().decode(DemoScript.self, from: data)
    }
}

/// A pointer target and how to press it: `"monitor.power"`, or `{"at": "token:a.txt", "mods": ["cmd"], "count": 2}`.
///
/// Targets: an anchor name (`monitor.power`, `wastebasket.mouth`…), `token:<name>` (a token's centre on screen),
/// `cell:<col>,<row>` (a cell of the current page), `core:<x>,<y>` (core px), `point:<x>,<y>` (canvas px), or
/// `card.<button>` (a button on a monitor card).
public struct DemoPointer: Codable, Sendable, Equatable {
    public var at: String
    public var mods: [String]
    public var count: Int

    public init(at: String, mods: [String] = [], count: Int = 1) {
        self.at = at
        self.mods = mods
        self.count = count
    }

    private enum Key: String, CodingKey { case at, mods, count }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.init(at: s)
            return
        }
        let c = try decoder.container(keyedBy: Key.self)
        self.init(at: try c.decode(String.self, forKey: .at), mods: try c.decodeIfPresent([String].self, forKey: .mods) ?? [],
                  count: try c.decodeIfPresent(Int.self, forKey: .count) ?? 1)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(at, forKey: .at)
        if !mods.isEmpty { try c.encode(mods, forKey: .mods) }
        if count != 1 { try c.encode(count, forKey: .count) }
    }
}

public struct DemoDrag: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    /// Seconds from press to the last move (default 0.4).
    public var duration: Double?
    /// Keep the button down at `to` (a later `release` step ends the drag), for mid-drag snapshots.
    public var hold: Bool?
    public var mods: [String]?

    public init(from: String, to: String, duration: Double? = nil, hold: Bool? = nil, mods: [String]? = nil) {
        self.from = from
        self.to = to
        self.duration = duration
        self.hold = hold
        self.mods = mods
    }
}

public struct DemoScroll: Codable, Sendable, Equatable {
    public var at: String
    /// Art px, y-down (the direction the content moves).
    public var dx: Double?
    public var dy: Double?
}

public struct DemoMenu: Codable, Sendable, Equatable {
    /// Where to right-click.
    public var at: String
    /// The `MenuItem.id` to choose.
    public var item: String
    /// Accept a confirmation sheet if the command asks for one.
    public var confirm: Bool?
}

/// A change to the fixture folder, performed by the demo harness (`scripts/run-demo.sh`), never by the app.
public enum DemoFS: Codable, Sendable, Equatable {
    case touch(String)
    /// `{"mkdir": name}`.
    case newFolder(String)
    case mv(String, String)
    case rm(String)

    private enum Key: String, CodingKey { case touch, mkdir, mv, rm }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "one fs operation"))
        }
        switch key {
        case .touch: self = .touch(try c.decode(String.self, forKey: .touch))
        case .mkdir: self = .newFolder(try c.decode(String.self, forKey: .mkdir))
        case .rm: self = .rm(try c.decode(String.self, forKey: .rm))
        case .mv:
            let names = try c.decode([String].self, forKey: .mv)
            guard names.count == 2 else {
                throw DecodingError.dataCorruptedError(forKey: .mv, in: c, debugDescription: "mv takes [from, to]")
            }
            self = .mv(names[0], names[1])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .touch(n): try c.encode(n, forKey: .touch)
        case let .newFolder(n): try c.encode(n, forKey: .mkdir)
        case let .rm(n): try c.encode(n, forKey: .rm)
        case let .mv(a, b): try c.encode([a, b], forKey: .mv)
        }
    }

    /// The operation and its names, all plain file names (no paths).
    public var parts: [String] {
        switch self {
        case let .touch(n): ["touch", n]
        case let .newFolder(n): ["mkdir", n]
        case let .rm(n): ["rm", n]
        case let .mv(a, b): ["mv", a, b]
        }
    }

    /// Every name is a plain file name without control characters (a tab or newline would break the harness's
    /// line protocol).
    public var isValid: Bool {
        parts.dropFirst().allSatisfy { DeskState.isPlainName($0) && !$0.unicodeScalars.contains { $0.properties.generalCategory == .control } }
    }
}

/// A JSON scalar in an expectation.
public enum DemoValue: Codable, Sendable, Equatable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        }
    }

    public var description: String {
        switch self {
        case let .string(s): "\"\(s)\""
        case let .number(n): n == n.rounded() ? String(Int(n)) : String(n)
        case let .bool(b): String(b)
        }
    }

    /// The value as text (numbers without a trailing ".0").
    public var text: String {
        if case let .string(s) = self { return s }
        return description
    }
}

public struct DemoWaitFor: Codable, Sendable, Equatable {
    public var expect: [String: DemoValue]
    /// Seconds before the expectation counts as failed (default 3).
    public var within: Double?
}

/// One step. Each is a JSON object with one key (see `docs/DEMOS.md`).
public enum DemoStep: Codable, Sendable, Equatable {
    /// Run until nothing animates, the mirror is quiet and icons have arrived (at most this many seconds).
    case waitIdle(Double)
    /// Run frames for this many seconds.
    case wait(Double)
    case snapshot(String)
    case click(DemoPointer)
    case hover(String)
    case drag(DemoDrag)
    /// Ends a held drag where the pointer is.
    case release
    case scroll(DemoScroll)
    /// `space`, `esc`, `left`, `cmd+a`, `cmd+z`, `shift+cmd+z`…
    case key(String)
    case menu(DemoMenu)
    case fs(DemoFS)
    /// A model action by name (`DemoStep.action(named:)`), for states input cannot reach (access denied).
    case action(String)
    case expect([String: DemoValue])
    case waitFor(DemoWaitFor)
    case comment(String)

    private enum Key: String, CodingKey, CaseIterable {
        case waitIdle, wait, snapshot, click, hover, drag, release, scroll, key, menu, fs, action, expect, waitFor, comment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            let keys = c.allKeys.map(\.stringValue)
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "a step has exactly one known key, got \(keys)"
            ))
        }
        switch key {
        case .waitIdle: self = .waitIdle(try c.decode(Double.self, forKey: key))
        case .wait: self = .wait(try c.decode(Double.self, forKey: key))
        case .snapshot: self = .snapshot(try c.decode(String.self, forKey: key))
        case .click: self = .click(try c.decode(DemoPointer.self, forKey: key))
        case .hover: self = .hover(try c.decode(String.self, forKey: key))
        case .drag: self = .drag(try c.decode(DemoDrag.self, forKey: key))
        case .release: _ = try c.decode(Bool.self, forKey: key); self = .release
        case .scroll: self = .scroll(try c.decode(DemoScroll.self, forKey: key))
        case .key: self = .key(try c.decode(String.self, forKey: key))
        case .menu: self = .menu(try c.decode(DemoMenu.self, forKey: key))
        case .fs: self = .fs(try c.decode(DemoFS.self, forKey: key))
        case .action: self = .action(try c.decode(String.self, forKey: key))
        case .expect: self = .expect(try c.decode([String: DemoValue].self, forKey: key))
        case .waitFor: self = .waitFor(try c.decode(DemoWaitFor.self, forKey: key))
        case .comment: self = .comment(try c.decode(String.self, forKey: key))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .waitIdle(s): try c.encode(s, forKey: .waitIdle)
        case let .wait(s): try c.encode(s, forKey: .wait)
        case let .snapshot(n): try c.encode(n, forKey: .snapshot)
        case let .click(p): try c.encode(p, forKey: .click)
        case let .hover(t): try c.encode(t, forKey: .hover)
        case let .drag(d): try c.encode(d, forKey: .drag)
        case .release: try c.encode(true, forKey: .release)
        case let .scroll(s): try c.encode(s, forKey: .scroll)
        case let .key(k): try c.encode(k, forKey: .key)
        case let .menu(m): try c.encode(m, forKey: .menu)
        case let .fs(f): try c.encode(f, forKey: .fs)
        case let .action(a): try c.encode(a, forKey: .action)
        case let .expect(e): try c.encode(e, forKey: .expect)
        case let .waitFor(w): try c.encode(w, forKey: .waitFor)
        case let .comment(t): try c.encode(t, forKey: .comment)
        }
    }

    /// Model actions a script may name: `powerOn`, `powerOff`, `requestConnect`, `accessDenied`, `accessGranted`,
    /// `finderHidesItems`, `cycleInput`, `selectAV`, `page:<n>` (HDMI n), `takeEverythingOut`, `clearDesk`, `undo`,
    /// `redo`, `cleanUp:<name|kind|dateAdded>`, `lights:<auto|day|night|lamp>`.
    public static func action(named name: String, in s: DeskState) -> DeskAction? {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts[0], parts.count > 1 ? parts[1] : nil) {
        case ("powerOn", nil): return .power(true)
        case ("powerOff", nil): return .power(false)
        case ("requestConnect", nil): return .requestConnect
        case ("accessDenied", nil): return .accessDenied
        case ("accessGranted", nil): return .accessGranted
        case ("finderHidesItems", nil): return .finderHidesItems
        case ("cycleInput", nil): return .cycleInput
        case ("selectAV", nil): return .selectAV
        case ("takeEverythingOut", nil): return .takeEverythingOut
        case ("clearDesk", nil): return .clearDesk
        case ("undo", nil): return .undo
        case ("redo", nil): return .redo
        case let ("page", n?): return Int(n).map { .setPage($0 - 1) }
        case let ("cleanUp", k?): return ScreenGrid.SortKey(rawValue: k).map { .cleanUp($0) }
        case let ("lights", m?):
            return LightsMode(rawValue: m).map { .lights(LightsState(mode: $0, room: s.lights.room, lamp: s.lights.lamp)) }
        default: return nil
        }
    }
}

/// An expected token location in an `expect` step: `screen`, `screen:<page>` (HDMI page, 1-based), `cell:<page>,
/// <col>,<row>` (0-based page), `container`, `container:<id>`, `desk`, `floor`, `present` or `missing`.
public enum LocationPattern: Sendable, Equatable {
    case screen(page: Int?)
    case cell(ScreenCell)
    case container(ContainerID?)
    case desk
    case floor
    case present
    case missing

    public init?(_ s: String) {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : nil
        switch parts[0] {
        case "screen":
            guard let arg else { self = .screen(page: nil); return }
            guard let n = Int(arg), n >= 1 else { return nil }
            self = .screen(page: n - 1)
        case "cell":
            let v = arg?.split(separator: ",").compactMap { Int($0) } ?? []
            guard v.count == 3 else { return nil }
            self = .cell(ScreenCell(page: v[0], col: v[1], row: v[2]))
        case "container":
            guard let arg else { self = .container(nil); return }
            guard let id = ContainerID(rawValue: arg) else { return nil }
            self = .container(id)
        case "desk" where arg == nil: self = .desk
        case "floor" where arg == nil: self = .floor
        case "present" where arg == nil: self = .present
        case "missing" where arg == nil: self = .missing
        default: return nil
        }
    }

    /// Whether a token's location (nil: no such token) matches.
    public func matches(_ loc: Location?) -> Bool {
        switch (self, loc) {
        case (.missing, nil): true
        case (.missing, _?), (_, nil): false
        case (.present, _?): true
        case let (.screen(page), .screen(p, _, _)?): page.map { $0 == p } ?? true
        case let (.cell(c), l?): l.cell == c
        case let (.container(id), .container(i, _)?): id.map { $0 == i } ?? true
        case (.desk, .desk?): true
        case (.floor, .floor?): true
        default: false
        }
    }
}

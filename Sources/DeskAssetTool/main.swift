import DeskCore
import DeskPixels
import Foundation

// `deskterior-assets` dev tool. Writes review images and generated assets; never touches user files.
//
//   deskterior-assets review <out-dir> [--scale N]    palette/light-ramp swatches + canvas primitives sheet
//   deskterior-assets icon --out <dir> [--all-sizes]  AppIcon.iconset (for iconutil), AppIcon-master.png and
//                                                     AppIcon-preview.png in <dir>; --all-sizes adds the
//                                                     16/32-px slots (see AppIconArt)
//   deskterior-assets contact-sheet --out <dir> [--scale N] [--rooms]
//                                                     every sprite and frame on labelled sheets (×3 nearest);
//                                                     --rooms adds CPU-lit room previews per display × light
//   deskterior-assets zoom <in.png> --rect x,y,w,h --out <file> [--scale N]
//                                                     nearest-neighbour crop of a 1× image for close review
//   deskterior-assets cloth-review --out <dir>        desk-mat cloth scenarios rendered for review

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
        usage: deskterior-assets review <out-dir> [--scale N]
               deskterior-assets icon --out <dir> [--all-sizes]
               deskterior-assets contact-sheet --out <dir> [--scale N] [--rooms]
               deskterior-assets zoom <in.png> --rect x,y,w,h --out <file> [--scale N]
               deskterior-assets cloth-review --out <dir>
        """)
    exit(2)
}

func value(of name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func option(_ name: String, default d: Int) -> Int {
    value(of: name).flatMap { Int($0) } ?? d
}

func write(_ buffer: PixelBuffer, _ name: String, in dir: URL, scale: Int) throws {
    let url = dir.appendingPathComponent(name)
    try PNGCodec.encode(buffer.scaledNearest(scale)).write(to: url)
    print("wrote \(url.path) (\(buffer.width)x\(buffer.height) ×\(scale))")
}

/// 46 palette columns × (1 identity row + 8 levels × 2 tints), 6×6 px cells.
func lightRampSheet() -> PixelBuffer {
    let cell = 6
    let rows = 1 + LightRamp.levelCount * 2
    var canvas = PixelCanvas(width: Apollo.count * cell, height: rows * cell + 2, fill: .neutral0)
    for i in 0..<Apollo.count {
        canvas.fill(ArtRect(i * cell, 0, cell, cell), Ink(palette: i))
        for tint in Tint.allCases {
            for level in 0..<LightRamp.levelCount {
                let row = 1 + tint.rawValue * LightRamp.levelCount + (LightRamp.maxLevel - level)
                let mapped = LightRamp.shared.map(i, level: level, tint: tint)
                canvas.fill(ArtRect(i * cell, row * cell + 2, cell, cell), Ink(palette: mapped))
            }
        }
    }
    return canvas.buffer
}

/// A sampler of PixelCanvas primitives, drawn the way furniture will be authored.
func primitivesSheet() -> PixelBuffer {
    var c = PixelCanvas(width: 200, height: 120, fill: Role.wallDay)
    // Desk slab with bevel and dithered wood band.
    c.fill(ArtRect(4, 60, 192, 40), Role.desk)
    c.bevel(ArtRect(4, 60, 192, 40), light: Role.deskHighlight, dark: Role.deskShadow)
    c.ditherFill(ArtRect(5, 80, 190, 6), Role.desk, Role.deskEdge, fraction: 0.5)
    c.gradientV(ArtRect(5, 86, 190, 13), inks: [.oak3, .oak2, .oak1])
    // Monitor: rounded bezel, screen gradient, power LED.
    c.roundedRectFill(ArtRect(60, 6, 80, 50), radius: 2, Role.bezel)
    c.gradientV(ArtRect(64, 10, 72, 38), inks: [.blue1, .blue2, .blue3])
    c.fill(ArtRect(128, 50, 2, 2), Role.ledOn)
    c.fill(ArtRect(96, 56, 8, 4), Role.bezelLight)
    // Lamp cone (polygon) and shade (ellipse).
    c.polygonFill([ArtPoint(20, 20), ArtPoint(30, 20), ArtPoint(46, 60), ArtPoint(4, 60)], Role.lampGlow)
    c.ellipseFill(ArtRect(16, 12, 18, 10), .red3)
    c.ellipseStroke(ArtRect(16, 12, 18, 10), Role.outline)
    // Clock with pixel-perfect hands.
    c.ellipseFill(ArtRect(156, 8, 28, 28), .neutral8)
    c.ellipseStroke(ArtRect(156, 8, 28, 28), Role.outline)
    c.polyline([ArtPoint(170, 22), ArtPoint(170, 12)], Role.outline)
    c.polyline([ArtPoint(170, 22), ArtPoint(178, 27)], .red3)
    // Pen cup sprite.
    let cup = IndexedSprite("""
        .kkkkkkkk.
        kRRRRRRRRk
        kRrRRRRRRk
        kRrRRRRRRk
        kRRRRRRRRk
        .kkkkkkkk.
        """, ["k": Role.outline, "R": .red3, "r": .red5, ".": .clear])
    c.blit(cup, at: ArtPoint(150, 52))
    return c.buffer
}

/// The icon as people see it: the 16- and 32-px sprites, then the 64- and 128-px slots, bottom-aligned on a
/// light and a dark row.
func iconPreviewSheet() -> PixelBuffer {
    let slots = AppIconArt.allSlots
    let tiles = [16, 32, 64, 128].compactMap { px in slots.first { $0.pixels == px }?.render() }
    let pad = 8
    let width = tiles.reduce(pad) { $0 + $1.width + pad }
    let rowHeight = (tiles.map(\.height).max() ?? 0) + 2 * pad
    var sheet = PixelBuffer(width: width, height: 2 * rowHeight)
    for (row, background) in [Role.wallDay, Ink.neutral1].enumerated() {
        let top = row * rowHeight
        sheet.fill(ArtRect(0, top, width, rowHeight), background.color)
        var x = pad
        for tile in tiles {
            sheet.blit(tile, at: ArtPoint(x, top + rowHeight - pad - tile.height))
            x += tile.width + pad
        }
    }
    return sheet
}

/// Writes `<dir>/AppIcon.iconset/*.png` (`AppIconArt.iconset`, or every slot with `allSizes`),
/// `<dir>/AppIcon-master.png` and `<dir>/AppIcon-preview.png`.
func writeIcon(to dir: URL, allSizes: Bool) throws {
    let iconset = dir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for image in allSizes ? AppIconArt.allSlots : AppIconArt.iconset {
        try write(image.render(), image.name, in: iconset, scale: 1)
    }
    try write(AppIconArt.master.render(), "AppIcon-master.png", in: dir, scale: 1)
    try write(iconPreviewSheet(), "AppIcon-preview.png", in: dir, scale: 2)
}

/// One labelled sheet per catalog section: each sprite's frames side by side over a grey tile, name below.
func contactSheet(_ section: ArtCatalog.Section, maxWidth: Int = 720) -> PixelBuffer {
    let font = PixelFont.galmuri9
    let pad = 6, gap = 2, labelH = 12
    struct Tile { var image: PixelBuffer; var origin = ArtPoint.zero }
    var tiles: [Tile] = []
    for sprite in section.sprites {
        let fw = sprite.size.w, fh = sprite.size.h
        let n = sprite.frames.count
        let label = font?.render("\(sprite.name) \(fw)x\(fh)" + (n > 1 ? " ×\(n)" : ""), color: Ink.neutral9.color)
        let stripW = n * fw + (n - 1) * gap
        let w = max(stripW, label?.width ?? 0) + 4, h = fh + 4 + labelH
        var c = PixelCanvas(width: w, height: h, fill: .neutral2)
        for (i, f) in sprite.frames.enumerated() {
            let r = ArtRect(2 + i * (fw + gap), 2, fw, fh)
            c.fill(r, .neutral6)
            c.blit(f, at: r.origin)
        }
        if let label { c.blit(label, at: ArtPoint(2, fh + 4)) }
        tiles.append(Tile(image: c.buffer))
    }
    var x = pad, y = pad, rowH = 0, width = pad
    for i in tiles.indices {
        let t = tiles[i].image
        if x + t.width + pad > maxWidth, x > pad {
            x = pad
            y += rowH + pad
            rowH = 0
        }
        tiles[i].origin = ArtPoint(x, y)
        x += t.width + pad
        rowH = max(rowH, t.height)
        width = max(width, x)
    }
    var sheet = PixelBuffer(width: max(width, 1), height: y + rowH + pad, fill: Ink.neutral1.color)
    for t in tiles { sheet.blit(t.image, at: t.origin, alphaTest: false) }
    return sheet
}

/// Displays for room previews (DESIGN §1.2 table, Dock hidden like this Mac, plus a bottom-Dock variant).
let previewDisplays: [(String, DisplayGeometry)] = [
    ("1470x956@2", DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2, topInsetPt: 33)),
    ("1470x956@2-dock", DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2, topInsetPt: 37, bottomInsetPt: 70)),
    ("1280x832@2", DisplayGeometry(widthPt: 1280, heightPt: 832, backingScale: 2, topInsetPt: 37)),
    ("1512x982@2", DisplayGeometry(widthPt: 1512, heightPt: 982, backingScale: 2, topInsetPt: 37)),
    ("1710x1112@2", DisplayGeometry(widthPt: 1710, heightPt: 1112, backingScale: 2, topInsetPt: 37)),
    ("1920x1080@1", DisplayGeometry(widthPt: 1920, heightPt: 1080, backingScale: 1, topInsetPt: 25)),
    ("2560x1440@2", DisplayGeometry(widthPt: 2560, heightPt: 1440, backingScale: 2, topInsetPt: 25)),
    ("1280x800@1", DisplayGeometry(widthPt: 1280, heightPt: 800, backingScale: 1, topInsetPt: 25)),
    ("1080x1920@1", DisplayGeometry(widthPt: 1080, heightPt: 1920, backingScale: 1, topInsetPt: 25)),
]

/// The DeskOS wallpaper with a full page of icons in the token grid (how the screen reads with files on it).
func screenMock(_ sky: SkyVariant) -> PixelBuffer {
    var screen = MonitorArt.deskOSWallpaper(sky: sky)
    let kinds = IconKind.allCases
    for row in 0..<CoreLayout.screenRows {
        for col in 0..<CoreLayout.screenColumns {
            let cell = CoreLayout.screenCellRect(col: col, row: row).offsetBy(-CoreLayout.screen.x, -CoreLayout.screen.y)
            let icon = KindIcons.icon(kinds[(row * CoreLayout.screenColumns + col) % kinds.count]).image
            screen.blit(icon, at: ArtPoint(cell.x + 2, cell.y + 2))
        }
    }
    return screen
}

func writeContactSheets(to dir: URL, scale: Int, rooms: Bool) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for section in ArtCatalog.sections() {
        try write(contactSheet(section), "contact-\(section.title).png", in: dir, scale: scale)
    }
    for sky in SkyVariant.allCases {
        try write(screenMock(sky), "screen-icons-\(sky.rawValue).png", in: dir, scale: scale)
    }
    guard rooms else { return }
    let lights: [(String, WallTime, LightsMode)] = [
        ("day", WallTime(hour: 10, minute: 0), .auto), ("dusk", WallTime(hour: 18, minute: 0), .auto),
        ("night", WallTime(hour: 22, minute: 0), .auto), ("lamp", WallTime(hour: 22, minute: 0), .lampOnly),
    ]
    for (name, display) in previewDisplays {
        let layout = LayoutSolver.solve(display: display)
        for (phase, time, mode) in lights {
            let image = RoomPlan.render(layout, RoomState(time: time, lightsMode: mode))
            try write(image, "room-\(name)-\(phase).png", in: dir, scale: 2)
            try write(image, "room-\(name)-\(phase)@1x.png", in: dir, scale: 1)
        }
    }
}

do {
    switch args.first {
    case "review":
        guard args.count >= 2 else { usage() }
        let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
        let scale = option("--scale", default: 4)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try write(lightRampSheet(), "light-ramp.png", in: outDir, scale: scale)
        try write(primitivesSheet(), "primitives.png", in: outDir, scale: scale)
    case "contact-sheet":
        guard let out = value(of: "--out") else { usage() }
        try writeContactSheets(to: URL(fileURLWithPath: out, isDirectory: true), scale: option("--scale", default: 3),
                               rooms: args.contains("--rooms"))
    case "zoom":
        guard args.count >= 2, let out = value(of: "--out"), let spec = value(of: "--rect") else { usage() }
        let n = spec.split(separator: ",").compactMap { Int($0) }
        guard n.count == 4, let image = PNGCodec.decode(try Data(contentsOf: URL(fileURLWithPath: args[1]))) else { usage() }
        let url = URL(fileURLWithPath: out)
        try PNGCodec.encode(image.cropped(to: ArtRect(n[0], n[1], n[2], n[3])).scaledNearest(option("--scale", default: 4)))
            .write(to: url)
        print("wrote \(url.path)")
    case "cloth-review":
        guard let out = value(of: "--out") else { usage() }
        try ClothReview.run(outDir: URL(fileURLWithPath: out, isDirectory: true))
    case "icon":
        guard let out = value(of: "--out") else { usage() }
        try writeIcon(to: URL(fileURLWithPath: out, isDirectory: true), allSizes: args.contains("--all-sizes"))
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

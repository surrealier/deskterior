import DeskCore
import DeskPixels
import Foundation

// `deskterior-assets` dev tool. Writes review images and generated assets; never touches user files.
//
//   deskterior-assets review <out-dir> [--scale N]    palette/light-ramp swatches + canvas primitives sheet
//   deskterior-assets icon --out <dir> [--all-sizes]  AppIcon.iconset (for iconutil), AppIcon-master.png and
//                                                     AppIcon-preview.png in <dir>; --all-sizes adds the
//                                                     16/32-px slots (see AppIconArt)

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
        usage: deskterior-assets review <out-dir> [--scale N]
               deskterior-assets icon --out <dir> [--all-sizes]
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

do {
    switch args.first {
    case "review":
        guard args.count >= 2 else { usage() }
        let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
        let scale = option("--scale", default: 4)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try write(lightRampSheet(), "light-ramp.png", in: outDir, scale: scale)
        try write(primitivesSheet(), "primitives.png", in: outDir, scale: scale)
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

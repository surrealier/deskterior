import Foundation
import simd

/// Desk and floor props (DESIGN §2.2): lamp, plant, pen cup and pens, phone on its stand, drive hub and drives,
/// brush, keyboard, chair, and the wastebasket with its crumpled balls. All lit from the top-left, outlined with
/// the darkest step of their own ramp.
public enum PropArt {
    // MARK: Geometry (core px)

    /// The lamp sprite covers base, arm and head.
    public static let lampRect = ArtRect(108, 98, 54, 70)
    /// The glowing bulb inside the shade (emissive when on).
    public static let lampBulbRect = ArtRect(149, 109, 5, 4)
    public static var phoneStandRect: ArtRect { CoreLayout.phone }
    /// The phone's screen (emissive when face-up).
    public static let phoneScreenRect = ArtRect(387, 146, 10, 18)

    // MARK: Lamp

    /// The anglepoise lamp: weighted base with its switch, two-part arm, tilted dome shade.
    public static func lamp(on: Bool) -> SpriteAsset {
        let r = lampRect
        var c = PixelCanvas(width: r.w, height: r.h)
        let base = CoreLayout.lampBase.offsetBy(-r.x, -r.y)
        let pivot = ArtPoint(base.midX, base.y)
        let elbow = ArtPoint(9, 30)
        let head = CoreLayout.lampHead.offsetBy(-r.x, -r.y)
        let knuckle = ArtPoint(head.x + 5, head.y + 3)

        // Arm: lower and upper struts with a spring, then the joints.
        func strut(_ a: ArtPoint, _ b: ArtPoint) {
            c.line(from: a + ArtPoint(1, 0), to: b + ArtPoint(1, 0), .red1)
            c.line(from: a, to: b, .red3)
            c.line(from: a + ArtPoint(-1, 0), to: b + ArtPoint(-1, 0), .red4)
        }
        strut(pivot + ArtPoint(0, -1), elbow)
        strut(elbow, knuckle)
        // The power cord runs up beside the lower strut with a slight sag.
        let cordA = pivot + ArtPoint(4, -2), cordB = elbow + ArtPoint(3, 3)
        let sag = ArtPoint((cordA.x + cordB.x) / 2 + 2, (cordA.y + cordB.y) / 2 + 1)
        c.polyline([cordA, sag, cordB], .neutral4)
        for j in [elbow] {
            c.ellipseFill(ArtRect(j.x - 2, j.y - 2, 5, 5), .neutral3)
            c.plot(j.x, j.y, .neutral7)
            c.plot(j.x - 1, j.y - 1, .neutral5)
        }

        // Base: oval weight with a top face and front face.
        c.ellipseFill(ArtRect(base.x, base.y + 1, base.w, base.h), .red1)
        c.ellipseFill(ArtRect(base.x + 1, base.y + 1, base.w - 2, base.h - 2), .red2)
        c.ellipseFill(ArtRect(base.x + 1, base.y + 1, base.w - 2, 5), .red3)
        c.ellipseFill(ArtRect(base.x + 4, base.y + 1, base.w - 12, 3), .red4)
        c.hline(x: base.x + 6, y: base.y + 1, length: 5, .red5)
        // Collar at the pivot.
        c.fill(ArtRect(pivot.x - 2, pivot.y - 2, 5, 4), .neutral3)
        c.hline(x: pivot.x - 2, y: pivot.y - 2, length: 5, .neutral5)
        // Switch on the base top.
        let sw = CoreLayout.lampSwitch.offsetBy(-r.x, -r.y)
        c.fill(sw, .neutral2)
        c.fill(ArtRect(sw.x + (on ? 3 : 1), sw.y, 2, 2), .neutral8)

        // Shade.
        let shade = lampShade(on: on)
        c.blit(shade, at: head.origin)
        c.ellipseFill(ArtRect(knuckle.x - 2, knuckle.y - 2, 5, 5), .neutral3)
        c.plot(knuckle.x, knuckle.y, .neutral7)
        c.plot(knuckle.x - 1, knuckle.y - 1, .neutral5)

        let hits: [String: ArtRect] = ["base": base, "switch": sw.insetBy(-2, -2), "head": head]
        return SpriteAsset(on ? "lamp.on" : "lamp.off", c, anchor: ArtPoint(base.midX, base.maxY), hitRects: hits)
    }

    /// The tilted dome shade (24×16, opening facing down-right), rendered from a cone around its axis.
    static func lampShade(on: Bool) -> PixelBuffer {
        let w = 24, h = 16
        var c = PixelCanvas(width: w, height: h)
        let k = SIMD2<Double>(5.5, 3.5)
        let a = simd_normalize(SIMD2<Double>(1, 0.72))
        let n = SIMD2<Double>(-a.y, a.x)
        let len = 11.5, r0 = 2.6, r1 = 7.6, b = 2.4
        var mask = PixelCanvas(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let d = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - k
                let u = simd_dot(d, a), v = simd_dot(d, n)
                let rr = r0 + (r1 - r0) * u / len
                let inCone = u >= -1.6 && u <= len && abs(v) <= max(rr, 1.6)
                let eu = (u - len) / b, ev = v / r1
                let inMouth = eu * eu + ev * ev <= 1
                if inMouth {
                    let rim = eu * eu + ev * ev > 0.55
                    let bulb = eu * eu + (ev * 1.6) * (ev * 1.6) < 0.35
                    let ink: Ink
                    if rim {
                        // Lit, the lower lip glows warm.
                        ink = v < 0 ? .red5 : (on ? .walnut4 : .red4)
                    } else if on {
                        ink = bulb ? .neutral9 : .walnut5
                    } else {
                        ink = bulb ? .neutral6 : .red1
                    }
                    c.plot(x, y, ink)
                    mask.plot(x, y, .neutral0)
                } else if inCone {
                    let t = v / max(rr, 1)
                    let ink: Ink = t < -0.55 ? .red4 : (t > 0.45 ? .red2 : .red3)
                    c.plot(x, y, ink)
                    if t < -0.25, t > -0.55, u > 2, u < len - 3 { c.plot(x, y, .red5) }
                    mask.plot(x, y, .neutral0)
                }
            }
        }
        let outline = ArtKit.outline(mask.buffer, .red1)
        var out = PixelCanvas(width: w, height: h)
        out.blit(outline.cropped(to: ArtRect(1, 1, w, h)), at: .zero)
        out.blit(c.buffer, at: .zero)
        return out.buffer
    }

    // MARK: Plant

    /// A snake plant in a terracotta pot.
    public static func plant() -> SpriteAsset {
        let r = CoreLayout.plant
        var leaves = PixelCanvas(width: r.w, height: r.h)
        // (base x, tip x, tip y, half width)
        let blades: [(Int, Int, Int, Int)] = [
            (7, 2, 7, 2), (17, 22, 6, 2), (10, 8, 0, 2), (14, 16, 2, 2), (12, 12, 9, 2),
        ]
        let baseY = 23
        for (i, (bx, tx, ty, hw)) in blades.enumerated() {
            let midY = (baseY + ty) / 2 + 2
            let mx = (bx + tx) / 2
            let poly = [
                ArtPoint(bx - hw + 1, baseY), ArtPoint(mx - hw - 1, midY), ArtPoint(tx, ty),
                ArtPoint(mx + hw + 1, midY), ArtPoint(bx + hw, baseY),
            ]
            let body: Ink = i % 2 == 0 ? .green2 : .green3
            var blade = PixelCanvas(width: r.w, height: r.h)
            blade.polygonFill(poly, body)
            // Lit left margin, dark right margin, banding.
            for y in ty..<baseY {
                let xs = (0..<r.w).filter { blade.ink(at: $0, y) == body }
                guard let minX = xs.first, let maxX = xs.last else { continue }
                blade.plot(minX, y, .green5)
                if maxX > minX { blade.plot(maxX, y, .green4) }
                if (y + i) % 5 == 0, maxX - minX >= 3 { blade.hline(x: minX + 1, y: y, length: maxX - minX - 1, .green1) }
                if (y + i) % 5 == 2, maxX - minX >= 3 { blade.plot(minX + 1, y, .green3) }
            }
            leaves.blit(blade.buffer, at: .zero)
        }
        var c = PixelCanvas(width: r.w, height: r.h)
        let outline = ArtKit.outline(leaves.buffer, .green0)
        c.blit(outline.cropped(to: ArtRect(1, 1, r.w, r.h)), at: .zero)
        c.blit(leaves.buffer, at: .zero)

        // Pot: rim, tapered body, saucer.
        let potTop = 21
        c.fill(ArtRect(4, potTop, 16, 3), .red4)
        c.hline(x: 4, y: potTop, length: 16, .red5)
        c.hline(x: 5, y: potTop, length: 14, .red5)
        c.hline(x: 4, y: potTop + 2, length: 16, .red3)
        c.fill(ArtRect(5, potTop - 1, 14, 1), .walnut1)
        for y in (potTop + 3)..<(r.h - 2) {
            let inset = (y - potTop - 3) / 4
            let x0 = 5 + inset, x1 = 19 - inset
            c.hline(x: x0, y: y, length: x1 - x0, .red4)
            c.plot(x0, y, .red5)
            c.plot(x0 + 1, y, .red5)
            c.plot(x1 - 1, y, .red3)
            c.plot(x1 - 2, y, .red3)
        }
        c.fill(ArtRect(5, r.h - 2, 14, 2), .red3)
        c.hline(x: 5, y: r.h - 2, length: 14, .red4)
        c.hline(x: 6, y: r.h - 1, length: 12, .red2)
        let potMask = c.buffer
        var framed = PixelCanvas(width: r.w, height: r.h)
        framed.blit(ArtKit.outline(silhouette(potMask, rows: potTop..<r.h), .red1).cropped(to: ArtRect(1, 1, r.w, r.h)), at: .zero)
        framed.blit(potMask, at: .zero)
        return SpriteAsset("plant", framed, anchor: ArtPoint(12, r.h))
    }

    static func silhouette(_ b: PixelBuffer, rows: Range<Int>) -> PixelBuffer {
        var out = PixelBuffer(width: b.width, height: b.height)
        for y in rows where y >= 0 && y < b.height {
            for x in 0..<b.width where b.pixel(x, y).a != 0 { out[x, y] = b[x, y] }
        }
        return out
    }

    // MARK: Pen cup

    public enum PenCupPose: Hashable, Sendable {
        case upright
        /// Tipping frame 0…2 (about 20°, 45°, 70°).
        case tipping(Int)
        /// Lying on its side, mouth to the right (`true`) or left.
        case lying(right: Bool)
    }

    /// The pen cup (14×22 upright, 26×22 for tipping and lying poses), with `pens` (cap inks) sticking up.
    public static func penCup(_ pose: PenCupPose = .upright, pens: [Ink] = []) -> SpriteAsset {
        let angle: Double
        var mirrored = false
        switch pose {
        case .upright: angle = 0
        case .tipping(let i): angle = [20.0, 45.0, 70.0][min(max(i, 0), 2)]
        case .lying(let right):
            angle = 90
            mirrored = !right
        }
        let upright = angle == 0
        let size = upright ? CoreLayout.penCup.size : ArtSize(28, 22)
        var c = PixelCanvas(width: size.w, height: size.h)
        let R = 6.5, H = 13.0
        // Pivot: the bottom-right corner of the cup stays on the desk as it tips right.
        let pivot = upright ? SIMD2<Double>(13.5, 21.5) : SIMD2<Double>(15.5, 21.5)
        let th = angle * .pi / 180
        let up = SIMD2<Double>(sin(th), -cos(th))
        let perp = SIMD2<Double>(cos(th), sin(th))
        let bottomCentre = pivot - perp * R
        let topCentre = bottomCentre + up * H
        let rm = 2.0

        // Two pencils that always live in the cup lean left; pens for files stand in front of them.
        for (dx, lean, ink) in [(-1.6, -2.2, Ink.walnut4), (0.9, -1.4, Ink.red3)] {
            let start = topCentre + perp * dx + up * 0.5
            let tip = start + up * 6 + perp * lean
            let a = ArtPoint(Int(start.x.rounded(.down)), Int(start.y.rounded(.down)))
            let b = ArtPoint(Int(tip.x.rounded(.down)), Int(tip.y.rounded(.down)))
            c.line(from: a, to: b, ink)
            c.plot(b, .oak5)
        }
        // Pens behind the front wall.
        if !pens.isEmpty {
            for (i, ink) in pens.prefix(6).enumerated() {
                let spread = (Double(i) - Double(min(pens.count, 6) - 1) / 2) * 1.9
                let start = topCentre + perp * spread + up * 0.5
                let tip = start + up * (7 + Double(i % 3)) + perp * spread * 0.35
                let a = ArtPoint(Int(start.x.rounded(.down)), Int(start.y.rounded(.down)))
                let b = ArtPoint(Int(tip.x.rounded(.down)), Int(tip.y.rounded(.down)))
                c.line(from: a, to: b, .neutral7)
                c.line(from: a + ArtPoint(1, 0), to: b + ArtPoint(1, 0), .neutral5)
                c.fill(ArtRect(b.x, b.y, 2, 3), ink)
                c.plot(b.x, b.y, ink.lighter())
            }
        }
        var body = PixelCanvas(width: size.w, height: size.h)
        for y in 0..<size.h {
            for x in 0..<size.w {
                let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                let d = p - bottomCentre
                let s = simd_dot(d, perp), t = simd_dot(d, up)
                let taper = R - 0.9 + 0.9 * min(max(t / H, 0), 1)
                let inWall = abs(s) <= taper && t >= 0 && t <= H
                let eb = (s / R) * (s / R) + (t / rm) * (t / rm)
                let dt = p - topCentre
                let ms = simd_dot(dt, perp), mt = simd_dot(dt, up)
                let em = (ms / R) * (ms / R) + (mt / rm) * (mt / rm)
                if em <= 1 {
                    let inner = (ms / (R - 1.2)) * (ms / (R - 1.2)) + (mt / (rm - 0.7)) * (mt / (rm - 0.7))
                    body.plot(x, y, inner <= 1 ? (mt > 0 ? .blue0 : .blue1) : (ms < 0 ? .blue5 : .blue4))
                } else if inWall || (eb <= 1 && t < 0) {
                    let f = s / taper
                    let ink: Ink = f < -0.66 ? .blue4 : (f < -0.42 ? .blue5 : (f > 0.5 ? .blue2 : .blue3))
                    body.plot(x, y, ink)
                }
            }
        }
        // Two-tone dipped glaze: a pale band round the top with a darker lip under it.
        for y in 0..<size.h {
            for x in 0..<size.w {
                guard let ink = body.ink(at: x, y), [Ink.blue2, .blue3, .blue4, .blue5].contains(ink) else { continue }
                let d = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - bottomCentre
                let t = simd_dot(d, up)
                guard t > H - 5.5, t <= H else { continue }
                let s = simd_dot(d, perp)
                if t < H - 4.5 {
                    body.plot(x, y, .blue1)
                } else {
                    body.plot(x, y, s < -2 ? .neutral9 : (s > 3 ? .neutral7 : .neutral8))
                }
            }
        }
        c.blit(ArtKit.outline(body.buffer, .blue1).cropped(to: ArtRect(1, 1, size.w, size.h)), at: .zero)
        c.blit(body.buffer, at: .zero)
        var buf = c.buffer
        if mirrored { buf = buf.flippedHorizontally() }
        let name: String
        switch pose {
        case .upright: name = "pencup"
        case .tipping(let i): name = "pencup.tipping\(i)"
        case .lying(let right): name = right ? "pencup.lying.right" : "pencup.lying.left"
        }
        return SpriteAsset(name + (pens.isEmpty ? "" : ".pens\(pens.count)"), buf, anchor: ArtPoint(size.w / 2, size.h),
                           hitRects: ["mouth": ArtRect(0, 0, size.w, 6)])
    }

    /// A pen as a token becomes it (3×10): cap in the kind colour, clip, barrel, tip.
    public static func pen(_ cap: Ink) -> SpriteAsset {
        var c = PixelCanvas(width: 3, height: 10)
        c.fill(ArtRect(0, 0, 3, 3), cap)
        c.plot(0, 0, cap.lighter())
        c.vline(x: 2, y: 0, length: 3, cap.darker())
        c.plot(1, 3, cap.darker())
        c.fill(ArtRect(0, 3, 3, 5), .neutral8)
        c.vline(x: 0, y: 3, length: 5, .neutral9)
        c.vline(x: 2, y: 3, length: 5, .neutral6)
        c.plot(1, 8, .neutral6)
        c.plot(1, 9, .neutral2)
        return SpriteAsset("pen", c, anchor: .zero)
    }

    // MARK: Phone and stand

    public enum PhoneFace: Int, CaseIterable, Sendable { case up, flip1, flip2, flip3, down }

    /// The phone on its stand: face-up (screen with up to six 5×5 minis), face-down (case and camera bump), or
    /// one of the three flip frames between them.
    public static func phoneStand(faceUp: Bool, minis: [PixelBuffer] = []) -> SpriteAsset {
        phoneStand(face: faceUp ? .up : .down, minis: minis)
    }

    public static func phoneStand(face: PhoneFace, minis: [PixelBuffer] = []) -> SpriteAsset {
        let r = CoreLayout.phone
        var c = PixelCanvas(width: r.w, height: r.h)
        // Stand: oak back support, base plate and front lip.
        c.fill(ArtRect(4, 6, 8, 18), .oak1)
        c.fill(ArtRect(5, 6, 6, 18), .oak2)
        c.fill(ArtRect(0, r.h - 5, r.w, 5), .oak0)
        c.fill(ArtRect(1, r.h - 5, r.w - 2, 3), .oak3)
        c.hline(x: 1, y: r.h - 5, length: r.w - 2, .oak4)
        c.hline(x: 1, y: r.h - 2, length: r.w - 2, .oak1)
        c.fill(ArtRect(1, r.h - 7, r.w - 2, 2), .oak2)
        c.hline(x: 1, y: r.h - 7, length: r.w - 2, .oak3)

        let fullW = 12, ph = 22
        let widths: [PhoneFace: Int] = [.up: 12, .flip1: 8, .flip2: 2, .flip3: 8, .down: 12]
        let pw = widths[face]!
        let px = 2 + (fullW - pw) / 2, py = 0
        let phone = ArtRect(px, py, pw, ph)
        if face == .flip2 {
            c.fill(phone, .neutral3)
            c.vline(x: phone.x, y: phone.y, length: ph, .neutral5)
        } else {
            let showsScreen = face == .up || face == .flip1
            c.roundedRectFill(phone, radius: 2, .neutral1)
            let inner = phone.insetBy(1, 1)
            if showsScreen {
                c.roundedRectFill(inner, radius: 1, .neutral2)
                let s = ArtRect(inner.x, inner.y + 1, inner.w, inner.h - 3)
                c.fill(s, .blue3)
                c.hline(x: s.x, y: s.maxY - 4, length: s.w, .blue2)
                c.fill(ArtRect(s.x, s.maxY - 3, s.w, 3), .blue2)
                c.plot(s.maxX - 3, s.y + 3, .purple4)
                c.hline(x: s.x, y: s.y, length: s.w, .neutral3)
                if face == .up {
                    for (i, m) in minis.prefix(6).enumerated() {
                        c.blit(m, at: ArtPoint(s.x + (i % 2) * 5, s.y + 3 + (i / 2) * 5))
                    }
                    // Home bar.
                    c.hline(x: s.x + 3, y: inner.maxY - 1, length: 4, .neutral6)
                    c.plot(s.x, s.y + 1, .neutral9)
                }
            } else {
                // Coral case with a camera bump.
                c.roundedRectFill(inner, radius: 1, .red4)
                c.vline(x: inner.x, y: inner.y + 1, length: inner.h - 2, .red5)
                c.vline(x: inner.maxX - 1, y: inner.y + 1, length: inner.h - 2, .red3)
                if pw >= 8 {
                    let cam = ArtRect(inner.x + 1, inner.y + 1, 5, 6)
                    c.roundedRectFill(cam, radius: 1, .neutral2)
                    c.plot(cam.x + 1, cam.y + 1, .neutral5)
                    c.plot(cam.x + 1, cam.y + 3, .neutral5)
                    c.plot(cam.x + 3, cam.y + 2, .neutral7)
                    c.plot(inner.maxX - 3, inner.maxY - 5, .red5)
                }
            }
        }
        // The lip holds the phone's foot.
        c.fill(ArtRect(1, r.h - 7, r.w - 2, 1), .oak3)
        c.plot(0, r.h - 7, .oak1)
        c.plot(r.w - 1, r.h - 7, .oak1)
        let name = "phone." + ["up", "flip1", "flip2", "flip3", "down"][face.rawValue]
        return SpriteAsset(name, c, anchor: ArtPoint(r.w / 2, r.h), hitRects: ["screen": ArtRect(3, 2, 10, 18)])
    }

    // MARK: Drive hub and drives

    public enum DriveKind: String, CaseIterable, Sendable { case usb, disk, server }

    /// The USB hub on the desk (24×8): four ports on the front.
    public static func driveHub() -> SpriteAsset {
        let r = CoreLayout.driveHub
        var c = PixelCanvas(width: r.w, height: r.h)
        c.roundedRectFill(c.bounds, radius: 1, .neutral4)
        c.fill(ArtRect(1, 0, r.w - 2, 3), .neutral8)
        c.hline(x: 1, y: 0, length: r.w - 2, .neutral9)
        c.fill(ArtRect(1, 3, r.w - 2, r.h - 4), .neutral7)
        c.hline(x: 1, y: r.h - 2, length: r.w - 2, .neutral6)
        for i in 0..<4 {
            let x = 2 + i * 5
            c.fill(ArtRect(x, 4, 4, 2), .neutral1)
            c.hline(x: x, y: 4, length: 4, .neutral2)
        }
        c.plot(r.w - 2, 4, .blue4)
        return SpriteAsset("hub", c, anchor: ArtPoint(r.w / 2, r.h), hitRects: ["slot0": ArtRect(1, 0, 5, 3)])
    }

    /// Where drive `i` (0…3) stands on the hub, in hub-local px (bottom-left of the drive sprite).
    public static func driveSlot(_ i: Int) -> ArtPoint { ArtPoint(1 + i * 6, 1) }

    /// A mounted volume as plugged into the hub.
    public static func drive(_ kind: DriveKind) -> SpriteAsset {
        var c: PixelCanvas
        switch kind {
        case .usb:
            c = PixelCanvas(width: 5, height: 10)
            c.fill(ArtRect(1, 7, 3, 3), .neutral7)
            c.plot(1, 7, .neutral9)
            c.roundedRectFill(ArtRect(0, 0, 5, 8), radius: 1, .blue2)
            c.fill(ArtRect(1, 1, 3, 6), .blue3)
            c.vline(x: 1, y: 1, length: 6, .blue4)
            c.plot(2, 1, .neutral1)
        case .disk:
            c = PixelCanvas(width: 6, height: 10)
            c.roundedRectFill(c.bounds, radius: 1, .neutral1)
            c.fill(ArtRect(1, 1, 4, 8), .neutral3)
            c.vline(x: 1, y: 1, length: 8, .neutral5)
            c.hline(x: 1, y: 1, length: 4, .neutral4)
            c.plot(3, 7, .green4)
        case .server:
            c = PixelCanvas(width: 6, height: 10)
            c.roundedRectFill(c.bounds, radius: 1, .neutral2)
            c.fill(ArtRect(1, 1, 4, 8), .neutral6)
            c.vline(x: 1, y: 1, length: 8, .neutral8)
            c.hline(x: 1, y: 3, length: 4, .neutral3)
            c.hline(x: 1, y: 6, length: 4, .neutral3)
            c.plot(4, 2, .blue4)
            c.plot(4, 5, .green4)
        }
        return SpriteAsset("drive.\(kind.rawValue)", c, anchor: ArtPoint(c.width / 2, c.height))
    }

    // MARK: Brush

    /// The desk brush at rest; frame 1 bends the bristles (while sweeping).
    public static func brush() -> SpriteAsset {
        let r = CoreLayout.brush
        func frame(_ bend: Int) -> PixelBuffer {
            var c = PixelCanvas(width: r.w, height: r.h)
            // Lacquered red handle (it must not melt into the oak desk) with a hanging hole.
            c.roundedRectFill(ArtRect(9, 2, 15, 4), radius: 1, .red1)
            c.hline(x: 10, y: 2, length: 12, .red4)
            c.hline(x: 10, y: 3, length: 12, .red3)
            c.hline(x: 11, y: 4, length: 11, .red2)
            c.plot(12, 2, .oak5)
            c.plot(21, 3, .red0)
            // Head block.
            c.roundedRectFill(ArtRect(0, 1, 11, 6), radius: 1, .walnut0)
            c.fill(ArtRect(1, 2, 9, 4), .walnut2)
            c.hline(x: 1, y: 2, length: 9, .walnut3)
            c.hline(x: 2, y: 2, length: 3, .walnut4)
            // Bristles.
            for x in 0..<11 {
                let bx = x + (x > 1 ? bend : 0)
                c.vline(x: bx, y: 7, length: 3, x % 2 == 0 ? .oak4 : .oak3)
                c.plot(bx, 9, .oak2)
            }
            return c.buffer
        }
        return SpriteAsset("brush", frames: [frame(0), frame(-1)], anchor: ArtPoint(12, r.h))
    }

    // MARK: Keyboard

    /// The keyboard: light caps on a grey plate with an accent Esc and Enter. `pressed` = (row, column) of a key
    /// drawn 1 px down.
    public static func keyboard(pressed: (row: Int, col: Int)? = nil) -> SpriteAsset {
        let r = CoreLayout.keyboard
        var c = PixelCanvas(width: r.w, height: r.h)
        c.roundedRectFill(c.bounds, radius: 2, .neutral4)
        c.roundedRectFill(ArtRect(1, 0, r.w - 2, r.h - 2), radius: 1, .neutral7)
        c.hline(x: 2, y: 0, length: r.w - 4, .neutral9)
        c.hline(x: 1, y: r.h - 2, length: r.w - 2, .neutral5)
        c.hline(x: 2, y: r.h - 1, length: r.w - 4, .neutral3)
        for key in keyboardKeys {
            let (ri, ki, x, y, kw) = (key.row, key.col, key.rect.x, key.rect.y, key.rect.w)
            let isPressed = pressed.map { $0.row == ri && $0.col == ki } ?? false
            var cap: Ink = .neutral9, side: Ink = .neutral6
            if ri == 0 && ki == 0 { (cap, side) = (.red4, .red2) }
            if ri == 2 && ki == keyboardRows[ri].count - 1 { (cap, side) = (.walnut4, .walnut2) }
            if ri == 3 && ki != 3 { (cap, side) = (.neutral8, .neutral5) }
            if isPressed {
                c.hline(x: x, y: y, length: kw, .neutral5)
                c.hline(x: x, y: y + 1, length: kw, cap)
                c.hline(x: x, y: y + 2, length: kw, cap.darker())
            } else {
                c.hline(x: x, y: y, length: kw, cap)
                c.hline(x: x, y: y + 1, length: kw, cap == .neutral9 ? .neutral8 : cap)
                c.plot(x, y, cap == .neutral9 ? .neutral9 : cap.lighter())
                c.hline(x: x, y: y + 2, length: kw, side)
            }
        }
        // Status LEDs.
        c.plot(r.w - 6, 13, .green4)
        return SpriteAsset(pressed == nil ? "keyboard" : "keyboard.pressed", c, anchor: ArtPoint(r.w / 2, r.h))
    }

    /// Key widths per keyboard row (1-px gaps); the last key of each row stretches to the plate's right edge.
    static let keyboardRows: [[Int]] = [
        Array(repeating: 4, count: 16) + [10],
        [7] + Array(repeating: 4, count: 14) + [12],
        [8] + Array(repeating: 4, count: 14) + [11],
        [5, 5, 5, 45, 5, 5, 4, 4, 4],
    ]

    /// Every key cap of `keyboard()`: row, column and its 3-px-tall rect in sprite px (E14 presses one).
    public static let keyboardKeys: [(row: Int, col: Int, rect: ArtRect)] = {
        let w = CoreLayout.keyboard.w
        var out: [(row: Int, col: Int, rect: ArtRect)] = []
        for (ri, row) in keyboardRows.enumerated() {
            var x = 3
            for (ki, w0) in row.enumerated() {
                let kw = ki == row.count - 1 ? w - 3 - x : w0
                out.append((ri, ki, ArtRect(x, 1 + ri * 3, kw, 3)))
                x += kw + 1
            }
        }
        return out
    }()

    /// The key under sprite-local `p`, if any (the 1-px gaps between caps count for the key on their left).
    public static func keyboardKey(at p: ArtPoint) -> (row: Int, col: Int)? {
        keyboardKeys.first { k in
            p.y >= k.rect.minY && p.y < k.rect.maxY && p.x >= k.rect.minX && p.x <= k.rect.maxX
        }.map { ($0.row, $0.col) }
    }

    // MARK: Plant jiggle

    /// The plant poked (E14): frame 0…3 of a 4-frame jiggle. The blade tips sway right, left, right by 1 px (the
    /// middle of the blades follows only to the right), then rest; the pot stays put. Each frame has
    /// `plantJigglePad` clear columns either side of the plant, so a swaying tip at its edge is not cut off: place
    /// it that many px left of the plant.
    public static func plantJiggle(_ frame: Int) -> PixelBuffer {
        let still = plant().image
        let sway = [1, -1, 1, 0][min(max(frame, 0), 3)]
        let pad = plantJigglePad
        var out = PixelBuffer(width: still.width + 2 * pad, height: still.height)
        for y in 0..<still.height {
            let shift = y < 9 ? sway : (y < 16 && sway > 0 ? 1 : 0)
            for x in 0..<still.width {
                let c = still.pixel(x, y)
                guard c.a != 0 else { continue }
                out.set(x + shift + pad, y, c)
            }
        }
        return out
    }

    /// Clear columns either side of a `plantJiggle` frame.
    public static let plantJigglePad = 1

    // MARK: Chair

    public enum ChairFacing: Int, CaseIterable, Sendable { case back, right, front, left }

    /// The office chair (72×84) in one of four facings; `left` mirrors `right`.
    public static func chair(_ facing: ChairFacing = .back) -> SpriteAsset {
        let r = CoreLayout.chair
        if facing == .left {
            let img = chair(.right).image.flippedHorizontally()
            return SpriteAsset("chair.left", img, anchor: ArtPoint(r.w / 2, r.h))
        }
        var c = PixelCanvas(width: r.w, height: r.h)
        drawChairBase(&c, size: r.size)
        switch facing {
        case .back:
            // Spine.
            c.fill(ArtRect(33, 32, 6, 12), .neutral1)
            c.fill(ArtRect(34, 32, 3, 12), .neutral3)
            // Seat back edge.
            c.roundedRectFill(ArtRect(6, 41, 60, 10), radius: 2, .blue0)
            c.fill(ArtRect(7, 42, 58, 3), .blue2)
            c.fill(ArtRect(7, 45, 58, 5), .blue1)
            c.hline(x: 8, y: 42, length: 56, .blue3)
            // Backrest: one seam across, a lit top-left.
            let back = ArtRect(11, 0, 50, 35)
            c.roundedRectFill(back, radius: 5, .blue0)
            c.roundedRectFill(back.insetBy(1, 1), radius: 4, .blue2)
            c.roundedRectFill(ArtRect(13, 2, 42, 12), radius: 3, .blue3)
            c.hline(x: 16, y: 2, length: 26, .blue4)
            c.vline(x: 13, y: 5, length: 8, .blue4)
            c.hline(x: 13, y: 17, length: 46, .blue1)
            c.hline(x: 13, y: 18, length: 46, .blue3)
            c.fill(ArtRect(13, 29, 46, 4), .blue1)
            c.vline(x: 58, y: 5, length: 26, .blue1)
        case .front:
            c.fill(ArtRect(33, 32, 6, 12), .neutral1)
            c.fill(ArtRect(34, 32, 3, 12), .neutral3)
            let back = ArtRect(13, 0, 46, 33)
            c.roundedRectFill(back, radius: 5, .blue0)
            c.roundedRectFill(back.insetBy(1, 1), radius: 4, .blue3)
            c.roundedRectFill(ArtRect(17, 4, 38, 25), radius: 4, .blue2)
            c.hline(x: 18, y: 4, length: 24, .blue4)
            // Seat cushion: top face then front edge.
            c.roundedRectFill(ArtRect(5, 34, 62, 17), radius: 3, .blue0)
            c.fill(ArtRect(6, 35, 60, 9), .blue3)
            c.hline(x: 8, y: 35, length: 46, .blue4)
            c.fill(ArtRect(6, 44, 60, 6), .blue2)
            c.hline(x: 6, y: 49, length: 60, .blue1)
        case .right:
            // Backrest edge-on, seat in profile.
            c.fill(ArtRect(16, 31, 4, 16), .neutral1)
            c.fill(ArtRect(17, 31, 2, 16), .neutral3)
            let back = ArtRect(9, 0, 14, 35)
            c.roundedRectFill(back, radius: 4, .blue0)
            c.roundedRectFill(back.insetBy(1, 1), radius: 3, .blue2)
            c.vline(x: 11, y: 3, length: 27, .blue3)
            c.vline(x: 12, y: 4, length: 11, .blue4)
            c.roundedRectFill(ArtRect(11, 39, 52, 11), radius: 3, .blue0)
            c.fill(ArtRect(12, 40, 50, 4), .blue3)
            c.hline(x: 13, y: 40, length: 34, .blue4)
            c.fill(ArtRect(12, 44, 50, 5), .blue2)
            c.hline(x: 12, y: 48, length: 50, .blue1)
        case .left:
            break
        }
        let name = "chair." + ["back", "right", "front", "left"][facing.rawValue]
        return SpriteAsset(name, c, anchor: ArtPoint(r.w / 2, r.h), hitRects: ["seat": ArtRect(6, 33, 60, 18)])
    }

    /// Gas lift, five-star base and casters, over a contact shadow on the floor (it rolls with the chair).
    static func drawChairBase(_ c: inout PixelCanvas, size: ArtSize) {
        // Contact shadow between and beside the casters.
        c.drawing(at: ArtPoint(2, size.h - 3), size: ArtSize(size.w - 2, 3)) { s in
            s.ellipseFill(s.bounds, .oak0)
        }
        // Gas lift.
        c.fill(ArtRect(33, 50, 6, 20), .neutral1)
        c.fill(ArtRect(34, 50, 4, 20), .neutral3)
        c.vline(x: 34, y: 50, length: 20, .neutral5)
        c.fill(ArtRect(31, 50, 10, 4), .neutral2)
        c.hline(x: 31, y: 50, length: 10, .neutral4)
        // Star base: two side legs and a front leg, casters at the ends.
        let hub = ArtPoint(36, 71)
        for (end, dir) in [(ArtPoint(5, 77), -1), (ArtPoint(66, 77), 1)] {
            c.line(from: hub, to: end, .neutral1)
            c.line(from: hub + ArtPoint(0, -1), to: end + ArtPoint(0, -1), .neutral3)
            c.line(from: hub + ArtPoint(0, -2), to: end + ArtPoint(dir, -2), .neutral4)
        }
        c.fill(ArtRect(34, 70, 4, 9), .neutral1)
        c.fill(ArtRect(35, 70, 2, 8), .neutral4)
        c.fill(ArtRect(31, 69, 10, 3), .neutral2)
        c.hline(x: 31, y: 69, length: 10, .neutral5)
        for x in [1, 32, 63] {
            c.fill(ArtRect(x + 2, size.h - 7, 3, 2), .neutral2)
            c.ellipseFill(ArtRect(x, size.h - 5, 7, 5), .neutral1)
            c.ellipseFill(ArtRect(x + 1, size.h - 5, 4, 3), .neutral3)
            c.plot(x + 2, size.h - 4, .neutral5)
        }
    }

    // MARK: Wastebasket

    /// The basket's back: a dark 4-px-deep mouth (`151d28`) inside a `394a50` back rim; drawn behind the heap.
    public static func wastebasketBack() -> SpriteAsset {
        let r = CoreLayout.wastebasket
        var c = PixelCanvas(width: r.w, height: r.h)
        let mouth = ArtRect(0, 0, r.w, 7)
        c.ellipseFill(mouth, .neutral4)
        c.ellipseFill(ArtRect(2, 1, r.w - 4, 5), .neutral2)
        c.hline(x: 6, y: 1, length: r.w - 12, .neutral1)
        return SpriteAsset("wastebasket.back", c, anchor: ArtPoint(r.w / 2, r.h))
    }

    /// The basket's wire body (vertical slats every 3 px, two hoops) and its pale front rim: drawn in front of
    /// the heap.
    public static func wastebasketFront() -> SpriteAsset {
        let r = CoreLayout.wastebasket
        var c = PixelCanvas(width: r.w, height: r.h)
        let top = 4
        // Tapered body: dark inside, slats lit on the left, hoops round it.
        for y in top..<r.h {
            let inset = (y - top) / 9
            let x0 = inset, x1 = r.w - inset
            c.hline(x: x0, y: y, length: x1 - x0, .neutral2)
            for x in (x0 + 1)..<(x1 - 1) where x % 3 == 1 {
                let f = Double(x) / Double(r.w)
                c.plot(x, y, f < 0.33 ? .neutral7 : (f > 0.7 ? .neutral4 : .neutral5))
            }
            c.plot(x0, y, .neutral6)
            c.plot(x1 - 1, y, .neutral3)
        }
        for y in [15, 26] {
            let inset = (y - top) / 9
            c.hline(x: inset, y: y, length: r.w - 2 * inset, .neutral5)
            c.hline(x: inset, y: y, length: (r.w - 2 * inset) / 3, .neutral7)
        }
        // Base band.
        c.fill(ArtRect(4, r.h - 5, r.w - 8, 4), .neutral4)
        c.hline(x: 4, y: r.h - 5, length: r.w - 8, .neutral6)
        c.hline(x: 4, y: r.h - 1, length: r.w - 8, .neutral2)
        // Front rim: the lower half of the mouth's ring, lit.
        var ring = PixelCanvas(width: r.w, height: 8)
        ring.ellipseStroke(ArtRect(0, 0, r.w, 7), .neutral8)
        ring.ellipseStroke(ArtRect(0, 1, r.w, 7), .neutral6)
        for y in 3..<8 {
            for x in 0..<r.w where ring.ink(at: x, y)?.isClear == false {
                c.plot(x, y, y <= 5 ? .neutral8 : ring.ink(at: x, y)!)
            }
        }
        return SpriteAsset("wastebasket.front", c, anchor: ArtPoint(r.w / 2, r.h), hitRects: [
            "mouth": ArtRect(0, 0, r.w, 6),
        ])
    }

    /// A crumpled paper ball (8×8), three variants.
    public static func paperBall(_ variant: Int) -> SpriteAsset {
        var c = PixelCanvas(width: 8, height: 8)
        c.ellipseFill(c.bounds, .neutral7)
        c.ellipseFill(ArtRect(0, 0, 7, 7), .neutral8)
        c.ellipseFill(ArtRect(1, 1, 5, 5), .neutral9)
        let v = variant % 3
        let creases: [[ArtPoint]] = [
            [ArtPoint(2, 3), ArtPoint(3, 2), ArtPoint(5, 4), ArtPoint(4, 5)],
            [ArtPoint(1, 4), ArtPoint(3, 3), ArtPoint(4, 1), ArtPoint(5, 5)],
            [ArtPoint(2, 2), ArtPoint(4, 3), ArtPoint(2, 5), ArtPoint(6, 3)],
        ]
        for p in creases[v] { c.plot(p, .neutral7) }
        c.plot(1 + v, 1, .neutral9)
        c.ellipseStroke(c.bounds, .neutral6)
        c.plot(1, 1, .neutral8)
        return SpriteAsset("paperBall.\(v)", c, anchor: ArtPoint(4, 8))
    }
}

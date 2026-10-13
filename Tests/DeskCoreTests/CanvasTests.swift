import Testing
@testable import DeskCore

private let key: [Character: Ink] = [
    ".": .clear, "#": .neutral0, "o": .oak4, "L": .oak5, "D": .oak1, "c": .oak3, "a": .blue1, "b": .blue4, "g": .green3,
]

/// The canvas as ASCII with the test key.
private func art(_ c: PixelCanvas) -> String {
    guard let s = IndexedSprite(exactly: c.buffer) else { return "<off-palette>" }
    return s.ascii(key: key)
}

/// Normalizes an indented multi-line literal the same way sprites are parsed.
private func grid(_ s: String) -> String {
    s.split(whereSeparator: \.isNewline)
        .map { String($0.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private func opaque(_ c: PixelCanvas) -> Set<ArtPoint> {
    var out = Set<ArtPoint>()
    for y in 0..<c.height {
        for x in 0..<c.width where c.buffer[x, y] != .clear { out.insert(ArtPoint(x, y)) }
    }
    return out
}

private func filled(_ w: Int, _ h: Int, _ draw: (inout PixelCanvas) -> Void) -> Set<ArtPoint> {
    var c = PixelCanvas(width: w, height: h)
    draw(&c)
    return opaque(c)
}

/// Pixels of `set` with a 4-neighbour outside `set`.
private func boundary(_ set: Set<ArtPoint>) -> Set<ArtPoint> {
    set.filter { p in
        [ArtPoint(1, 0), ArtPoint(-1, 0), ArtPoint(0, 1), ArtPoint(0, -1)].contains { !set.contains(p + $0) }
    }
}

private func isEightConnected(_ set: Set<ArtPoint>) -> Bool {
    guard let start = set.first else { return true }
    var seen: Set<ArtPoint> = [start], stack = [start]
    while let p = stack.popLast() {
        for dy in -1...1 {
            for dx in -1...1 {
                let q = ArtPoint(p.x + dx, p.y + dy)
                if set.contains(q), seen.insert(q).inserted { stack.append(q) }
            }
        }
    }
    return seen.count == set.count
}

@Suite struct CanvasTests {
    // MARK: Rects

    @Test func fillClipsAndClearErases() {
        var c = PixelCanvas(width: 5, height: 4)
        c.fill(ArtRect(-2, -1, 4, 3), .neutral0)
        c.fill(ArtRect(3, 3, -2, 5), .oak4)  // negative size: no-op
        c.fill(ArtRect(9, 9, 3, 3), .oak4)   // fully outside: no-op
        #expect(art(c) == grid("""
            ##...
            ##...
            .....
            .....
            """))
        c.fill(.oak4)
        c.fill(ArtRect(1, 1, 3, 2), .clear)
        #expect(art(c) == grid("""
            ooooo
            o...o
            o...o
            ooooo
            """))
    }

    @Test func linesHaveLengthNotEndpoints() {
        var c = PixelCanvas(width: 5, height: 3)
        c.hline(x: 1, y: 0, length: 3, .neutral0)
        c.vline(x: 4, y: 0, length: 9, .oak4)
        c.hline(x: 0, y: 2, length: 0, .oak4)
        c.vline(x: 0, y: 0, length: -2, .oak4)
        #expect(art(c) == grid("""
            .###o
            ....o
            ....o
            """))
    }

    @Test func strokeDrawsAOnePixelBorder() {
        var c = PixelCanvas(width: 6, height: 5)
        c.stroke(ArtRect(1, 1, 4, 3), .neutral0)
        #expect(art(c) == grid("""
            ......
            .####.
            .#..#.
            .####.
            ......
            """))
        var tiny = PixelCanvas(width: 3, height: 3)
        tiny.stroke(ArtRect(1, 1, 1, 1), .oak4)
        tiny.stroke(ArtRect(0, 0, 0, 3), .oak4)
        #expect(art(tiny) == grid("""
            ...
            .o.
            ...
            """))
    }

    @Test func bevelLightsTopLeftAndShadesBottomRight() {
        var c = PixelCanvas(width: 5, height: 4)
        c.bevel(c.bounds, light: .oak5, dark: .oak1)
        #expect(art(c) == grid("""
            LLLLD
            L...D
            L...D
            DDDDD
            """))
        c.bevel(c.bounds, light: .oak5, dark: .oak1, corners: .oak3)
        #expect(art(c) == grid("""
            LLLLc
            L...D
            L...D
            cDDDD
            """))
        // Sunken: swap the inks; the corner rule follows the dark ink.
        var s = PixelCanvas(width: 3, height: 3)
        s.bevel(s.bounds, light: .oak1, dark: .oak5)
        #expect(art(s) == grid("""
            DDL
            D.L
            LLL
            """))
        // Thin rects: the dark side wins.
        var thin = PixelCanvas(width: 3, height: 3)
        thin.bevel(ArtRect(1, 0, 1, 3), light: .oak5, dark: .oak1, corners: .oak3)
        thin.bevel(ArtRect(0, 0, 0, 3), light: .oak5, dark: .oak1)
        #expect(art(thin) == grid("""
            .D.
            .D.
            .D.
            """))
    }

    // MARK: Rounded rects

    @Test func roundedCornersRadiusOneTwoThree() {
        var r1 = PixelCanvas(width: 6, height: 4)
        r1.roundedRectFill(r1.bounds, radius: 1, .oak4)
        #expect(art(r1) == grid("""
            .oooo.
            oooooo
            oooooo
            .oooo.
            """))

        var r2 = PixelCanvas(width: 8, height: 6)
        r2.roundedRectFill(r2.bounds, radius: 2, .oak4)
        #expect(art(r2) == grid("""
            ..oooo..
            .oooooo.
            oooooooo
            oooooooo
            .oooooo.
            ..oooo..
            """))

        var r3 = PixelCanvas(width: 10, height: 8)
        r3.roundedRectFill(r3.bounds, radius: 3, .oak4)
        #expect(art(r3) == grid("""
            ...oooo...
            .oooooooo.
            .oooooooo.
            oooooooooo
            oooooooooo
            .oooooooo.
            .oooooooo.
            ...oooo...
            """))
    }

    @Test func roundedStrokeOutlinesTheFill() {
        var c = PixelCanvas(width: 10, height: 7)
        c.roundedRectFill(ArtRect(1, 0, 8, 6), radius: 2, .oak4)
        c.roundedRectStroke(ArtRect(1, 0, 8, 6), radius: 2, .neutral0)
        #expect(art(c) == grid("""
            ...####...
            ..#oooo#..
            .#oooooo#.
            .#oooooo#.
            ..#oooo#..
            ...####...
            ..........
            """))
        for r in 0...5 {
            let fill = filled(12, 9) { $0.roundedRectFill(ArtRect(1, 1, 10, 7), radius: r, .oak4) }
            let stroke = filled(12, 9) { $0.roundedRectStroke(ArtRect(1, 1, 10, 7), radius: r, .oak4) }
            #expect(stroke == boundary(fill), "radius \(r)")
        }
    }

    @Test func roundedRadiusIsClampedToKeepStraightEdges() {
        var big = PixelCanvas(width: 6, height: 6)
        big.roundedRectFill(big.bounds, radius: 10, .oak4)
        var two = PixelCanvas(width: 6, height: 6)
        two.roundedRectFill(two.bounds, radius: 2, .oak4)
        #expect(big == two)

        var plus = PixelCanvas(width: 3, height: 3)
        plus.roundedRectFill(plus.bounds, radius: 4, .oak4)
        #expect(art(plus) == grid("""
            .o.
            ooo
            .o.
            """))

        var square = PixelCanvas(width: 2, height: 2)
        square.roundedRectFill(square.bounds, radius: 3, .oak4)
        #expect(art(square) == "oo\noo")

        var none = PixelCanvas(width: 4, height: 3)
        none.roundedRectFill(none.bounds, radius: 0, .oak4)
        #expect(opaque(none).count == 12)
    }

    // MARK: Ellipses

    @Test func ellipsesAreSymmetricContiguousAndOutlined() {
        for h in 1...12 {
            for w in 1...12 {
                let rect = ArtRect(1, 1, w, h)
                let fill = filled(w + 2, h + 2) { $0.ellipseFill(rect, .oak4) }
                let stroke = filled(w + 2, h + 2) { $0.ellipseStroke(rect, .oak4) }
                let label: Comment = "\(w)x\(h)"
                #expect(fill.allSatisfy { rect.contains($0) }, label)
                for p in fill {
                    #expect(fill.contains(ArtPoint(2 * rect.x + w - 1 - p.x, p.y)), label)
                    #expect(fill.contains(ArtPoint(p.x, 2 * rect.y + h - 1 - p.y)), label)
                }
                // Every row and column of the box is touched; rows are single runs that widen to the middle.
                var previous = Int.max
                for y in rect.minY..<rect.maxY {
                    let xs = fill.filter { $0.y == y }.map(\.x)
                    #expect(!xs.isEmpty, label)
                    guard let lo = xs.min(), let hi = xs.max() else { continue }
                    #expect(xs.count == hi - lo + 1, label)
                    let width = hi - lo + 1
                    if y - rect.minY <= (h - 1) / 2 { #expect(width >= (previous == .max ? 0 : previous), label) }
                    previous = width
                }
                for x in rect.minX..<rect.maxX { #expect(fill.contains { $0.x == x }, label) }
                if w == h {
                    #expect(Set(fill.map { ArtPoint($0.y, $0.x) }) == fill, label)
                }
                #expect(stroke == boundary(fill), label)
                #expect(isEightConnected(stroke), label)
            }
        }
    }

    @Test func smallEllipseShapes() {
        func shape(_ w: Int, _ h: Int, stroke: Bool = false) -> String {
            var c = PixelCanvas(width: w, height: h)
            if stroke { c.ellipseStroke(c.bounds, .neutral0) } else { c.ellipseFill(c.bounds, .oak4) }
            return art(c)
        }
        #expect(shape(1, 1) == "o")
        #expect(shape(3, 3) == grid("""
            .o.
            ooo
            .o.
            """))
        #expect(shape(4, 4) == grid("""
            .oo.
            oooo
            oooo
            .oo.
            """))
        #expect(shape(6, 6) == grid("""
            ..oo..
            .oooo.
            oooooo
            oooooo
            .oooo.
            ..oo..
            """))
        #expect(shape(8, 3) == grid("""
            ..oooo..
            oooooooo
            ..oooo..
            """))
        #expect(shape(7, 7, stroke: true) == grid("""
            ..###..
            .#...#.
            #.....#
            #.....#
            #.....#
            .#...#.
            ..###..
            """))
        #expect(shape(5, 9, stroke: true) == grid("""
            ..#..
            .#.#.
            #...#
            #...#
            #...#
            #...#
            #...#
            .#.#.
            ..#..
            """))
    }

    @Test func ellipseIsPlacedAtTheRectAndClipped() {
        var c = PixelCanvas(width: 5, height: 4)
        c.ellipseFill(ArtRect(-1, 1, 3, 3), .oak4)
        #expect(art(c) == grid("""
            .....
            o....
            oo...
            o....
            """))
        var empty = PixelCanvas(width: 3, height: 3)
        empty.ellipseFill(ArtRect(0, 0, 0, 3), .oak4)
        empty.ellipseStroke(ArtRect(0, 0, 3, -1), .oak4)
        #expect(opaque(empty).isEmpty)
    }

    // MARK: Polygons

    @Test func rectanglePolygonMatchesRectFill() {
        let cw = filled(10, 8) { $0.polygonFill([ArtPoint(2, 1), ArtPoint(7, 1), ArtPoint(7, 5), ArtPoint(2, 5)], .oak4) }
        let ccw = filled(10, 8) { $0.polygonFill([ArtPoint(2, 1), ArtPoint(2, 5), ArtPoint(7, 5), ArtPoint(7, 1)], .oak4) }
        let rect = filled(10, 8) { $0.fill(ArtRect(2, 1, 5, 4), .oak4) }
        #expect(cw == rect)
        #expect(ccw == rect)
    }

    @Test func trapezoidsSharingAnEdgeNeitherOverlapNorGap() {
        // Desk-top perspective: a trapezoid split along a slanted edge.
        let a = [ArtPoint(4, 0), ArtPoint(9, 0), ArtPoint(6, 10), ArtPoint(0, 10)]
        let b = [ArtPoint(9, 0), ArtPoint(20, 0), ArtPoint(24, 10), ArtPoint(6, 10)]
        let whole = [ArtPoint(4, 0), ArtPoint(20, 0), ArtPoint(24, 10), ArtPoint(0, 10)]
        let fa = filled(26, 12) { $0.polygonFill(a, .oak4) }
        let fb = filled(26, 12) { $0.polygonFill(b, .oak4) }
        let fw = filled(26, 12) { $0.polygonFill(whole, .oak4) }
        #expect(!fa.isEmpty && !fb.isEmpty)
        #expect(fa.isDisjoint(with: fb))
        #expect(fa.union(fb) == fw)

        // Side by side with a steep shared edge, listed in opposite directions.
        let left = [ArtPoint(0, 0), ArtPoint(10, 0), ArtPoint(15, 12), ArtPoint(0, 12)]
        let right = [ArtPoint(15, 12), ArtPoint(10, 0), ArtPoint(22, 0), ArtPoint(22, 12)]
        let fl = filled(24, 14) { $0.polygonFill(left, .oak4) }
        let fr = filled(24, 14) { $0.polygonFill(right, .oak4) }
        #expect(fl.isDisjoint(with: fr))
        #expect(fl.union(fr) == filled(24, 14) { $0.fill(ArtRect(0, 0, 22, 12), .oak4) })
    }

    @Test func triangleFanTilesTheLampCone() {
        let apex = ArtPoint(12, 0)
        let base = [0, 5, 11, 17, 24].map { ArtPoint($0, 16) }
        var cover: [ArtPoint: Int] = [:]
        for i in 0..<(base.count - 1) {
            for p in filled(26, 18, { $0.polygonFill([apex, base[i], base[i + 1]], .walnut5) }) { cover[p, default: 0] += 1 }
        }
        #expect(cover.values.allSatisfy { $0 == 1 })
        #expect(Set(cover.keys) == filled(26, 18) { $0.polygonFill([apex, base[0], base[4]], .walnut5) })
    }

    @Test func jitteredMeshTilesExactly() {
        var rng = SplitMix64(seed: 2026)
        let cols = 6, rows = 5
        var v: [[ArtPoint]] = []
        for j in 0...rows {
            var row: [ArtPoint] = []
            for i in 0...cols {
                let edgeX = i == 0 || i == cols, edgeY = j == 0 || j == rows
                let jx = edgeX ? 0 : rng.nextInt(in: -2...2), jy = edgeY ? 0 : rng.nextInt(in: -2...2)
                row.append(ArtPoint(2 + i * 7 + jx, 2 + j * 6 + jy))
            }
            v.append(row)
        }
        var cover: [ArtPoint: Int] = [:]
        for j in 0..<rows {
            for i in 0..<cols {
                let quad = [v[j][i], v[j][i + 1], v[j + 1][i + 1], v[j + 1][i]]
                for p in filled(48, 36, { $0.polygonFill(quad, .oak4) }) { cover[p, default: 0] += 1 }
            }
        }
        #expect(cover.values.allSatisfy { $0 == 1 })
        #expect(Set(cover.keys) == filled(48, 36) { $0.fill(ArtRect(2, 2, cols * 7, rows * 6), .oak4) })
    }

    @Test func concaveAndDegeneratePolygons() {
        let l = [ArtPoint(0, 0), ArtPoint(6, 0), ArtPoint(6, 2), ArtPoint(2, 2), ArtPoint(2, 6), ArtPoint(0, 6)]
        let expected = filled(8, 8) {
            $0.fill(ArtRect(0, 0, 6, 2), .oak4)
            $0.fill(ArtRect(0, 2, 2, 4), .oak4)
        }
        #expect(filled(8, 8) { $0.polygonFill(l, .oak4) } == expected)
        #expect(filled(8, 8) { $0.polygonFill([ArtPoint(0, 0), ArtPoint(5, 5)], .oak4) }.isEmpty)
        #expect(filled(8, 8) { $0.polygonFill([ArtPoint(0, 0), ArtPoint(5, 0), ArtPoint(7, 0)], .oak4) }.isEmpty)
        // Clipped against every side.
        let big = filled(4, 3) { $0.polygonFill([ArtPoint(-5, -5), ArtPoint(9, -5), ArtPoint(9, 9), ArtPoint(-5, 9)], .oak4) }
        #expect(big.count == 12)
    }

    // MARK: Dither and gradients

    @Test func ditherFillExtremesAndChecker() {
        var c = PixelCanvas(width: 4, height: 2)
        c.ditherFill(c.bounds, .blue1, .blue4, fraction: 0)
        #expect(art(c) == "aaaa\naaaa")
        c.ditherFill(c.bounds, .blue1, .blue4, fraction: 1)
        #expect(art(c) == "bbbb\nbbbb")
        c.ditherFill(c.bounds, .blue1, .blue4, fraction: 0.5)
        #expect(art(c) == "baba\nabab")
        c.artOrigin = ArtPoint(1, 0)
        c.ditherFill(ArtRect(-3, 0, 5, 1), .blue1, .blue4, fraction: 0.5)
        #expect(art(c) == "abba\nabab")
    }

    @Test func gradientBandsWithSoftEdges() {
        var c = PixelCanvas(width: 8, height: 8)
        c.gradientV(c.bounds, inks: [.blue1, .blue4])
        #expect(art(c) == grid("""
            aaaaaaaa
            aaaaaaaa
            aaaaaaaa
            abaaabaa
            bbbabbba
            bbbbbbbb
            bbbbbbbb
            bbbbbbbb
            """))
        var three = PixelCanvas(width: 4, height: 9)
        three.gradientV(three.bounds, inks: [.blue1, .blue4, .green3])
        #expect(art(three) == grid("""
            aaaa
            aaaa
            aaba
            abbb
            bbbb
            bbbg
            gbgg
            gggg
            gggg
            """))
    }

    @Test func thinBandsKeepTheirSolidRows() {
        var c = PixelCanvas(width: 4, height: 3)
        c.gradientV(c.bounds, inks: [.blue1, .blue4, .green3])
        #expect(art(c) == "aaaa\nbbbb\ngggg")
        var two = PixelCanvas(width: 4, height: 4)
        two.gradientV(two.bounds, inks: [.blue1, .blue4])
        #expect(art(two) == grid("""
            aaaa
            aaab
            babb
            bbbb
            """))
        var one = PixelCanvas(width: 3, height: 2)
        one.gradientV(one.bounds, inks: [.green3])
        #expect(art(one) == "ggg\nggg")
        one.gradientV(one.bounds, inks: [])
        #expect(art(one) == "ggg\nggg")
    }

    @Test func horizontalGradientIsTheTranspose() {
        var v = PixelCanvas(width: 5, height: 11)
        v.gradientV(v.bounds, inks: [.blue1, .blue4, .green3])
        var h = PixelCanvas(width: 11, height: 5)
        h.gradientH(h.bounds, inks: [.blue1, .blue4, .green3])
        for y in 0..<5 {
            for x in 0..<11 { #expect(h.buffer[x, y] == v.buffer[y, x]) }
        }
    }

    @Test func gradientDitherFollowsArtOrigin() {
        var big = PixelCanvas(width: 9, height: 8)
        big.gradientV(big.bounds, inks: [.blue1, .blue4])
        var sub = PixelCanvas(width: 8, height: 8, artOrigin: ArtPoint(1, 0))
        sub.gradientV(sub.bounds, inks: [.blue1, .blue4])
        #expect(sub.buffer == big.buffer.cropped(to: ArtRect(1, 0, 8, 8)))
    }

    // MARK: Lines, blits, reads

    @Test func linesUseLineRaster() {
        var c = PixelCanvas(width: 8, height: 8)
        c.line(from: ArtPoint(1, 1), to: ArtPoint(6, 3), .neutral0)
        #expect(opaque(c) == Set(LineRaster.points(from: ArtPoint(1, 1), to: ArtPoint(6, 3))))
        var p = PixelCanvas(width: 5, height: 5)
        p.polyline([ArtPoint(0, 0), ArtPoint(4, 0), ArtPoint(4, 4)], .neutral0)
        #expect(!opaque(p).contains(ArtPoint(4, 0)))
        var raw = PixelCanvas(width: 5, height: 5)
        raw.polyline([ArtPoint(0, 0), ArtPoint(4, 0), ArtPoint(4, 4)], .neutral0, pixelPerfect: false)
        #expect(opaque(raw).contains(ArtPoint(4, 0)))
    }

    @Test func blitsSkipTransparencyAndClip() {
        let sprite = IndexedSprite("""
            #o
            .#
            """, key)
        var c = PixelCanvas(width: 3, height: 3, fill: .green3)
        c.blit(sprite, at: ArtPoint(-1, 1))
        c.blit(sprite, at: ArtPoint(2, 0), remap: [.oak4: .blue4, .neutral0: .clear])
        #expect(art(c) == grid("""
            ggg
            ogg
            #gg
            """))
        var d = PixelCanvas(width: 3, height: 3, fill: .green3)
        d.blit(sprite.render(), at: ArtPoint(1, 1))
        #expect(art(d) == grid("""
            ggg
            g#o
            gg#
            """))
        var e = PixelCanvas(width: 3, height: 3)
        e.blit(sprite, at: ArtPoint(2, 0), remap: [.oak4: .blue4])
        #expect(art(e) == grid("""
            ..#
            ...
            ...
            """))
    }

    @Test func readsInksBack() {
        var c = PixelCanvas(IndexedSprite("#o", key), artOrigin: ArtPoint(3, 3))
        #expect(c.ink(at: 0, 0) == .neutral0)
        #expect(c.ink(at: 1, 0) == .oak4)
        #expect(c.ink(at: 5, 0) == .clear)
        c.buffer[0, 0] = RGBA8(1, 2, 3)
        #expect(c.ink(at: 0, 0) == nil)
        c.plot(ArtPoint(0, 0), .blue1)
        c.plot(-1, 0, .blue1)
        #expect(art(c) == "ao")
        #expect(c.size == ArtSize(2, 1) && c.bounds == ArtRect(0, 0, 2, 1))
    }
}

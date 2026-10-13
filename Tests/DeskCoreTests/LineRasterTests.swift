import Testing
@testable import DeskCore

private func pts(_ list: [(Int, Int)]) -> [ArtPoint] { list.map { ArtPoint($0.0, $0.1) } }

/// True when no point is the corner of an L between two diagonal neighbours.
private func hasLCorner(_ p: [ArtPoint]) -> Bool {
    guard p.count > 2 else { return false }
    for i in 1..<(p.count - 1) {
        let a = p[i - 1], b = p[i], c = p[i + 1]
        let ortho = { (u: ArtPoint, v: ArtPoint) in abs(u.x - v.x) + abs(u.y - v.y) == 1 }
        if ortho(a, b) && ortho(b, c) && a.x != c.x && a.y != c.y { return true }
    }
    return false
}

private func isEightConnected(_ p: [ArtPoint]) -> Bool {
    zip(p, p.dropFirst()).allSatisfy { a, b in
        let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
        return max(dx, dy) == 1
    }
}

@Suite struct LineRasterTests {
    private static let endpoints: [ArtPoint] = {
        var out: [ArtPoint] = []
        for y in stride(from: -5, through: 5, by: 1) {
            for x in stride(from: -6, through: 6, by: 1) where (x * 7 + y * 3) % 2 == 0 || abs(x) == 6 || abs(y) == 5 {
                out.append(ArtPoint(x, y))
            }
        }
        return out
    }()

    @Test func singlePoint() {
        #expect(LineRaster.points(from: ArtPoint(3, 4), to: ArtPoint(3, 4)) == [ArtPoint(3, 4)])
    }

    @Test func axisAndDiagonalLines() {
        #expect(LineRaster.points(from: ArtPoint(0, 0), to: ArtPoint(3, 0)) == pts([(0, 0), (1, 0), (2, 0), (3, 0)]))
        #expect(LineRaster.points(from: ArtPoint(2, 3), to: ArtPoint(2, 0)) == pts([(2, 3), (2, 2), (2, 1), (2, 0)]))
        #expect(LineRaster.points(from: ArtPoint(0, 0), to: ArtPoint(-3, 3)) == pts([(0, 0), (-1, 1), (-2, 2), (-3, 3)]))
    }

    @Test func shallowSlopesMakeEvenRuns() {
        // Slope 2/5 → nearest rows give runs of two.
        #expect(LineRaster.points(from: ArtPoint(0, 0), to: ArtPoint(5, 2))
            == pts([(0, 0), (1, 0), (2, 1), (3, 1), (4, 2), (5, 2)]))
        #expect(LineRaster.points(from: ArtPoint(0, 0), to: ArtPoint(2, 6)).map(\.x) == [0, 0, 1, 1, 1, 2, 2])
        // Exact halves (x = 4 → y = 1.5) round toward the top endpoint.
        let tie = LineRaster.points(from: ArtPoint(0, 0), to: ArtPoint(8, 3))
        #expect(tie.map(\.y) == [0, 0, 1, 1, 1, 2, 2, 3, 3])
        let up = LineRaster.points(from: ArtPoint(0, 3), to: ArtPoint(8, 0))
        #expect(up.map(\.y) == [3, 3, 2, 2, 1, 1, 1, 0, 0])
        // Steep: the tie at y = −4 (x = 0.5) goes to the top endpoint's column.
        #expect(LineRaster.points(from: ArtPoint(0, 0), to: ArtPoint(1, -8)).map(\.x) == [0, 0, 0, 0, 1, 1, 1, 1, 1])
    }

    @Test func mirrorImagesRasterizeAsMirrorImages() {
        // M1 review F8: 1:00 and 11:00 clock hands, lamp cones and other symmetric art.
        for dx in -12...12 {
            for dy in -12...12 {
                let line = LineRaster.points(from: .zero, to: ArtPoint(dx, dy))
                let mirrored = LineRaster.points(from: .zero, to: ArtPoint(-dx, dy))
                #expect(mirrored == line.map { ArtPoint(-$0.x, $0.y) }, "(\(dx), \(dy))")
            }
        }
        for a in Self.endpoints {
            for b in Self.endpoints {
                let line = LineRaster.points(from: a, to: b)
                let mirrored = LineRaster.points(from: ArtPoint(-a.x, a.y), to: ArtPoint(-b.x, b.y))
                #expect(mirrored == line.map { ArtPoint(-$0.x, $0.y) })
            }
        }
    }

    @Test func endpointsCountAndConnectivity() {
        for a in Self.endpoints {
            for b in Self.endpoints {
                let line = LineRaster.points(from: a, to: b)
                #expect(line.first == a)
                #expect(line.last == b)
                #expect(line.count == max(abs(b.x - a.x), abs(b.y - a.y)) + 1)
                if line.count > 1 { #expect(isEightConnected(line)) }
                #expect(!hasLCorner(line))
            }
        }
    }

    @Test func linesAreSymmetric() {
        for a in Self.endpoints {
            for b in Self.endpoints {
                #expect(LineRaster.points(from: a, to: b) == LineRaster.points(from: b, to: a).reversed())
            }
        }
    }

    @Test func pointsStayCloseToTheIdealLine() {
        let a = ArtPoint(-4, 2), b = ArtPoint(9, -3)
        for p in LineRaster.points(from: a, to: b) {
            // Distance along the minor axis from the exact line is at most half a pixel.
            let t = Double(p.x - a.x) / Double(b.x - a.x)
            let ideal = Double(a.y) + t * Double(b.y - a.y)
            #expect(abs(Double(p.y) - ideal) <= 0.5)
        }
    }

    @Test func pixelPerfectRemovesLCorners() {
        let stair = pts([(0, 0), (1, 0), (1, 1), (2, 1), (2, 2)])
        #expect(LineRaster.pixelPerfect(stair) == pts([(0, 0), (1, 1), (2, 2)]))

        // An L inside a longer run: only the corner pixel goes.
        let hook = pts([(0, 0), (1, 0), (2, 0), (2, 1), (2, 2)])
        #expect(LineRaster.pixelPerfect(hook) == pts([(0, 0), (1, 0), (2, 1), (2, 2)]))

        // Duplicates collapse; endpoints stay.
        #expect(LineRaster.pixelPerfect(pts([(0, 0), (0, 0), (1, 0), (1, 0)])) == pts([(0, 0), (1, 0)]))
        #expect(LineRaster.pixelPerfect([]) == [])
        #expect(LineRaster.pixelPerfect(pts([(4, 4)])) == pts([(4, 4)]))

        // A jump between distant points is not an L corner.
        let jump = pts([(0, 0), (0, 5), (3, 5)])
        #expect(LineRaster.pixelPerfect(jump) == jump)
    }

    @Test func pixelPerfectKeepsBresenhamLinesAndCleansPolylines() {
        for b in Self.endpoints {
            let line = LineRaster.points(from: .zero, to: b)
            #expect(LineRaster.pixelPerfect(line) == line)
        }
        // A clock-hand-like polyline with a bend produces an L at the joint; cleanup removes it.
        let bent = LineRaster.polyline([ArtPoint(0, 0), ArtPoint(4, 0), ArtPoint(4, 4)])
        #expect(bent.count == 9)
        #expect(hasLCorner(bent))
        let clean = LineRaster.pixelPerfect(bent)
        #expect(!hasLCorner(clean))
        #expect(isEightConnected(clean))
        #expect(clean.first == ArtPoint(0, 0) && clean.last == ArtPoint(4, 4))
        #expect(!clean.contains(ArtPoint(4, 0)))
    }

    @Test func polylineJoinsWithoutDuplicates() {
        #expect(LineRaster.polyline([]) == [])
        #expect(LineRaster.polyline([ArtPoint(1, 1)]) == [ArtPoint(1, 1)])
        let p = LineRaster.polyline([ArtPoint(0, 0), ArtPoint(2, 0), ArtPoint(2, 2), ArtPoint(0, 2)])
        #expect(p == pts([(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2)]))
    }

    @Test func drawsClippedIntoABuffer() {
        var buf = PixelBuffer(width: 4, height: 3)
        LineRaster.draw(from: ArtPoint(-2, 1), to: ArtPoint(6, 1), color: .white, into: &buf)
        #expect((0..<4).allSatisfy { buf[$0, 1] == .white })
        #expect((0..<4).allSatisfy { buf[$0, 0] == .clear && buf[$0, 2] == .clear })
        LineRaster.plot(pts([(0, 0), (9, 9)]), color: .black, into: &buf)
        #expect(buf[0, 0] == .black)
    }
}

import Testing
@testable import DeskCore

@Suite struct DitherTests {
    private let standard = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    @Test func bayerMatrixIsTheStandardOne() {
        #expect(Dither.bayer4Matrix == standard)
        for y in 0..<4 {
            for x in 0..<4 { #expect(Dither.bayer4(x: x, y: y) == standard[y][x]) }
        }
        let all = (0..<16).map { Dither.bayer4(x: $0 % 4, y: $0 / 4) }
        #expect(Set(all) == Set(0...15))
    }

    @Test func patternTilesThePlaneIncludingNegativeCoordinates() {
        for y in -9...9 {
            for x in -9...9 {
                let v = Dither.bayer4(x: x, y: y)
                #expect(v == standard[((y % 4) + 4) % 4][((x % 4) + 4) % 4])
                #expect(v == Dither.bayer4(x: x + 4, y: y - 8))
            }
        }
        #expect(Dither.bayer4(x: -1, y: -1) == 5)
    }

    @Test func thresholdIsCentredInEachSixteenth() {
        #expect(Dither.threshold(x: 0, y: 0) == 0.5 / 16)
        #expect(Dither.threshold(x: 0, y: 3) == 15.5 / 16)
        #expect(Dither.threshold(x: 1, y: 1) == 4.5 / 16)
    }

    @Test func pickExtremes() {
        for y in -6..<6 {
            for x in -6..<6 {
                #expect(!Dither.pick(x: x, y: y, fraction: 0))
                #expect(!Dither.pick(x: x, y: y, fraction: -1))
                #expect(Dither.pick(x: x, y: y, fraction: 1))
                #expect(Dither.pick(x: x, y: y, fraction: 2))
                #expect(!Dither.pick(x: x, y: y, sixteenths: 0))
                #expect(Dither.pick(x: x, y: y, sixteenths: 16))
            }
        }
    }

    @Test func everyFourByFourWindowGetsExactlyKSixteenths() {
        for k in 0...16 {
            let f = Double(k) / 16
            for (ox, oy) in [(0, 0), (1, 2), (-3, -1), (5, -7)] {
                var count = 0, countInt = 0
                for y in oy..<(oy + 4) {
                    for x in ox..<(ox + 4) {
                        if Dither.pick(x: x, y: y, fraction: f) { count += 1 }
                        if Dither.pick(x: x, y: y, sixteenths: k) { countInt += 1 }
                    }
                }
                #expect(count == k)
                #expect(countInt == k)
            }
        }
    }

    @Test func pickIsMonotonicInFraction() {
        for y in 0..<4 {
            for x in 0..<4 {
                var seen = false
                for k in 0...32 {
                    let p = Dither.pick(x: x, y: y, fraction: Double(k) / 32)
                    if seen { #expect(p) }
                    seen = seen || p
                }
            }
        }
    }

    @Test func halfIsACheckerboard() {
        for y in 0..<8 {
            for x in 0..<8 { #expect(Dither.pick(x: x, y: y, fraction: 0.5) == ((x + y) % 2 == 0)) }
        }
    }

    @Test func coarseCellsRepeatEachThreshold() {
        for y in -8..<8 {
            for x in -8..<8 {
                let bx = Int((Double(x) / 2).rounded(.down)), by = Int((Double(y) / 2).rounded(.down))
                #expect(Dither.threshold(x: x, y: y, cell: 2) == Dither.threshold(x: bx, y: by))
                #expect(Dither.pick(x: x, y: y, sixteenths: 7, cell: 2) == Dither.pick(x: bx, y: by, sixteenths: 7))
            }
        }
    }

    @Test func ditherAlignsAcrossCanvasesByAbsoluteCoordinates() {
        // One big fill vs. two neighbouring sub-canvases placed at their art origins.
        let whole = ArtRect(13, 7, 10, 6)
        var big = PixelCanvas(width: 40, height: 20)
        big.ditherFill(whole, .oak2, .oak4, fraction: 0.375)

        var left = PixelCanvas(width: 4, height: 6, artOrigin: ArtPoint(13, 7))
        left.ditherFill(left.bounds, .oak2, .oak4, fraction: 0.375)
        var right = PixelCanvas(width: 6, height: 6, artOrigin: ArtPoint(17, 7))
        right.ditherFill(right.bounds, .oak2, .oak4, fraction: 0.375)

        var composed = PixelCanvas(width: 40, height: 20)
        composed.blit(left.buffer, at: left.artOrigin)
        composed.blit(right.buffer, at: right.artOrigin)
        #expect(composed == big)

        // Ignoring the origin would shift the phase and break the seam.
        var naive = PixelCanvas(width: 6, height: 6)
        naive.ditherFill(naive.bounds, .oak2, .oak4, fraction: 0.375)
        #expect(naive.buffer != right.buffer)
    }
}

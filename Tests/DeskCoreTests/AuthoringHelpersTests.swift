import Testing
@testable import DeskCore

@Suite struct AuthoringHelpersTests {
    @Test func rgba8LayoutIsFourPackedBytes() {
        #expect(MemoryLayout<RGBA8>.size == 4)
        #expect(MemoryLayout<RGBA8>.stride == 4)
        #expect(MemoryLayout<RGBA8>.offset(of: \.r) == 0)
        #expect(MemoryLayout<RGBA8>.offset(of: \.a) == 3)
    }

    @Test func rgbaBytesRoundTrip() {
        let b = PixelBuffer(width: 2, height: 1, pixels: [RGBA8(1, 2, 3, 255), .clear])
        #expect(b.rgbaBytes == [1, 2, 3, 255, 0, 0, 0, 0])
        #expect(PixelBuffer(width: 2, height: 1, rgbaBytes: b.rgbaBytes) == b)
    }

    @Test func fillAndBlitClip() {
        var b = PixelBuffer(width: 4, height: 3)
        b.fill(ArtRect(-2, 1, 4, 5), .white)
        #expect(b.pixel(0, 0) == .clear && b.pixel(1, 1) == .white && b.pixel(2, 1) == .clear && b.pixel(1, 2) == .white)
        var d = PixelBuffer(width: 3, height: 3)
        let src = PixelBuffer(width: 2, height: 2, pixels: [.white, .clear, .black, .white])
        d.blit(src, at: ArtPoint(2, -1))
        #expect(d.pixel(2, 0) == .black && d.pixel(2, 1) == .clear)
    }

    @Test func inkRampSteps() {
        #expect(Ink.oak4.ramp == .oak && Ink.oak4.step == 4)
        #expect(Ink.oak4.darker() == .oak3 && Ink.oak4.darker(9) == .oak0)
        #expect(Ink.oak4.lighter(3) == .oak5)
        #expect(Ink(ramp: .neutral, step: 12) == .neutral9)
        #expect(Ink.clear.darker() == .clear && Ink.clear.ramp == nil)
    }

    @Test func drawingScopeUsesLocalCoordinatesAndClips() {
        var c = PixelCanvas(width: 6, height: 4, fill: .neutral9)
        c.drawing(at: ArtPoint(4, 2), size: ArtSize(3, 3)) { part in
            #expect(part.ink(at: 0, 0) == .neutral9)   // pre-filled from the parent
            part.fill(ArtRect(0, 0, 3, 3), .red3)
            part.plot(1, 1, .clear)
        }
        #expect(c.ink(at: 4, 2) == .red3 && c.ink(at: 5, 3) == .clear)
        #expect(c.ink(at: 3, 2) == .neutral9 && c.ink(at: 5, 2) == .red3)
    }

    @Test func mirroredDrawingIsSymmetric() {
        for w in [5, 6] {
            var c = PixelCanvas(width: w, height: 2)
            c.drawingMirrored(at: .zero, size: ArtSize(w, 2)) { half in
                half.plot(0, 0, .blue3)
                half.plot(1, 1, .green3)
            }
            for x in 0..<w {
                for y in 0..<2 { #expect(c.ink(at: x, y) == c.ink(at: w - 1 - x, y), "w\(w) x\(x) y\(y)") }
            }
            #expect(c.ink(at: 0, 0) == .blue3 && c.ink(at: w - 1, 0) == .blue3)
        }
    }
}

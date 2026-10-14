import Foundation
import Testing
@testable import DeskCore

/// The demo recording pieces (M13): the `record` and `glide` steps and the pointer drawn into recorded frames.
@Suite("Demo recording")
struct DemoRecordingTests {
    @Test("record and glide steps decode and round-trip")
    func steps() throws {
        let s = try DemoScript.decode(Data("""
            { "name": "x", "steps": [ { "record": true }, { "glide": { "to": "monitor.power", "duration": 0.4 } },
                                      { "glide": { "to": "token:a.txt" } }, { "record": false } ] }
            """.utf8))
        #expect(s.steps == [.record(true), .glide(DemoMove(to: "monitor.power", duration: 0.4)),
                            .glide(DemoMove(to: "token:a.txt")), .record(false)])
        #expect(try DemoScript.decode(JSONEncoder().encode(s)) == s)
        #expect(throws: (any Error).self) { try DemoScript.decode(Data(#"{ "name": "x", "steps": [ { "record": "on" } ] }"#.utf8)) }
    }

    @Test("The hero demo records a segment and names its stills")
    func heroScript() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Demos/hero.json").standardizedFileURL
        let s = try DemoScript.decode(Data(contentsOf: url))
        let records = s.steps.compactMap { if case let .record(on) = $0 { on } else { nil } }
        #expect(records == [true, false])
        let stills = Set(s.steps.compactMap { if case let .snapshot(n) = $0 { n } else { nil } })
        // scripts/make-gif.sh copies these four.
        #expect(stills.isSuperset(of: ["still-desk", "still-peel", "still-hiding", "still-lamp-only"]))
    }

    @Test("The pointer is binary-alpha Apollo art with its hot spot at the tip")
    func art() {
        for sprite in [DemoCursorArt.arrow, DemoCursorArt.pressed] + DemoCursorArt.ripples {
            for p in sprite.render().pixels {
                #expect(p.a == 0 || (p.a == 255 && Apollo.index(of: p) != nil))
            }
        }
        #expect(DemoCursorArt.arrow[0, 0] == .neutral0)
        #expect(DemoCursorArt.arrow.size == DemoCursorArt.pressed.size)
        #expect(DemoCursorArt.ripples.allSatisfy { $0.w % 2 == 1 && $0.h % 2 == 1 })
    }

    @Test("Stamping draws the arrow at the tip, the ring only after a press, and clips at the edges")
    func stamp() {
        let blank = PixelBuffer(width: 40, height: 30, fill: Ink.oak4.color)
        var frame = blank
        DemoCursorArt.stamp(into: &frame, tip: ArtPoint(10, 8), pressed: false, sincePress: nil)
        #expect(frame[10, 8] == Ink.neutral0.color)
        #expect(frame[11, 10] == Ink.neutral9.color)
        #expect(frame[9, 8] == Ink.oak4.color) // nothing left of the tip without a ring

        var pressed = blank
        DemoCursorArt.stamp(into: &pressed, tip: ArtPoint(10, 8), pressed: true, sincePress: 0)
        #expect(pressed[11, 10] == Ink.neutral7.color)
        #expect(pressed[7, 8] != Ink.oak4.color) // the small ring, left of the tip

        var later = blank
        DemoCursorArt.stamp(into: &later, tip: ArtPoint(10, 8), pressed: false,
                            sincePress: DemoCursorArt.rippleFrames * DemoCursorArt.ripples.count)
        #expect(later == frame) // the ring is over

        var edge = blank
        DemoCursorArt.stamp(into: &edge, tip: ArtPoint(38, 28), pressed: false, sincePress: 7)
        DemoCursorArt.stamp(into: &edge, tip: ArtPoint(-3, -2), pressed: false, sincePress: 0)
        #expect(edge[38, 28] == Ink.neutral0.color)
    }
}

import Testing
@testable import DeskCore

@Suite struct AppIconArtTests {
    @Test func spriteSizes() {
        #expect(AppIconArt.artwork.size == ArtSize(32, 32))
        #expect(AppIconArt.master.size == ArtSize(32, 32))
        #expect(AppIconArt.small.size == ArtSize(16, 16))
    }

    @Test func artParsesWithoutRaggedRows() throws {
        // The throwing parser reports ragged rows or stray characters instead of trapping.
        #expect(try IndexedSprite(parsing: AppIconArt.artworkArt, key: SpriteKey.standard) == AppIconArt.artwork)
        #expect(try IndexedSprite(parsing: AppIconArt.smallArt, key: SpriteKey.standard) == AppIconArt.small)
    }

    @Test(arguments: ["artwork", "master", "small"])
    func everyPixelIsClearOrAnApolloColour(name: String) {
        let sprite = Self.sprite(name)
        let buffer = sprite.render()
        #expect(buffer.pixels.allSatisfy { $0 == .clear || Apollo.index(of: $0) != nil })
        #expect(IndexedSprite(exactly: buffer) == sprite)
    }

    @Test func artworkIsASquareBodyOnTheIconGrid() {
        // Apple's macOS grid: an 824-px body in a 1024-px canvas, i.e. 25.75 of 32 px.
        let buffer = AppIconArt.artwork.render()
        #expect(buffer.opaqueBounds() == ArtRect(3, 3, 26, 26))
        #expect(buffer.cropped(to: ArtRect(3, 3, 26, 26)).pixels.allSatisfy { $0.a == 255 })
    }

    /// A rounded square centred in the canvas: each row of the body is one opaque run with equal side margins,
    /// the corner cut-outs shrink to zero towards the middle, and the top and bottom halves mirror each other.
    @Test(arguments: [("master", 3), ("small", 1)])
    func roundedSquare(name: String, margin: Int) {
        let sprite = Self.sprite(name)
        let body = sprite.w - 2 * margin
        #expect(sprite.render().opaqueBounds() == ArtRect(margin, margin, body, body))
        var cuts: [Int] = []
        for y in margin..<(margin + body) {
            let row = (0..<sprite.w).map { sprite[$0, y] }
            let left = row.prefix(while: \.isClear).count
            guard left < sprite.w else {
                Issue.record("row \(y) is fully transparent")
                continue
            }
            let right = row.reversed().prefix(while: \.isClear).count
            #expect(left == right, "row \(y): margins \(left)/\(right)")
            #expect(row[left..<(sprite.w - right)].allSatisfy { !$0.isClear }, "row \(y) has a hole")
            cuts.append(left - margin)
        }
        #expect(cuts == Array(cuts.reversed()), "corners differ top/bottom")
        let top = cuts.prefix(body / 2)
        #expect(zip(top, top.dropFirst()).allSatisfy { $0 >= $1 }, "corner profile is not monotonic")
        #expect(cuts[0] > 0, "corners should be rounded")
        #expect(cuts[body / 2] == 0, "middle rows should span the body")
    }

    @Test func masterIsTheArtworkClippedToTheShape() {
        var mismatches: [String] = []
        for y in 0..<32 {
            for x in 0..<32 {
                let expected = AppIconArt.shapeContains(x, y, size: 32) ? AppIconArt.artwork[x, y] : .clear
                if AppIconArt.master[x, y] != expected { mismatches.append("(\(x), \(y))") }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test func shapeMatchesAppleGridAndIsSymmetric() {
        // At 1024 px the body spans 100…923 along the middle row and column.
        let middle = (0..<1024).filter { AppIconArt.shapeContains($0, 512, size: 1024) }
        #expect(middle.first == 100)
        #expect(middle.last == 923)
        #expect(!AppIconArt.shapeContains(100, 100, size: 1024))
        #expect(AppIconArt.shapeContains(512, 512, size: 1024))
        for size in [32, 64, 128] {
            var asymmetric = 0
            for y in 0..<size {
                for x in 0..<size {
                    let inside = AppIconArt.shapeContains(x, y, size: size)
                    if inside != AppIconArt.shapeContains(size - 1 - x, y, size: size) { asymmetric += 1 }
                    if inside != AppIconArt.shapeContains(y, x, size: size) { asymmetric += 1 }
                }
            }
            #expect(asymmetric == 0, "size \(size)")
        }
    }

    @Test func slotsCoverTheIconsetWithIntegerScales() {
        let expected: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]
        #expect(AppIconArt.allSlots.map(\.name) == expected.map(\.0))
        #expect(AppIconArt.allSlots.map(\.pixels) == expected.map(\.1))
        #expect(AppIconArt.allSlots.allSatisfy { $0.pixels % 16 == 0 })
        // macOS 26 frames supplied 16/32-px reps on a grey plate, so the shipped set starts at 64 px.
        #expect(AppIconArt.iconset.map(\.pixels) == [64, 128, 256, 256, 512, 512, 1024])
    }

    @Test func smallSlotsAreTheHandDrawnSprites() throws {
        let slots = Dictionary(uniqueKeysWithValues: AppIconArt.allSlots.map { ($0.name, $0) })
        #expect(try #require(slots["icon_16x16.png"]).render() == AppIconArt.small.render())
        #expect(try #require(slots["icon_16x16@2x.png"]).render() == AppIconArt.master.render())
        #expect(try #require(slots["icon_32x32.png"]).render() == AppIconArt.master.render())
    }

    @Test(arguments: [64, 256, 1024])
    func largeSlotsAreNearestUpscalesClippedToTheShape(pixels: Int) throws {
        let image = try #require(AppIconArt.iconset.first { $0.pixels == pixels }).render()
        #expect(image.size == ArtSize(pixels, pixels))
        let scale = pixels / 32
        let artwork = AppIconArt.artwork.render()
        var mismatches = 0
        for y in 0..<pixels {
            for x in 0..<pixels {
                let expected = AppIconArt.shapeContains(x, y, size: pixels) ? artwork[x / scale, y / scale] : .clear
                if image[x, y] != expected { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
        #expect(image.pixels.allSatisfy { $0.a == 0 || $0.a == 255 })
    }

    private static func sprite(_ name: String) -> IndexedSprite {
        switch name {
        case "artwork": AppIconArt.artwork
        case "master": AppIconArt.master
        default: AppIconArt.small
        }
    }
}

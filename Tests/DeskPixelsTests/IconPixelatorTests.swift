import CoreGraphics
import DeskCore
import Foundation
import Testing
@testable import DeskPixels

@Suite("IconPixelator")
struct IconPixelatorTests {
    static let fixtures = ["fixture-app-64", "fixture-doc-32", "fixture-photo-48x32", "fixture-tiny-8"]

    static func fixture(_ name: String, filePath: String = #filePath) throws -> PixelBuffer {
        let url = Golden.url(name, filePath: filePath)
        return try #require(PNGCodec.decode(try Data(contentsOf: url)), "missing fixture \(url.path)")
    }

    /// Every output pixel is clear or an opaque Apollo colour, and nothing opaque touches the edge except the
    /// outline colour.
    static func checkOnPalette(_ b: PixelBuffer) {
        for y in 0..<b.height {
            for x in 0..<b.width {
                let c = b[x, y]
                #expect(c == .clear || Apollo.index(of: c) != nil, "(\(x),\(y)) \(c) is off-palette")
                let edge = x == 0 || y == 0 || x == b.width - 1 || y == b.height - 1
                if edge && c != .clear { #expect(c == Role.outline.color, "(\(x),\(y)) edge pixel \(c)") }
            }
        }
    }

    @Test("Goldens: icons, documents, photos and polaroids at 16 and 12 px", arguments: fixtures)
    func goldens(_ name: String) throws {
        let source = try Self.fixture(name)
        for style in IconPixelator.Style.allCases {
            for size in [16, 12] {
                let out = try #require(IconPixelator.pixelate(source, size: size, style: style))
                #expect(out.size == ArtSize(size, size))
                Self.checkOnPalette(out)
                let golden = "icon-\(name.dropFirst("fixture-".count))-\(style.rawValue)-\(size)"
                #expect(Golden.match(out, golden), "golden \(golden)")
            }
        }
    }

    @Test("A review sheet of every golden can be written for eyeballing (DESKTERIOR_REVIEW_DIR)")
    func reviewSheet() throws {
        guard let dir = TestSupport.environment("DESKTERIOR_REVIEW_DIR") else { return }
        let styles = IconPixelator.Style.allCases
        var sheet = PixelBuffer(width: 4 + styles.count * 2 * 20, height: 4 + Self.fixtures.count * 20, fill: Ink.neutral7.color)
        for (row, name) in Self.fixtures.enumerated() {
            let source = try Self.fixture(name)
            for (i, style) in styles.enumerated() {
                for (j, size) in [16, 12].enumerated() {
                    if let out = IconPixelator.pixelate(source, size: size, style: style) {
                        sheet.blit(out, at: ArtPoint(4 + (i * 2 + j) * 20, 4 + row * 20))
                    }
                }
            }
        }
        try TestSupport.writePNG(sheet.scaledNearest(8), directory: dir, name: "icon-pixelator-review")
    }

    @Test("Photos keep at most 16 colours plus the outline and frame")
    func photoPalette() throws {
        let source = try Self.fixture("fixture-photo-48x32")
        let photo = try #require(IconPixelator.pixelate(source, size: 16, style: .photo))
        #expect(Set(photo.pixels.filter { $0.a != 0 }).count <= IconPixelator.photoColors + 1)
        let polaroid = try #require(IconPixelator.pixelate(source, size: 16, style: .polaroid))
        // A 14×14 frame inside the outline: opaque from (1,1) to (14,14), and the outline ring around it.
        #expect(polaroid.opaqueBounds() == ArtRect(0, 0, 16, 16))
        #expect(polaroid[0, 0] == .clear && polaroid[1, 0] == Role.outline.color)
        #expect(polaroid[1, 1] == Ink.neutral9.color && polaroid[14, 13] == Ink.neutral9.color)
        #expect(polaroid[1, 14] == Ink.neutral7.color)
    }

    @Test("Soft shadows do not count toward the trimmed size; faint or empty images give nil")
    func trimming() throws {
        let app = try Self.fixture("fixture-app-64")
        let bounds = IconPixelator.alphaBounds(app, minAlpha: 115)
        #expect(bounds.w <= 50 && bounds.h <= 50)
        #expect(app.opaqueBounds().w > bounds.w)
        #expect(IconPixelator.pixelate(try Self.fixture("fixture-faint-16"), style: .icon) == nil)
        #expect(IconPixelator.pixelate(PixelBuffer(width: 10, height: 10), style: .polaroid) == nil)
    }

    @Test("Pixelation is deterministic and works from CGImage")
    func deterministic() throws {
        let source = try Self.fixture("fixture-app-64")
        let image = try #require(source.makeCGImage())
        let a = IconPixelator.pixelate(image, size: 16, style: .icon)
        let b = IconPixelator.pixelate(source, size: 16, style: .icon)
        #expect(a != nil && a == b)
    }

    @Test("Style by kind; fit and crop geometry")
    func geometry() {
        #expect(IconPixelator.style(for: .image) == .polaroid && IconPixelator.style(for: .screenshot) == .polaroid)
        #expect(IconPixelator.style(for: .pdf) == .icon && IconPixelator.style(for: .video) == .photo)
        #expect(IconPixelator.style(for: .app) == .icon && IconPixelator.style(for: .folder) == .icon)
        #expect(IconPixelator.fitted(ArtSize(64, 64), into: ArtSize(14, 14)) == ArtSize(14, 14))
        #expect(IconPixelator.fitted(ArtSize(20, 32), into: ArtSize(14, 14)) == ArtSize(9, 14))
        #expect(IconPixelator.fitted(ArtSize(100, 1), into: ArtSize(14, 14)) == ArtSize(14, 1))
        #expect(IconPixelator.coverCrop(ArtSize(48, 32), aspect: ArtSize(12, 10)) == ArtRect(5, 0, 38, 32))
        #expect(IconPixelator.coverCrop(ArtSize(32, 48), aspect: ArtSize(12, 10)) == ArtRect(0, 11, 32, 26))
    }
}

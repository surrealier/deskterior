import DeskPixels
import Testing
@testable import DeskCore

@Suite("InteriorRaster")
struct InteriorRasterTests {
    static let kinds: [FileKind] = [.pdf, .image, .folder, .doc, .text, .zip, .code, .audio, .video, .app]
    static let names = ["report.pdf", "IMG_0412.png", "Projects", "보고서.docx", "notes.txt", "backup.zip",
                        "main.swift", "song.mp3", "Xcode.dmg", "Mail.app"]

    static func items(_ n: Int) -> [InteriorRaster.Item] {
        (0..<n).map { InteriorRaster.Item(kind: kinds[$0 % kinds.count], name: names[$0 % names.count], seed: UInt64($0) &* 0x9E37) }
    }

    static func onPalette(_ b: PixelBuffer) -> Bool {
        b.pixels.allSatisfy { $0 == .clear || Apollo.index(of: $0) != nil }
    }

    @Test("Every output is binary-alpha Apollo pixels")
    func palette() {
        for id in ContainerID.allCases where id.isDrawer {
            for n in [0, 1, 6, id.spec.hardCap] {
                for p in [0, 4, 8, Int(id.spec.travel ?? 1)] {
                    let b = InteriorRaster.drawerContents(id, items: Self.items(n), offsets: [1, -2, 3], opening: p)
                    #expect(b.size == InteriorRaster.contentSize(id))
                    #expect(Self.onPalette(b), "\(id) n\(n) p\(p)")
                }
            }
        }
        #expect(Self.onPalette(InteriorRaster.cubby(Self.items(12))))
        #expect(Self.onPalette(InteriorRaster.cabinet(p: [12, 14, 18], items: [Self.items(8), Self.items(12), Self.items(20)]).image))
        #expect(Self.onPalette(InteriorRaster.wastebasket(Self.items(24)).image))
        #expect(Self.onPalette(InteriorRaster.penCup(.tipping(1), mirrored: true, items: Self.items(6)).image))
    }

    @Test("Content sizes match the art: interior width less the walls, travel − 1 rows")
    func sizes() {
        #expect(InteriorRaster.contentSize(.riserLeft) == ArtSize(52, 9))
        #expect(InteriorRaster.contentSize(.cabinetTop) == ArtSize(72, 11))
        #expect(InteriorRaster.contentSize(.cabinetMiddle) == ArtSize(72, 13))
        #expect(InteriorRaster.contentSize(.cabinetFile) == ArtSize(72, 17))
        #expect(InteriorRaster.cubby([]).size == CoreLayout.riserCubby.size)
        #expect(InteriorRaster.riserDrawer(.riserLeft, p: 10, items: Self.items(3)).size
            == StorageArt.riserDrawer(p: 10).size)
        #expect(InteriorRaster.cabinet(p: [0, 0, 0], items: []).size == StorageArt.cabinet().size)
        #expect(InteriorRaster.phoneMinis(Self.items(9)).count == 6)
        #expect(InteriorRaster.penInks(Self.items(2)) == [KindIcons.color(.pdf), KindIcons.color(.image)])
    }

    @Test("Empty cabinet drawers draw exactly like StorageArt (the interiors only add contents)")
    func cabinetMatchesStorageArt() {
        for p in [[0, 0, 0], [12, 0, 0], [0, 14, 0], [5, 9, 0], [12, 14, 0], [3, 0, 0]] {
            let mine = InteriorRaster.cabinet(p: p, items: [[], [], []]).image
            #expect(mine == StorageArt.cabinet(p: p).image, "p \(p)")
        }
        // An overfull drawer pokes paper the same way.
        let jam = InteriorRaster.cabinet(p: [6, 0, 0], items: [Self.items(14), [], []])
        let art = StorageArt.cabinet(p: [6, 0, 0], jammed: [true, false, false])
        #expect(jam.image.cropped(to: ArtRect(0, 8, 80, 76)) == art.image.cropped(to: ArtRect(0, 8, 80, 76)))
        #expect(jam.hitRects == art.hitRects && jam.anchor == art.anchor)
    }

    @Test("A drawer that only peeks shows anonymous paper, never a kind's colour")
    func peekIsAnonymous() {
        for id in [ContainerID.riserLeft, .cabinetMiddle, .cabinetFile] {
            let b = InteriorRaster.drawerContents(id, items: Self.items(8), opening: 5)
            let inks = Set(b.pixels.compactMap { Apollo.index(of: $0).map { Ink(palette: $0) } })
            #expect(inks.allSatisfy { $0.ramp == .neutral }, "\(id): \(inks)")
            let open = InteriorRaster.drawerContents(id, items: Self.items(8), opening: 8)
            #expect(open != b)
        }
    }

    @Test("Jostle offsets move items within the interior; hit-testing finds the front-most item")
    func offsetsAndHits() {
        let its = Self.items(5)
        let still = InteriorRaster.itemRects(.cabinetMiddle, items: its)
        let moved = InteriorRaster.itemRects(.cabinetMiddle, items: its, offsets: [-3, 0, 0, 0, 99])
        #expect(moved[0].maxY == still[0].maxY - 3)
        #expect(moved[4].maxY - 1 == Int(InteriorRaster.baseBounds(.cabinetMiddle).upperBound))
        let homes = InteriorRaster.jostleHomes(.cabinetMiddle, items: its)
        #expect(homes.allSatisfy { InteriorRaster.baseBounds(.cabinetMiddle).contains($0) })
        let r = still[2]
        let hit = InteriorRaster.item(at: ArtPoint(r.midX, r.maxY - 1), .cabinetMiddle, items: its)
        #expect(hit != nil)
        #expect(InteriorRaster.item(at: ArtPoint(-5, -5), .cabinetMiddle, items: its) == nil)
        // Seeds come from the key, not from the process.
        let key = TokenKey(volume: "8F1C-AA", inode: 42)
        #expect(InteriorRaster.seed(key) == InteriorRaster.seed(TokenKey(volume: "8F1C-AA", inode: 42)))
        #expect(InteriorRaster.seed(key) != InteriorRaster.seed(TokenKey(volume: "8F1C-AA", inode: 43)))
    }

    @Test("Folder tab initials: two drawable characters from the start of the name, else none")
    func initials() {
        #expect(InteriorRaster.initials("report.pdf") == "RE")
        #expect(InteriorRaster.initials("IMG_0412.png") == "IM")
        #expect(InteriorRaster.initials("  (draft) memo") == "DR")
        #expect(InteriorRaster.initials("2025 taxes") == "20")
        #expect(InteriorRaster.initials("보고서.pdf") == "")
        #expect(InteriorRaster.initials("Xcode") == "")
        #expect(InteriorRaster.initials("MW") == "M", "two wide letters do not fit the label")
        #expect(InteriorRaster.initials("") == "")
    }

    @Test("Items from a desk follow container order")
    func itemsFromState() {
        var s = DeskState()
        for (i, kind) in [FileKind.pdf, .folder, .zip].enumerated() {
            s.tokens.insert(TokenKey(volume: "V", inode: UInt64(10 - i)), meta: TokenMeta(name: "f\(i)", kind: kind),
                            at: .container(.phone, order: i))
        }
        #expect(InteriorRaster.items(.phone, in: s).map(\.kind) == [.pdf, .folder, .zip])
        #expect(InteriorRaster.items(.penCup, in: s).isEmpty)
    }

    // MARK: Goldens

    @Test("Golden: riser drawer open with six items, jostled")
    func goldenRiserOpen() {
        let s = InteriorRaster.riserDrawer(.riserLeft, p: 10, items: Self.items(6), offsets: [0, -2, 0, -1, 0, 0])
        #expect(Golden.match(s.image.scaledNearest(2), "interior-riser-open"))
    }

    @Test("Golden: jammed riser drawer resting at its gap (paper only)")
    func goldenRiserJammed() {
        let s = InteriorRaster.riserDrawer(.riserRight, p: 6, items: Self.items(14))
        #expect(Golden.match(s.image.scaledNearest(2), "interior-riser-jammed"))
    }

    @Test("Golden: cabinet with the top and file drawers open, cubby and heap")
    func goldenCabinetCubbyHeap() {
        let cab = InteriorRaster.cabinet(p: [12, 0, 0], items: [Self.items(7), [], []])
        let file = InteriorRaster.cabinet(p: [0, 0, 18], items: [[], [], Self.items(10)])
        let cubby = InteriorRaster.cubby(Self.items(7))
        let heap = InteriorRaster.wastebasket(Self.items(17))
        var sheet = PixelBuffer(width: 80 * 2 + 28 + 32 + 12, height: 84, fill: Ink.neutral1.color)
        sheet.blit(cab.image, at: .zero)
        sheet.blit(file.image, at: ArtPoint(84, 0))
        sheet.blit(cubby, at: ArtPoint(168, 4))
        sheet.blit(heap.image, at: ArtPoint(168 + 30, 20))
        #expect(Golden.match(sheet.scaledNearest(2), "interior-cabinet-cubby-heap"))
    }
}

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

    @Test("Ten balls fill the basket to its mouth; from the 11th the heap shows above the rim and keeps rising")
    func heapRises() {
        func above(_ n: Int) -> Int {
            let img = InteriorRaster.wastebasket(Self.items(n)).image
            return (0..<InteriorRaster.heapRise).reduce(0) { sum, y in
                sum + (0..<img.width).filter { img[$0, y].a != 0 }.count
            }
        }
        #expect(InteriorRaster.basketSlots.count == ContainerSpec.wastebasket.hardCap)
        #expect(InteriorRaster.basketSlots.prefix(WastebasketMachine.aboveRimCount - 1).allSatisfy { $0.y >= 0 })
        #expect(InteriorRaster.basketSlots.dropFirst(WastebasketMachine.aboveRimCount - 1).allSatisfy {
            $0.y <= -3 && $0.y >= -InteriorRaster.heapRise && $0.x >= 0 && $0.x + 8 <= CoreLayout.wastebasket.w
        })
        for n in 0...10 { #expect(above(n) == 0, "n\(n)") }
        var last = 0
        for n in [11, 14, 18, 24] {
            let a = above(n)
            #expect(a > last, "n\(n): \(a) px above the rim")
            last = a
        }
        // Fullness below the rim reads through the mesh: more balls, more lit pixels.
        func lit(_ n: Int) -> Int {
            InteriorRaster.wastebasket(Self.items(n)).image.pixels.filter { $0 != .clear && $0 != Ink.neutral2.color }.count
        }
        #expect(lit(10) > lit(5) && lit(5) > lit(0))
        #expect(WastebasketMachine.heapSlot(10) == InteriorRaster.basketSlots[10])
    }

    @Test("The tipped basket: palette pixels, a pixel-exact quarter turn lying beside its spot, frames in between")
    func tippedBasket() {
        let upright = InteriorRaster.wastebasket([]).image
        let uprightCount = upright.pixels.filter { $0.a != 0 }.count
        for right in [true, false] {
            let lying = InteriorRaster.wastebasketTipped(frame: nil, right: right)
            #expect(Self.onPalette(lying.image))
            #expect(lying.image.pixels.filter { $0.a != 0 }.count == uprightCount, "a quarter turn keeps every pixel")
            // Its opaque box, placed by the anchor at the basket's foot, is `tippedRect`.
            let r = CoreLayout.wastebasket
            let origin = ArtPoint(r.midX - lying.anchor.x, r.maxY - lying.anchor.y)
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            for y in 0..<lying.size.h {
                for x in 0..<lying.size.w where lying.image[x, y].a != 0 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            let box = ArtRect(origin.x + minX, origin.y + minY, maxX - minX + 1, maxY - minY + 1)
            #expect(box == WastebasketMachine.tippedRect(right: right), "\(right): \(box)")
            for f in 0...2 {
                let s = InteriorRaster.wastebasketTipped(frame: f, right: right)
                #expect(Self.onPalette(s.image) && s.size == lying.size)
                #expect(s.image.pixels.filter { $0.a != 0 }.count == uprightCount, "shears move whole pixels")
            }
            #expect(InteriorRaster.wastebasketTipped(frame: 0, right: right) != InteriorRaster.wastebasketTipped(frame: 2, right: right))
        }
        #expect(InteriorRaster.wastebasketTipped(frame: 1, right: false).image
            == InteriorRaster.wastebasketTipped(frame: 1, right: true).image.flippedHorizontally())
    }

    @Test("A revealed drawer shows icons below 8 px; an unrevealed one shows paper above it")
    func revealOverride() {
        let its = Self.items(6)
        let paper5 = InteriorRaster.drawerContents(.riserLeft, items: its, opening: 5)
        let icons5 = InteriorRaster.drawerContents(.riserLeft, items: its, opening: 5, revealed: true)
        #expect(icons5 == InteriorRaster.drawerContents(.riserLeft, items: its, opening: 10))
        #expect(paper5 == InteriorRaster.drawerContents(.riserLeft, items: its, opening: 10, revealed: false))
        #expect(paper5 != icons5)
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

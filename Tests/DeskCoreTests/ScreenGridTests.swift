import Foundation
import Testing
@testable import DeskCore

@Suite("ScreenGrid")
struct ScreenGridTests {
    let grid = ScreenGrid.standard

    func cell(_ page: Int, _ col: Int, _ row: Int) -> ScreenCell { ScreenCell(page: page, col: col, row: row) }

    /// Every cell of `pages` pages.
    func fullPages(_ pages: Int) -> Set<ScreenCell> {
        Set((0..<pages).flatMap { p in (0..<grid.cellsPerPage).map { grid.cell(page: p, index: $0) } })
    }

    @Test("9×5 cells per page in reading order")
    func layout() {
        #expect(grid.cols == 9 && grid.rows == 5 && grid.cellsPerPage == 45)
        #expect(grid.cell(page: 0, index: 0) == cell(0, 0, 0))
        #expect(grid.cell(page: 0, index: 9) == cell(0, 0, 1))
        #expect(grid.cell(page: 2, index: 44) == cell(2, 8, 4))
        #expect(grid.contains(cell(7, 8, 4)))
        #expect(!grid.contains(cell(0, 9, 0)) && !grid.contains(cell(0, 0, 5)) && !grid.contains(cell(-1, 0, 0)))
    }

    @Test("First free cell scans from HDMI 1 in reading order and overflows to new pages")
    func firstFree() {
        #expect(grid.firstFree([]) == cell(0, 0, 0))
        #expect(grid.firstFree([cell(0, 0, 0), cell(0, 1, 0), cell(0, 3, 0)]) == cell(0, 2, 0))
        #expect(grid.firstFree(fullPages(1)) == cell(1, 0, 0))
        #expect(grid.firstFree(fullPages(3).subtracting([cell(1, 4, 2)])) == cell(1, 4, 2))
        #expect(grid.firstFree([], fromPage: 2) == cell(2, 0, 0))
    }

    @Test("Nearest free cell: the target if free, else the closest on its page, else the next pages")
    func nearestFree() {
        let target = cell(0, 4, 2)
        #expect(grid.nearestFree(to: target, []) == target)
        // Four neighbours at distance 1; reading order breaks the tie (the one above comes first).
        #expect(grid.nearestFree(to: target, [target]) == cell(0, 4, 1))
        #expect(grid.nearestFree(to: target, [target, cell(0, 4, 1)]) == cell(0, 3, 2))
        // Corner target, two free cells: the closer wins regardless of reading order.
        let occupied = fullPages(1).subtracting([cell(0, 0, 0), cell(0, 7, 4)])
        #expect(grid.nearestFree(to: cell(0, 8, 4), occupied) == cell(0, 7, 4))
        // A full page spills to the first free cell after it.
        #expect(grid.nearestFree(to: cell(1, 4, 2), fullPages(2)) == cell(2, 0, 0))
        // Out-of-range targets clamp onto the grid.
        #expect(grid.nearestFree(to: cell(0, 20, -3), []) == cell(0, 8, 0))
    }

    @Test("Page count: one past the last used page; trailing empty pages disappear, HDMI 1 stays")
    func pageCountAndPruning() {
        #expect(grid.pageCount([ScreenCell]()) == 1)
        #expect(grid.pageCount([cell(0, 3, 3)]) == 1)
        #expect(grid.pageCount([cell(0, 0, 0), cell(3, 1, 1)]) == 4)
        // Middle pages may be empty; only trailing ones are pruned.
        var used: Set<ScreenCell> = [cell(0, 0, 0), cell(2, 0, 0)]
        #expect(grid.pageCount(used) == 3)
        used.remove(cell(2, 0, 0))
        #expect(grid.pageCount(used) == 1)
        used.remove(cell(0, 0, 0))
        #expect(grid.pageCount(used) == 1)
    }

    @Test("The allocator hands out free cells in order across pages without repeats")
    func allocator() {
        var a = ScreenGrid.Allocator(grid: grid, occupied: [cell(0, 0, 0), cell(0, 2, 0)])
        #expect(a.next() == cell(0, 1, 0))
        #expect(a.next() == cell(0, 3, 0))
        a.take(cell(0, 4, 0))
        #expect(a.next() == cell(0, 5, 0))
        var cells: [ScreenCell] = []
        for _ in 0..<100 { cells.append(a.next()) }
        #expect(Set(cells).count == 100)
        #expect(cells == cells.sorted())
        #expect(cells.last!.page == 2)
    }

    @Test("Clean up by name sorts case-insensitively with numbers by value")
    func cleanUpByName() {
        let names = ["file 10.txt", "File 2.txt", "apple.txt", "Zebra.png", "éclair.txt", "file 1.txt"]
        let items = names.enumerated().map { (key: TokenKey(volume: "V", inode: UInt64($0.offset)), meta: TokenMeta(name: $0.element, kind: .text)) }
        let out = grid.cleanUp(items, by: .name)
        let order = out.map { r in items.first { $0.key == r.key }!.meta.name }
        #expect(order == ["apple.txt", "éclair.txt", "file 1.txt", "File 2.txt", "file 10.txt", "Zebra.png"])
        #expect(out.map(\.cell) == (0..<6).map { grid.cell(page: 0, index: $0) })
    }

    @Test("Clean up by kind groups kinds, then names; by date added puts the newest first")
    func cleanUpByKindAndDate() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let specs: [(String, FileKind, Double?)] = [
            ("b.png", .image, 30), ("a.txt", .text, 10), ("Folder", .folder, 20), ("c.png", .image, nil), ("a.png", .image, 40),
        ]
        let items = specs.enumerated().map { i, s in
            (key: TokenKey(volume: "V", inode: UInt64(i)), meta: TokenMeta(name: s.0, kind: s.1, added: s.2.map { t0.addingTimeInterval($0) }))
        }
        func names(_ order: ScreenGrid.SortKey) -> [String] {
            grid.cleanUp(items, by: order).map { r in items.first { $0.key == r.key }!.meta.name }
        }
        #expect(names(.kind) == ["Folder", "a.txt", "a.png", "b.png", "c.png"])
        #expect(names(.dateAdded) == ["a.png", "b.png", "Folder", "a.txt", "c.png"])
    }

    @Test("Clean up of more than a page continues on HDMI 2")
    func cleanUpOverflow() {
        let items = (0..<50).map { (key: TokenKey(volume: "V", inode: UInt64($0)), meta: TokenMeta(name: String(format: "f%03d", $0), kind: .text)) }
        let cells = grid.cleanUp(items, by: .name).map(\.cell)
        #expect(cells[44] == cell(0, 8, 4))
        #expect(cells[45] == cell(1, 0, 0))
        #expect(cells[49] == cell(1, 4, 0))
    }
}

import Foundation

/// The monitor screen as pages of 9×5 cells (DESIGN §2.2 E2). Pages are unlimited; the page count is derived
/// from the occupied cells, so trailing empty pages disappear on their own and page 0 (HDMI 1) always exists.
/// Free cells are searched in reading order: page, then row, then column.
public struct ScreenGrid: Sendable, Equatable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int = 9, rows: Int = 5) {
        precondition(cols > 0 && rows > 0, "empty screen grid")
        self.cols = cols
        self.rows = rows
    }

    public static let standard = ScreenGrid()

    public var cellsPerPage: Int { cols * rows }

    public func contains(_ c: ScreenCell) -> Bool {
        c.page >= 0 && c.col >= 0 && c.col < cols && c.row >= 0 && c.row < rows
    }

    /// The cell at reading-order `index` (0 ..< cellsPerPage) of `page`.
    public func cell(page: Int, index: Int) -> ScreenCell {
        ScreenCell(page: page, col: index % cols, row: index / cols)
    }

    /// Pages in use: one past the highest occupied page, at least 1.
    public func pageCount(_ occupied: some Sequence<ScreenCell>) -> Int {
        (occupied.map(\.page).max() ?? 0) + 1
    }

    /// The first free cell scanning from page `fromPage`, cell 0. Always succeeds (pages are unlimited).
    public func firstFree(_ occupied: Set<ScreenCell>, fromPage: Int = 0) -> ScreenCell {
        var allocator = Allocator(grid: self, occupied: occupied, page: max(0, fromPage))
        return allocator.next()
    }

    /// The free cell nearest to `target` on its page (Euclidean in cells; ties in reading order). A full page
    /// spills to the first free cell of the following pages. A free `target` is returned as is.
    public func nearestFree(to target: ScreenCell, _ occupied: Set<ScreenCell>) -> ScreenCell {
        let page = max(0, target.page)
        let t = ScreenCell(page: page, col: min(max(target.col, 0), cols - 1), row: min(max(target.row, 0), rows - 1))
        if !occupied.contains(t) { return t }
        var best: (cell: ScreenCell, d: Int)?
        for i in 0..<cellsPerPage {
            let c = cell(page: page, index: i)
            guard !occupied.contains(c) else { continue }
            let d = (c.col - t.col) * (c.col - t.col) + (c.row - t.row) * (c.row - t.row)
            if best == nil || d < best!.d { best = (c, d) }
        }
        return best?.cell ?? firstFree(occupied, fromPage: page + 1)
    }

    /// Hands out free cells in reading order without rescanning from the start, for bursts of new files.
    public struct Allocator: Sendable {
        public let grid: ScreenGrid
        public private(set) var occupied: Set<ScreenCell>
        private var page: Int
        private var index = 0

        public init(grid: ScreenGrid, occupied: Set<ScreenCell>, page: Int = 0) {
            self.grid = grid
            self.occupied = occupied
            self.page = page
        }

        /// The next free cell, which is then marked occupied.
        public mutating func next() -> ScreenCell {
            while true {
                let c = grid.cell(page: page, index: index)
                index += 1
                if index == grid.cellsPerPage {
                    index = 0
                    page += 1
                }
                if occupied.insert(c).inserted { return c }
            }
        }

        /// Marks `c` occupied (a cell taken by other means during the burst).
        public mutating func take(_ c: ScreenCell) {
            occupied.insert(c)
        }
    }

    // MARK: Clean Up

    /// Monitor context menu ▸ Clean Up By.
    public enum SortKey: String, Codable, CaseIterable, Sendable {
        case name, kind, dateAdded
    }

    /// Packs `items` into consecutive cells from page 0, cell 0, sorted by `key`. Ties fall back to the
    /// display name, then the token key, so the result is deterministic.
    public func cleanUp(_ items: [(key: TokenKey, meta: TokenMeta)], by key: SortKey) -> [(key: TokenKey, cell: ScreenCell)] {
        let sorted = items.sorted { a, b in
            switch key {
            case .name:
                break
            case .kind:
                let ka = Self.kindOrder(a.meta.kind), kb = Self.kindOrder(b.meta.kind)
                if ka != kb { return ka < kb }
            case .dateAdded:
                // Newest first; undated items last.
                switch (a.meta.added, b.meta.added) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            }
            return Self.nameOrder(a, b)
        }
        return sorted.enumerated().map { i, item in
            (item.key, cell(page: i / cellsPerPage, index: i % cellsPerPage))
        }
    }

    /// Finder-like name order: case-, width- and diacritic-insensitive with numeric runs compared by value;
    /// the key breaks ties.
    public static func nameOrder(_ a: (key: TokenKey, meta: TokenMeta), _ b: (key: TokenKey, meta: TokenMeta)) -> Bool {
        let r = compareNames(a.meta.displayName, b.meta.displayName)
        return r != .orderedSame ? r == .orderedAscending : a.key < b.key
    }

    /// Locale-independent name comparison used everywhere names are sorted.
    public static func compareNames(_ a: String, _ b: String) -> ComparisonResult {
        let r = a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive, .diacriticInsensitive])
        return r != .orderedSame ? r : a.compare(b)
    }

    private static let kindRank: [FileKind] = [
        .folder, .app, .doc, .pdf, .text, .code, .image, .screenshot, .video, .audio, .zip, .dmg, .unknown,
    ]

    private static func kindOrder(_ k: FileKind) -> Int { kindRank.firstIndex(of: k) ?? kindRank.count }
}

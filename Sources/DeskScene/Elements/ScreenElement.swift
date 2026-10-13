import DeskCore
import DeskPixels
import Foundation
import SpriteKit

/// The monitor screen as the desktop (DESIGN §2.2 E2, §3.3, §3.4): the current HDMI page's tokens as 16-px icons
/// on the 9×5 grid, with Finder-style selection (a dark backdrop with a `Role.selection` fill, and a label pill
/// for the primary selection), a dark label pill for the hovered token (under the icon, or over it on the bottom
/// row), the drop brackets while carrying (a token that would be swapped away shows as a ghost in the cell it
/// would go to), the marquee, and the print-in, slide and pulse animations. The whole screen layer is one CPU
/// composite (`compose`, 196×108, clipped to the glass) re-uploaded only when it changes, so it is cheap and
/// testable without Metal. Labels drawn over other icons hit-test first: what you see is what you click.
///
/// Gestures: press selects (⇧ extends, ⌘ adds an unselected token), click narrows to the token (⌘-click on a
/// selected one deselects it, on release as in Finder, so a ⌘-drag carries the whole selection), double-click
/// opens, a drag carries the selection (`CarrySession`), right-click shows the token menu. Empty-screen gestures
/// (marquee, clearing the selection, paging by scroll) arrive through the `MonitorElement`, which owns the glass.
public final class ScreenElement: DeskElement {
    public let id = "screen"
    public let root = SKNode()
    unowned let context: SceneContext
    weak var monitor: MonitorElement?

    private let content = SKSpriteNode()
    private(set) var state: DeskState?
    /// Rows the monitor's pop-in shows (0…5).
    private(set) var rowsShown = MonitorMachine.rows
    /// The monitor shows the desktop (on, no card, not AV).
    private(set) var showsTokens = false
    /// Tokens in hand: not drawn until they land or spring back.
    var carried: Set<TokenKey> = [] { didSet { if carried != oldValue { dirty = true } } }
    /// The cell a carry would drop into.
    var dropTarget: ScreenCell? { didSet { if dropTarget != oldValue { dirty = true } } }
    /// The marquee rect (canvas px) while dragging one.
    var marquee: ArtRect? { didSet { if marquee != oldValue { dirty = true } } }
    public private(set) var hovered: TokenKey?
    private var printIn: [TokenKey: Double] = [:]
    /// Tokens sliding to a new cell (a swap, undo, Clean Up): canvas top-left they left from, progress 0…1.
    private var slides: [TokenKey: (from: ArtPoint, t: Double)] = [:]
    private var pulse: (key: TokenKey, age: Double)?
    /// Show on Desk's token, selected as soon as it is on show (after a power-on bloom, say).
    private var pendingSelect: TokenKey?
    private var selectionRevision = -1
    private var dirty = true
    /// The press added its token to the selection (⌘ on an unselected token), so its click must not toggle it off.
    private var pressAdded = false
    /// Labels as last drawn (canvas px), topmost first: they hit-test before the icons they cover.
    private(set) var labelRects: [(key: TokenKey, rect: ArtRect)] = []
    /// The last composite (tests, CRT frames).
    private(set) var image: PixelBuffer?

    static let printInDuration = 4.0 / 12
    static let slideDuration = 6.0 / 60
    static let pulseDuration = 2.0
    static let labelMaxWidth = 84
    /// Icon inset inside a 20-px cell.
    static let iconInset = 2

    init(context: SceneContext) {
        self.context = context
        content.isHidden = true
        root.addChild(content)
    }

    // MARK: Geometry

    /// The glass in canvas px.
    var screenRect: ArtRect { context.layout.rect(CoreLayout.screen) }

    /// A cell in canvas px.
    public func cellRect(_ col: Int, _ row: Int) -> ArtRect {
        context.layout.rect(CoreLayout.screenCellRect(col: col, row: row))
    }

    /// The 16×16 icon square of a cell in canvas px.
    func iconRect(_ col: Int, _ row: Int) -> ArtRect {
        let c = cellRect(col, row)
        return ArtRect(c.x + Self.iconInset, c.y + Self.iconInset, 16, 16)
    }

    /// The cell whose square is nearest to `p` (inside or on the gutters of the grid).
    func cell(nearest p: ArtPoint) -> (col: Int, row: Int) {
        let o = context.layout.point(CoreLayout.screenGridOrigin)
        let n = CoreLayout.screenCell
        let col = Int(floor(Double(p.x - o.x) / Double(n))), row = Int(floor(Double(p.y - o.y) / Double(n)))
        return (min(max(col, 0), CoreLayout.screenColumns - 1), min(max(row, 0), CoreLayout.screenRows - 1))
    }

    // MARK: State

    public func layout(_ layout: SceneLayout) {
        dirty = true
        render()
    }

    public func apply(_ s: DeskState) {
        let old = state
        state = s
        context.selection.follow(s)
        if let h = hovered { hovered = s.tokens.contains(s.currentKey(for: h)) ? s.currentKey(for: h) : nil }
        carried = Set(carried.map(s.currentKey).filter(s.tokens.contains))
        printIn = printIn.filter { s.tokens.contains($0.key) }
        if let old { startSlides(from: old, to: s) }
        dirty = true
        render()
    }

    /// Tokens that moved between two cells of the page on show (and were not carried there) slide over 6 frames.
    private func startSlides(from old: DeskState, to s: DeskState) {
        slides = slides.filter { s.tokens.contains($0.key) }
        guard showsTokens, old.monitor.page == s.monitor.page, !old.monitor.av, !s.monitor.av else { return }
        for t in visibleTokens() where !carried.contains(t.key) && printIn[t.key] == nil {
            guard let was = old.tokens.location(of: t.key)?.cell, was.page == t.cell.page, was != t.cell else { continue }
            slides[t.key] = (drawnOrigin(t.key, at: was), 0)
        }
    }

    /// The monitor's say on what shows (pop-in rows, desktop visible).
    func setVisibility(showsTokens: Bool, rowsShown: Int) {
        guard showsTokens != self.showsTokens || rowsShown != self.rowsShown else { return }
        self.showsTokens = showsTokens
        self.rowsShown = rowsShown
        if !showsTokens {
            hovered = nil
            slides.removeAll()
        }
        dirty = true
    }

    /// The current page's tokens that can be seen, in reading order.
    func visibleTokens() -> [(key: TokenKey, cell: ScreenCell, meta: TokenMeta)] {
        guard showsTokens, let s = state else { return [] }
        let page = s.monitor.page
        var out: [(key: TokenKey, cell: ScreenCell, meta: TokenMeta)] = []
        for c in s.tokens.occupiedCells where c.page == page && c.row < rowsShown {
            guard let key = s.tokens.occupant(of: c), let meta = s.tokens.meta(of: key) else { continue }
            out.append((key, c, meta))
        }
        return out.sorted { $0.cell < $1.cell }
    }

    /// The icon rect of a token on show (nil when it is not on the current page or hidden).
    public func iconRect(of key: TokenKey) -> ArtRect? {
        visibleTokens().first { $0.key == key }.map { iconRect($0.cell.col, $0.cell.row) }
    }

    /// Tokens on show: on the current page of a lit desktop, including ones in hand or about to print in (they
    /// are only moments from showing). The selection keeps only these.
    public var shownTokens: Set<TokenKey> { Set(visibleTokens().map(\.key)) }

    /// Tokens drawn on the screen now.
    public var visibleTokenCount: Int { visibleTokens().count }

    /// The first empty cell of the current page (canvas px), if any.
    public func firstEmptyCell() -> ArtRect? {
        guard let s = state else { return nil }
        let occupied = s.tokens.occupiedCells
        for i in 0..<ScreenGrid.standard.cellsPerPage {
            let c = ScreenGrid.standard.cell(page: s.monitor.page, index: i)
            if !occupied.contains(c) { return cellRect(c.col, c.row) }
        }
        return nil
    }

    /// The token whose drawn label or icon covers `p` (a label first: it is drawn over the icons around it).
    /// Tokens in hand or still waiting to print in are not there.
    func token(at p: ArtPoint) -> (key: TokenKey, cell: ScreenCell)? {
        let tokens = visibleTokens().filter { !carried.contains($0.key) && (printIn[$0.key] ?? 0) >= 0 }
        for l in labelRects where l.rect.contains(p) {
            if let t = tokens.first(where: { $0.key == l.key }) { return (t.key, t.cell) }
        }
        for t in tokens where iconRect(t.cell.col, t.cell.row).contains(p) { return (t.key, t.cell) }
        return nil
    }

    // MARK: DeskElement

    public func hitTest(_ p: ArtPoint) -> Hit? {
        guard let t = token(at: p) else { return nil }
        return Hit(element: id, part: "token", rect: iconRect(t.cell.col, t.cell.row), token: t.key)
    }

    public func hover(_ hit: Hit?) -> Bool {
        let key = hit?.token
        guard key != hovered else { return false }
        hovered = key
        dirty = true
        render()
        return true
    }

    public func hoverStyle(_ hit: Hit) -> HoverStyle {
        guard let key = hit.token, let meta = state?.tokens.meta(of: key) else { return .standard }
        return .image(TokenArt.hoverRing(TokenArt.icon(key, meta, context)), at: ArtPoint(hit.rect.x - 2, hit.rect.y - 2))
    }

    /// The token's kind and date (its name is already on the label; the full name joins only when the label had
    /// to shorten it), above the icon and its label, kept on the glass.
    public func tooltip(_ hit: Hit) -> TooltipSpec? {
        guard let key = hit.token, let meta = state?.tokens.meta(of: key) else { return nil }
        let detail = TokenArt.detail(meta)
        var anchor = hit.rect
        if let label = labelRects.first(where: { $0.key == key }) { anchor = anchor.union(label.rect) }
        let shortened = context.font.map { PixelText.truncated(meta.displayName, maxWidth: Self.labelMaxWidth, font: $0) != meta.displayName } ?? false
        var spec = shortened ? TooltipSpec(title: meta.displayName, detail: detail, anchor: anchor)
            : TooltipSpec(title: detail, anchor: anchor)
        spec.prefersAbove = true
        spec.bounds = screenRect
        return spec
    }

    public func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard let key = hit.token, let s = state, s.tokens.contains(key) else { return .pass }
        let selection = context.selection
        switch gesture {
        case let .press(_, mods):
            pressAdded = false
            if mods.contains(.command) {
                // ⌘ adds at once; taking a selected token out waits for the click, so a ⌘-drag keeps them all.
                if !selection.contains(key) {
                    selection.click(key, mods: [.command])
                    pressAdded = true
                }
            } else if mods.contains(.shift) {
                selection.click(key, mods: mods)
            } else if !selection.contains(key) {
                selection.select(key)
            }
            refreshIfSelectionChanged()
            return .handled
        case let .click(_, mods, count):
            defer { pressAdded = false }
            if count == 2 {
                // Only an exact double-click opens (a triple-click does not open twice).
                let keys = selection.contains(key) ? selection.sorted.filter(shownTokens.contains) : [key]
                context.dispatch(.requestOpen(keys))
            } else if count == 1 {
                if mods.contains(.command) {
                    if !pressAdded { selection.click(key, mods: [.command]) }
                } else if mods.isEmpty {
                    selection.select(key)
                }
                refreshIfSelectionChanged()
            }
            return .handled
        case let .dragBegan(from, at, _):
            pressAdded = false
            if !selection.contains(key) { selection.select(key) }
            refreshIfSelectionChanged()
            let onPage = visibleTokens().filter { selection.contains($0.key) }
            var keys = [key] + onPage.map(\.key).filter { $0 != key }
            keys = keys.filter { s.tokens.contains($0) }
            let origins = keys.compactMap { k in onPage.first { $0.key == k }.map { iconRect($0.cell.col, $0.cell.row).origin } }
            guard origins.count == keys.count else { return .pass }
            let session = CarrySession(keys: keys, origins: origins, grab: from, context: context)
            session.moved(to: at, mods: [])
            return .drag(session)
        case .scroll:
            return monitor?.handle(gesture, Hit(element: "monitor", part: "monitor.screen", rect: screenRect)) ?? .pass
        case .cancelPress:
            pressAdded = false
            return .handled
        }
    }

    public func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        guard screenRect.contains(p), let s = state else { return nil }
        guard showsTokens else { return .bonk(nil) }
        let c = cell(nearest: p)
        let aim = ScreenCell(page: s.monitor.page, col: c.col, row: c.row)
        if tokens.count > 1, !Self.pourFits(tokens.map(s.currentKey), at: aim, in: s) { return .bonk(.containerFull) }
        return .accept(aim.location)
    }

    /// Whether several tokens dropped at `aim` can pour in on its page: they all fit there, and the page is not
    /// full but for their own cells while `aim` holds another token (they would only pour straight back).
    static func pourFits(_ keys: [TokenKey], at aim: ScreenCell, in s: DeskState, grid: ScreenGrid = .standard) -> Bool {
        let movers = Set(keys)
        var own = 0, others = 0
        for c in s.tokens.occupiedCells where c.page == aim.page {
            if let k = s.tokens.occupant(of: c), movers.contains(k) { own += 1 } else { others += 1 }
        }
        let room = grid.cellsPerPage - others
        guard movers.count <= room else { return false }
        if room == own, let occupant = s.tokens.occupant(of: aim), !movers.contains(occupant) { return false }
        return true
    }

    public func menu(_ hit: Hit) -> MenuSpec? {
        guard let key = hit.token, let s = state else { return nil }
        let selection = context.selection
        selection.restrict(to: shownTokens)
        if !selection.contains(key) { selection.select(key) }
        refreshIfSelectionChanged()
        return MenuSpec.token(selection.sorted, s)
    }

    public func accessibilityItems() -> [AXItem] {
        visibleTokens().map { t in
            AXItem(id: "token.\(t.key.inode)", label: t.meta.displayName, role: .token,
                   frame: iconRect(t.cell.col, t.cell.row), token: t.key)
        }
    }

    public var needsFrames: Bool { !printIn.isEmpty || pulse != nil || !slides.isEmpty }

    public func step(_ dt: Double) {
        if !printIn.isEmpty {
            for (k, t) in printIn {
                let next = t + dt
                printIn[k] = next >= Self.printInDuration ? nil : next
            }
            dirty = true
        }
        if !slides.isEmpty {
            for (k, v) in slides {
                let next = v.t + dt / Self.slideDuration
                slides[k] = next >= 1 ? nil : (v.from, next)
            }
            dirty = true
        }
        if let p = pulse {
            let age = p.age + dt
            pulse = age >= Self.pulseDuration ? nil : (p.key, age)
            dirty = true
        }
        selectPending()
        if pulse == nil { pendingSelect = nil }
        render()
    }

    public func settle() {
        printIn.removeAll()
        slides.removeAll()
        selectPending()
        pendingSelect = nil
        pulse = nil
        dirty = true
        render()
    }

    // MARK: Animations and commands

    /// Scanline print-in for new or returning tokens; several stagger in order (at most ~2.6 s for a parade).
    func playPrintIn(_ keys: [TokenKey]) {
        guard !keys.isEmpty else { return }
        let stagger = min(0.04, 2.6 / Double(keys.count))
        for (i, k) in keys.enumerated() { printIn[k] = -Double(i) * stagger }
        dirty = true
    }

    /// Show on Desk: the token is selected (once it is on show) and its ring blinks for 2 s.
    func playPulse(_ key: TokenKey) {
        pulse = (key, 0)
        pendingSelect = key
        selectPending()
        dirty = true
    }

    private func selectPending() {
        guard let key = pendingSelect, shownTokens.contains(key) else { return }
        pendingSelect = nil
        context.selection.select(key)
    }

    /// A puff where a removed token was, when that cell is on show.
    func playPoof(at loc: Location) {
        guard let c = loc.cell, showsTokens, c.page == state?.monitor.page else { return }
        let r = cellRect(c.col, c.row)
        context.fx.puff(at: ArtPoint(r.midX, r.maxY - 2))
    }

    /// ⌘A: every token on the page.
    func selectAll() {
        let keys = visibleTokens().map(\.key)
        context.selection.set(Set(keys), primary: context.selection.primary ?? keys.first)
        refreshIfSelectionChanged()
    }

    /// Arrow keys: the nearest token in that direction (the first one when nothing is selected).
    func moveSelection(dx: Int, dy: Int) {
        let tokens = visibleTokens()
        guard !tokens.isEmpty else { return }
        guard let current = context.selection.primary, let from = tokens.first(where: { $0.key == current })?.cell else {
            context.selection.select(tokens[0].key)
            refreshIfSelectionChanged()
            return
        }
        var best: (key: TokenKey, score: Int)?
        for t in tokens where t.key != current {
            let ddx = t.cell.col - from.col, ddy = t.cell.row - from.row
            let along = ddx * dx + ddy * dy
            guard along > 0 else { continue }
            let across = abs(ddx * dy) + abs(ddy * dx)
            let score = along + 3 * across
            if best == nil || score < best!.score { best = (t.key, score) }
        }
        if let best {
            context.selection.select(best.key)
            refreshIfSelectionChanged()
        }
    }

    /// Selects the tokens a marquee covers (`base` stays selected).
    func marqueeSelect(_ rect: ArtRect, base: Set<TokenKey>) {
        var keys = base
        for t in visibleTokens() where iconRect(t.cell.col, t.cell.row).intersects(rect) { keys.insert(t.key) }
        context.selection.set(keys, primary: context.selection.primary)
        marquee = rect
        refreshIfSelectionChanged()
    }

    /// Starts a marquee from `from` (an empty spot on the glass).
    func beginMarquee(from: SIMD2<Float>, mods: InputEvent.Modifiers) -> MarqueeDrag {
        let base = mods.contains(.command) || mods.contains(.shift) ? context.selection.keys : []
        if base.isEmpty { context.selection.clear() }
        return MarqueeDrag(screen: self, from: from, base: base)
    }

    func refreshIfSelectionChanged() {
        if context.selection.revision != selectionRevision { dirty = true }
        render()
    }

    // MARK: Rendering

    /// Re-composites and uploads when something changed.
    func render() {
        if context.selection.revision != selectionRevision { dirty = true }
        guard dirty else { return }
        dirty = false
        selectionRevision = context.selection.revision
        let image = compose()
        self.image = image
        let rect = screenRect
        content.zPosition = context.placementZ("monitor.screen") + 0.1
        if image.opaqueBounds().isEmpty {
            content.isHidden = true
        } else {
            content.texture = TextureFactory.texture(image)
            context.space.place(content, at: rect)
            content.isHidden = false
        }
    }

    /// Where a token's icon is drawn now (canvas top-left): its cell, or on its way there while sliding.
    private func drawnOrigin(_ key: TokenKey, at cell: ScreenCell) -> ArtPoint {
        let to = iconRect(cell.col, cell.row).origin
        guard let slide = slides[key] else { return to }
        let e = 1 - (1 - slide.t) * (1 - slide.t)
        return ArtPoint(slide.from.x + Int((Double(to.x - slide.from.x) * e).rounded()),
                        slide.from.y + Int((Double(to.y - slide.from.y) * e).rounded()))
    }

    /// The screen layer (screen px, transparent where the wallpaper shows).
    public func compose() -> PixelBuffer {
        let screen = screenRect
        var c = PixelCanvas(width: screen.w, height: screen.h, artOrigin: screen.origin)
        labelRects = []
        guard let s = state else { return c.buffer }
        let tokens = visibleTokens().filter { !carried.contains($0.key) }
        func local(_ r: ArtRect) -> ArtRect { r.offsetBy(-screen.x, -screen.y) }
        let selection = context.selection
        var drawn: [TokenKey: ArtRect] = [:]
        if let target = dropTarget, target.page == s.monitor.page, showsTokens {
            TokenArt.drawDropTarget(&c, local(cellRect(target.col, target.row)))
            // A single carried token over an occupied cell swaps with it: a ghost of the occupant waits in the
            // cell the carry came from.
            if carried.count == 1, let lifted = carried.first, let from = s.tokens.location(of: lifted)?.cell,
               from.page == s.monitor.page, let occupant = s.tokens.occupant(of: target), occupant != lifted,
               let meta = s.tokens.meta(of: occupant) {
                c.blit(TokenArt.ghost(TokenArt.icon(occupant, meta, context)), at: local(iconRect(from.col, from.row)).origin)
            }
        }
        for t in tokens {
            // A token waiting for its turn to print in is not there yet.
            if let age = printIn[t.key], age < 0 { continue }
            let icon = local(ArtRect(origin: drawnOrigin(t.key, at: t.cell), size: ArtSize(16, 16)))
            drawn[t.key] = icon
            if selection.contains(t.key) { TokenArt.drawSelectionBackdrop(&c, icon) }
            var image = TokenArt.icon(t.key, t.meta, context)
            if let age = printIn[t.key] { image = TokenArt.printing(image, progress: age / Self.printInDuration) }
            c.blit(image, at: icon.origin)
            if let tag = TokenArt.tagInk(t.meta.tags) {
                c.blit(KindIcons.tagStripe(tag, width: 12).image, at: ArtPoint(icon.x + 2, icon.maxY))
            }
            if let p = pulse, p.key == t.key, Int(p.age * 4) % 2 == 0 {
                c.roundedRectStroke(icon.insetBy(-2, -2), radius: 2, .walnut5)
                c.roundedRectStroke(icon.insetBy(-3, -3), radius: 3, .neutral0)
            }
        }
        if let m = marquee { TokenArt.drawMarquee(&c, local(m.intersection(screen))) }
        guard let font = context.font else { return c.buffer }
        // Labels last, over neighbouring icons: the hovered token's and the primary selection's (when they would
        // overlap, the hovered one wins). A label sits under its icon, or over it when the glass ends below.
        var labels: [(key: TokenKey, image: PixelBuffer, at: ArtPoint)] = []
        for (key, selected) in [(hovered, false), (selection.primary, true)] {
            guard let key, let icon = drawn[key], !(selected && key == hovered), let t = tokens.first(where: { $0.key == key })
            else { continue }
            let label = TokenArt.label(t.meta, selected: selected || selection.contains(key), font: font)
            let x = min(max(icon.midX - label.width / 2, 1), c.width - 1 - label.width)
            let below = icon.maxY + 1
            let y = below + label.height <= c.height ? below : max(0, icon.minY - 1 - label.height)
            let r = ArtRect(x, y, label.width, label.height)
            if labels.contains(where: { ArtRect(origin: $0.at, size: $0.image.size).intersects(r) }) { continue }
            labels.append((key, label, ArtPoint(x, y)))
        }
        for l in labels.reversed() { c.blit(l.image, at: l.at) }
        labelRects = labels.map { ($0.key, ArtRect(origin: $0.at, size: $0.image.size).offsetBy(screen.x, screen.y)) }
        return c.buffer
    }
}

/// The marquee on empty glass: a dotted rectangle that selects every token it touches (⇧/⌘ add to the
/// selection the drag started with).
final class MarqueeDrag: DragController {
    private weak var screen: ScreenElement?
    private let from: SIMD2<Float>
    private let base: Set<TokenKey>
    private(set) var isFinished = false

    init(screen: ScreenElement, from: SIMD2<Float>, base: Set<TokenKey>) {
        self.screen = screen
        self.from = from
        self.base = base
    }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard let screen else { return }
        let a = ArtPoint(Int(from.x), Int(from.y)), b = ArtPoint(Int(p.x), Int(p.y))
        let r = ArtRect(min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x) + 1, abs(a.y - b.y) + 1)
        screen.marqueeSelect(r.intersection(screen.screenRect), base: base)
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        moved(to: p, mods: mods)
        finish()
    }

    func cancelled() {
        screen?.context.selection.set(base)
        finish()
    }

    private func finish() {
        screen?.marquee = nil
        screen?.render()
        isFinished = true
    }

    func step(_ dt: Double) {}
    var needsFrames: Bool { false }
}

/// How tokens look on the screen and in hand: real or kind icons with the alias arrow, tag stripes, labels and
/// highlights, and the tooltip's detail line.
public enum TokenArt {
    private static var kindIcons: [FileKind: PixelBuffer] = [:]

    /// The token's 16-px icon: the pixelated real icon when it has arrived, else the hand-drawn kind icon; an
    /// alias gets the arrow in its bottom-left corner.
    static func icon(_ key: TokenKey, _ meta: TokenMeta, _ context: SceneContext) -> PixelBuffer {
        var image = context.icons[key] ?? kindIcon(meta.kind)
        if meta.isAlias { image.blit(KindIcons.aliasOverlay().image, at: ArtPoint(0, 10)) }
        return image
    }

    static func kindIcon(_ kind: FileKind) -> PixelBuffer {
        if let hit = kindIcons[kind] { return hit }
        let image = KindIcons.icon(IconKind(rawValue: kind.rawValue) ?? .unknown, size: 16).image
        kindIcons[kind] = image
        return image
    }

    /// The scanline print-in (4 frames): rows appear top to bottom behind a bright scanline.
    static func printing(_ icon: PixelBuffer, progress: Double) -> PixelBuffer {
        let rows = min(icon.height, Int((progress * Double(icon.height)).rounded(.up)) + 1)
        var out = icon.cropped(to: ArtRect(0, 0, icon.width, rows))
        if rows < icon.height {
            var full = PixelBuffer(width: icon.width, height: icon.height)
            full.blit(out, at: .zero)
            for x in 0..<icon.width where icon.pixel(x, rows - 1).a != 0 { full[x, rows - 1] = Ink.neutral9.color }
            out = full
        }
        return out
    }

    /// Finder tag colours by name (English and Korean); other tags have no stripe.
    static func tagInk(_ tags: [String]) -> Ink? {
        for tag in tags {
            switch tag.lowercased() {
            case "red", "빨간색": return .red4
            case "orange", "주황색": return .red5
            case "yellow", "노란색": return .walnut5
            case "green", "초록색": return .green4
            case "blue", "파란색": return .blue4
            case "purple", "보라색": return .purple3
            case "gray", "grey", "회색": return .neutral6
            default: continue
            }
        }
        return nil
    }

    /// A token's name label: a `Role.selection` pill when selected, a dark pill when only hovered, each with a
    /// full 1-px rim so it reads over the sky and over other icons alike.
    static func label(_ meta: TokenMeta, selected: Bool, font: PixelFont) -> PixelBuffer {
        let name = PixelText.truncated(meta.displayName, maxWidth: ScreenElement.labelMaxWidth, font: font)
        let (rim, fill, shadow): (Ink, Ink, Ink) = selected ? (.blue0, Role.selection, .blue1) : (.neutral0, .neutral2, .neutral0)
        let text = PixelText.line(name, .neutral9, font: font)
        var c = PixelCanvas(width: text.width + 6, height: text.height + 4)
        c.roundedRectFill(c.bounds, radius: 2, rim)
        c.roundedRectFill(c.bounds.insetBy(1, 1), radius: 1, fill)
        c.blit(PixelText.silhouette(text, shadow), at: ArtPoint(4, 3))
        c.blit(text, at: ArtPoint(3, 2))
        return c.buffer
    }

    /// The hover ring round an icon's silhouette: white inside, black outside, so it reads on any sky or icon.
    /// Origin = the icon's top-left − (2, 2).
    static func hoverRing(_ icon: PixelBuffer) -> PixelBuffer {
        let inner = icon.outlined(.neutral9)
        var body = PixelBuffer(width: inner.width, height: inner.height)
        body.blit(icon, at: ArtPoint(1, 1))
        body.blit(inner, at: .zero)
        var ring = body.outlined(.neutral0)
        ring.blit(inner, at: ArtPoint(1, 1))
        return ring
    }

    /// A token about to be swapped away: every other pixel, so it reads as a ghost of itself.
    static func ghost(_ icon: PixelBuffer) -> PixelBuffer {
        var out = PixelBuffer(width: icon.width, height: icon.height)
        for y in 0..<icon.height {
            for x in 0..<icon.width where (x + y) % 2 == 0 { out[x, y] = icon[x, y] }
        }
        return out
    }

    /// The selected-icon backdrop: a `Role.selection` square behind the icon inside a dark rounded frame, so it
    /// reads on the light day sky and the dark night one alike.
    static func drawSelectionBackdrop(_ c: inout PixelCanvas, _ icon: ArtRect) {
        let r = icon.insetBy(-2, -2)
        c.roundedRectFill(r, radius: 3, .blue0)
        c.roundedRectFill(r.insetBy(1, 1), radius: 2, Role.selection)
    }

    /// Corner brackets round the cell a carry would land in.
    static func drawDropTarget(_ c: inout PixelCanvas, _ cell: ArtRect) {
        let r = cell.insetBy(0, 0)
        let n = 5
        for (ink, d) in [(Ink.neutral0, 1), (Ink.neutral9, 0)] {
            let x0 = r.minX + d, y0 = r.minY + d, x1 = r.maxX - 1 + d, y1 = r.maxY - 1 + d
            c.hline(x: x0, y: y0, length: n, ink); c.vline(x: x0, y: y0, length: n, ink)
            c.hline(x: x1 - n + 1, y: y0, length: n, ink); c.vline(x: x1, y: y0, length: n, ink)
            c.hline(x: x0, y: y1, length: n, ink); c.vline(x: x0, y: y1 - n + 1, length: n, ink)
            c.hline(x: x1 - n + 1, y: y1, length: n, ink); c.vline(x: x1, y: y1 - n + 1, length: n, ink)
        }
    }

    /// The marquee: a two-ink dotted rectangle (no fill, binary alpha).
    static func drawMarquee(_ c: inout PixelCanvas, _ r: ArtRect) {
        guard !r.isEmpty else { return }
        func dot(_ x: Int, _ y: Int) { c.plot(x, y, (x + y) % 4 < 2 ? .neutral9 : .blue0) }
        for x in r.minX..<r.maxX {
            dot(x, r.minY)
            dot(x, r.maxY - 1)
        }
        for y in r.minY..<r.maxY {
            dot(r.minX, y)
            dot(r.maxX - 1, y)
        }
    }

    // MARK: Tooltip text

    /// "PDF document · Oct 12, 2026" (kind, then the date added or modified).
    static func detail(_ meta: TokenMeta, calendar: Calendar = .current) -> String {
        var parts = [meta.isAlias ? "Alias" : kindName(meta.kind, package: meta.isPackage)]
        if meta.isDataless { parts.append("in iCloud") }
        if let date = meta.added ?? meta.modified { parts.append(dateText(date, calendar: calendar)) }
        return parts.joined(separator: " · ")
    }

    /// The kind as people say it ("PDF document", "Folder"), for tooltips and the Inventory.
    public static func kindName(_ kind: FileKind, package: Bool) -> String {
        switch kind {
        case .folder: package ? "Package" : "Folder"
        case .doc: "Document"
        case .text: "Plain text"
        case .pdf: "PDF document"
        case .image: "Image"
        case .video: "Movie"
        case .audio: "Audio"
        case .zip: "Archive"
        case .app: "Application"
        case .code: "Source code"
        case .dmg: "Disk image"
        case .screenshot: "Screenshot"
        case .unknown: package ? "Package" : "Document"
        }
    }

    static func dateText(_ date: Date, calendar: Calendar) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(months[((c.month ?? 1) - 1 + 12) % 12]) \(c.day ?? 1), \(c.year ?? 2026)"
    }
}

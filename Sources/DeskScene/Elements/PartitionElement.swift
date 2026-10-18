import DeskCore
import DeskPixels
import Foundation
import SpriteKit

/// The desk partition (데스크 파티션, Erratum 31): the felt panel on the desk's back edge and its tower, the sticky
/// notes on it, and its add-ons. The room draws the panel, the cube, the pad, the D-Day card and the clip light
/// (`RoomPlan`'s `partition.*` placements); this element draws the notes (one sprite each, `NoteSprite`, back to front
/// above the panel) and today's first line on the pad, and answers for all of it. The memo clips are their own
/// element in front of this one in the same slot (`MemoClipsElement`).
///
/// - **Hits**, front to back: the topmost note (by its pixels), the clip light, the D-Day card, the pad, the cube, then
///   the bare felt and frame (part `partition.felt`). An add-on answers only while it is out, the D-Day card only
///   while a D-Day is set.
/// - **Notes:** a click opens the note in the Memos window (there is no note selection); a drag moves it (`NoteDrag`),
///   bringing it to the front, or drops it in the wastebasket. Notes take clicks in the dark, but an unlit note's
///   tooltip and VoiceOver label say only "Sticky Note"; lit, the tooltip shows its text in up to five lines and its
///   date. Unlit, the pad and the D-Day card keep their text to themselves too.
/// - **The cube:** a click makes a note and opens it; a drag peels a new one off (`CubePeel`).
/// - **The pad:** a click opens today's memo; a drag tears today's page off as a cream note (`PageTear`).
/// - **The D-Day card** opens the D-Day editor; **the clip light** switches on and off.
/// - **The felt** has no ring and no tooltip; its menu is the partition's, and files dropped on it go to the memo
///   clips (a bonk when they are full).
final class PartitionElement: DeskElement {
    let id = "partition"
    let root = SKNode()
    unowned let context: SceneContext
    /// The room's placed partition (the panel and the add-ons' sprites).
    let placed: () -> PlacedElement?
    private(set) var state: DeskState?
    private var noteNodes: [NoteID: SKSpriteNode] = [:]
    private var drawn: [NoteID: DrawnNote] = [:]
    private let padNode = SKSpriteNode()
    private var padShown: String?
    /// Notes in hand (a `NoteDrag` carries them): not drawn on the felt.
    private(set) var lifted: Set<NoteID> = [] {
        didSet { if lifted != oldValue { render() } }
    }
    /// Today's page is in hand (a `PageTear`): the pad shows no line.
    private(set) var tearing = false {
        didSet { if tearing != oldValue { render() } }
    }
    /// A new note popping in (`.notePop`): it shows 1 px bigger for two of three 12 fps frames.
    private(set) var pop: (id: NoteID, animation: DecorAnimation)?

    static let feltPart = "partition.felt"
    static let notePrefix = "partition.note."
    static let cubePart = "partition.cube"
    static let padPart = "partition.pad"
    static let dDayPart = "partition.dday"
    static let clipLightPart = "partition.clipLight"

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
        padNode.isHidden = true
        root.addChild(padNode)
    }

    // MARK: Geometry

    var partitionRect: ArtRect { context.layout.rect(CoreLayout.partition) }
    var cubeRect: ArtRect { context.layout.rect(CoreLayout.partitionCube) }
    var padRect: ArtRect { context.layout.rect(CoreLayout.partitionPad) }
    var dDayRect: ArtRect { context.layout.rect(CoreLayout.partitionDDay) }
    var clipLightRect: ArtRect { context.layout.rect(CoreLayout.partitionClipLight) }

    /// The day the pad shows (the room's, so a clock preview past midnight turns it too).
    var padDay: DayKey { DayKey(context.shownTime) }

    /// The canvas rect a note rests in.
    func noteRect(of note: StickyNote) -> ArtRect {
        context.layout.rect(PartitionLayout.noteRect(at: note.pos))
    }

    /// Note `id`'s canvas rect while the partition shows it.
    func noteRect(_ id: NoteID) -> ArtRect? {
        guard let s = state, s.isOut(.partition), let n = s.memos.notes[id] else { return nil }
        return noteRect(of: n)
    }

    /// The notes on the felt, back to front (none while the partition is put away).
    var shownNotes: [StickyNote] {
        guard let s = state, s.isOut(.partition) else { return [] }
        return s.memos.backToFront.filter { !lifted.contains($0.id) }
    }

    /// The note a part names ("partition.note.N3").
    static func noteID(_ part: String?) -> NoteID? {
        guard let part, part.hasPrefix(notePrefix) else { return nil }
        return NoteID(raw: String(part.dropFirst(notePrefix.count)))
    }

    /// The add-on parts that answer now, front to back, with their rects.
    func modules(_ s: DeskState) -> [(part: String, rect: ArtRect)] {
        var out: [(String, ArtRect)] = []
        if s.isOut(.clipLight) { out.append((Self.clipLightPart, clipLightRect)) }
        if s.isOut(.dDayCard), s.memos.dDay != nil { out.append((Self.dDayPart, dDayRect)) }
        if s.isOut(.dailyPad) { out.append((Self.padPart, padRect)) }
        out.append((Self.cubePart, cubeRect))
        return out
    }

    // MARK: DeskElement

    func layout(_ layout: SceneLayout) {
        drawn.removeAll()
        padShown = nil
        render()
    }

    func apply(_ s: DeskState) {
        state = s
        if let p = pop, s.memos.notes[p.id] == nil { pop = nil }
        render()
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        guard let s = state else {
            // The bare room: the placed sprites answer, as decor does.
            return placed()?.hitTest(p).map { Hit(element: id, part: $0.part, rect: $0.rect) }
        }
        guard s.isOut(.partition) else { return nil }
        let font = context.font
        for n in shownNotes.reversed() {
            let r = noteRect(of: n)
            guard r.contains(p), NoteSprite.image(n, font: font).pixel(p.x - r.x, p.y - r.y).a != 0 else { continue }
            return Hit(element: id, part: Self.notePrefix + n.id.raw, rect: r)
        }
        if let m = modules(s).first(where: { $0.rect.contains(p) }) {
            return Hit(element: id, part: m.part, rect: m.rect)
        }
        guard let panel = placed()?.placements.first(where: { $0.id == "partition.panel" }), panel.rect.contains(p),
              panel.sprite.hits(ArtPoint(p.x - panel.origin.x, p.y - panel.origin.y), frame: panel.frame)
        else { return nil }
        return Hit(element: id, part: Self.feltPart, rect: partitionRect)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        guard state != nil, let part = hit.part, part != Self.feltPart else { return .none }
        if let note = Self.noteID(part), let n = state?.memos.notes[note] {
            let r = noteRect(of: n)
            return ContainerElement.outline(NoteSprite.image(n, font: context.font), at: r.origin)
        }
        if let p = placed()?.placements.first(where: { $0.id == part }), !p.image.opaqueBounds().isEmpty {
            return ContainerElement.outline(p.image, at: p.origin)
        }
        return ContainerElement.ring(around: hit.rect)
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        guard let s = state, let part = hit.part else { return nil }
        let lit = context.isLit(hit.rect)
        if let note = Self.noteID(part), let n = s.memos.notes[note] {
            return Self.noteTooltip(n, today: padDay, lit: lit, font: context.font, anchor: hit.rect)
        }
        var spec: TooltipSpec
        switch part {
        case Self.cubePart:
            spec = TooltipSpec(title: L10n.text(.stickyCube), detail: L10n.text(.stickyCubeHelp), anchor: hit.rect)
        case Self.padPart:
            // Lit, the first line of the day's page; else (or with none) what a click does.
            let first = lit ? NoteSprite.textLines(s.memos.pages[padDay] ?? "").first : nil
            spec = TooltipSpec(title: L10n.text(.stowDailyPad), detail: first ?? L10n.text(.padHelp), anchor: hit.rect)
        case Self.dDayPart:
            guard let d = s.memos.dDay else { return nil }
            let named = lit && !d.title.isEmpty
            let title = named ? L10n.format(.dDayNamed, [d.title]) : L10n.text(.stowDDayCard)
            let days = padDay.days(until: d.day)
            spec = TooltipSpec(title: title, detail: "\(Self.daysText(days)) · \(Self.dateText(d.day, "MMMd"))",
                               anchor: hit.rect)
        case Self.clipLightPart:
            spec = TooltipSpec(title: L10n.text(.stowClipLight),
                               detail: L10n.text(s.clipLightOn ? .clipLightHelpOff : .clipLightHelpOn), anchor: hit.rect)
        default:
            return nil
        }
        spec.prefersAbove = true
        return spec
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard let s = state, let part = hit.part, part != Self.feltPart else { return .pass }
        if let note = Self.noteID(part) { return handleNote(gesture, note, s) }
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case .scroll:
            return .pass
        case let .click(_, _, count):
            if count == 1 { click(part, s) }
            return .handled
        case let .dragBegan(_, at, _):
            switch part {
            case Self.cubePart: return .drag(peel(s, at: at))
            case Self.padPart: return tear(s, at: at).map { GestureResponse.drag($0) } ?? .pass
            default: return .pass
            }
        }
    }

    /// A click on an add-on or the cube.
    private func click(_ part: String, _ s: DeskState) {
        switch part {
        case Self.cubePart: newNote(s)
        case Self.padPart: context.request(.command(.openMemos(.today)))
        case Self.dDayPart: context.request(.command(.openMemos(.dDay)))
        case Self.clipLightPart: context.dispatch(.clipLight(!s.clipLightOn))
        default: break
        }
    }

    /// A click on a note opens it in the Memos window; a drag picks it up.
    private func handleNote(_ gesture: Gesture, _ note: NoteID, _ s: DeskState) -> GestureResponse {
        switch gesture {
        case let .click(_, _, count):
            if count == 1 { context.request(.command(.editNote(note))) }
            return .handled
        case let .dragBegan(from, at, _):
            guard let n = s.memos.notes[note] else { return .pass }
            let r = noteRect(of: n)
            lifted.insert(note)
            let held = ArtPoint(Int(from.x.rounded(.down)) - r.x, Int(from.y.rounded(.down)) - r.y)
            let drag = NoteDrag(kind: .move(note), colour: n.colour, image: NoteSprite.image(n, font: context.font),
                                home: r.origin, grab: held, pointer: at, context: context) { [weak self] in
                self?.lifted.remove(note)
            }
            return .drag(drag)
        case .press, .cancelPress:
            return .handled
        case .scroll:
            return .pass
        }
    }

    /// The cube's click: a new yellow note at the first free spot, opened in the Memos window (not when the
    /// partition is full: the reducer refuses it and the toast says so).
    private func newNote(_ s: DeskState) {
        let note = s.memos.nextNoteID
        let full = s.memos.notes.count >= MemoBook.maxNotes
        context.dispatch(.addNote(NewNote(id: note, text: "", colour: .yellow), session: nil))
        if !full { context.request(.command(.editNote(note))) }
    }

    /// A new yellow note peeled off the cube.
    private func peel(_ s: DeskState, at p: SIMD2<Float>) -> CubePeel {
        let look = NoteSprite.Look(line: "", scribbles: 0, colour: .yellow, dated: false,
                                   pinned: s.memos.nextNoteID.number % 2 == 1)
        return CubePeel(image: NoteSprite.image(look, font: context.font), cube: cubeRect, pointer: p, context: context) {}
    }

    /// Today's page torn off the pad, while it has one.
    private func tear(_ s: DeskState, at p: SIMD2<Float>) -> PageTear? {
        let day = context.today
        guard let text = s.memos.pages[day], !text.isEmpty else { return nil }
        let lines = NoteSprite.textLines(text)
        let look = NoteSprite.Look(line: NoteSprite.clipped(lines.first ?? "", width: NoteSprite.band.w, font: context.font),
                                   scribbles: min(NoteSprite.scribbleRows.count, max(0, lines.count - 1)),
                                   colour: .cream, dated: true, pinned: s.memos.nextNoteID.number % 2 == 1)
        tearing = true
        return PageTear(day: day, image: NoteSprite.image(look, font: context.font), pad: padRect, pointer: p,
                        context: context) { [weak self] in self?.tearing = false }
    }

    /// Files dropped anywhere on the partition go to the memo clips while they are out and have room (else a bonk).
    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        guard let s = state, s.isOut(.memoClips), hitTest(p) != nil else { return nil }
        let members = s.tokens.members(of: .memoClips)
        let movers = Set(tokens)
        let staying = members.filter { !movers.contains($0) }.count
        return staying + movers.count <= ContainerID.memoClips.spec.hardCap
            ? .accept(.container(.memoClips, order: members.count)) : .bonk(.memoClipsFull)
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard let s = state, let part = hit.part else { return nil }
        if let note = Self.noteID(part) { return MenuSpec.note(note, s) }
        switch part {
        case Self.cubePart: return MenuSpec.cube(s)
        case Self.padPart: return MenuSpec.dailyPad(s, context.menuContextNow)
        case Self.dDayPart: return MenuSpec.dDayCard(s)
        case Self.clipLightPart: return MenuSpec.clipLight(s)
        default: return MenuSpec.partition(s, context.menuContextNow)
        }
    }

    /// The notes (front first), the cube, the pad, the D-Day card and the clip light, then the partition itself. An
    /// unlit note is only "Sticky Note"; an unlit D-Day card keeps its title.
    func accessibilityItems() -> [AXItem] {
        guard let s = state, s.isOut(.partition) else { return [] }
        var items: [AXItem] = []
        for n in shownNotes.reversed() {
            let r = noteRect(of: n)
            items.append(AXItem(id: "note.\(n.id.raw)", label: Self.noteLabel(n, lit: context.isLit(r)), role: .button,
                                frame: r))
        }
        items.append(AXItem(id: Self.cubePart, label: L10n.text(.newNote), role: .button, frame: cubeRect))
        if s.isOut(.dailyPad) {
            var day = Self.dateText(padDay, "EEEEMMMMd")
            if !(s.memos.pages[padDay] ?? "").isEmpty { day += ", " + L10n.text(.axHasMemo) }
            items.append(AXItem(id: Self.padPart, label: L10n.format(.axDailyPad, [day]), role: .button, frame: padRect))
        }
        if s.isOut(.dDayCard), let d = s.memos.dDay {
            let days = Self.daysText(padDay.days(until: d.day))
            let shown = context.isLit(dDayRect) && !d.title.isEmpty ? "\(d.title), \(days)" : days
            items.append(AXItem(id: Self.dDayPart, label: L10n.format(.dDayNamed, [shown]), role: .button,
                                frame: dDayRect))
        }
        if s.isOut(.clipLight) {
            items.append(AXItem(id: Self.clipLightPart, label: L10n.format(.axClipLight, [s.clipLightOn ? "On" : "Off"]),
                                role: .button, frame: clipLightRect))
        }
        items.append(AXItem(id: id, label: L10n.text(.axPartition), role: .group, frame: partitionRect))
        return items
    }

    // MARK: Frames

    var needsFrames: Bool { pop != nil }

    func step(_ dt: Double) {
        guard var p = pop else { return }
        p.animation.advance(dt)
        pop = p.animation.isFinished ? nil : p
        render()
    }

    func settle() {
        guard pop != nil else { return }
        pop = nil
        render()
    }

    /// A new note pops in (`.notePop`): none with Reduce Motion.
    func playPop(_ note: NoteID) {
        guard !context.reduceMotion, state?.memos.notes[note] != nil else { return }
        pop = (note, DecorAnimation(count: 3))
        render()
    }

    // MARK: Drawing

    /// Places a sprite per note (back to front, just above the panel) and the pad's line; true when anything moved.
    @discardableResult
    func render() -> Bool {
        guard let s = state, s.isOut(.partition) else {
            for node in noteNodes.values { node.isHidden = true }
            padNode.isHidden = true
            return false
        }
        var changed = false
        let font = context.font
        let base = context.placementZ("partition.panel")
        let notes = s.memos.backToFront
        var seen = Set<NoteID>()
        for (rank, n) in notes.enumerated() {
            seen.insert(n.id)
            let node = noteNodes[n.id] ?? makeNode(n.id)
            if lifted.contains(n.id) {
                node.isHidden = true
                continue
            }
            let grown = pop.map { $0.id == n.id && $0.animation.index < 2 } ?? false
            let rect = grown ? noteRect(of: n).insetBy(-1, -1) : noteRect(of: n)
            let look = DrawnNote(look: NoteSprite.look(n, font: font), rect: rect, grown: grown)
            if drawn[n.id] != look {
                let image = NoteSprite.image(look.look, font: font)
                node.texture = TextureFactory.texture(grown ? NoteSprite.grown(image) : image)
                context.space.place(node, at: rect)
                drawn[n.id] = look
                changed = true
            }
            node.zPosition = base + 0.2 + CGFloat(rank) * 0.02
            node.isHidden = false
        }
        for (note, node) in noteNodes where !seen.contains(note) {
            node.removeFromParent()
            noteNodes[note] = nil
            drawn[note] = nil
            changed = true
        }
        renderPad(s, font: font)
        return changed
    }

    private func makeNode(_ note: NoteID) -> SKSpriteNode {
        let node = SKSpriteNode()
        node.name = Self.notePrefix + note.raw
        node.isHidden = true
        root.addChild(node)
        noteNodes[note] = node
        return node
    }

    /// Today's first line on the pad, while the pad is out and the page is not in hand.
    private func renderPad(_ s: DeskState, font: PixelFont?) {
        let text = s.isOut(.dailyPad) && !tearing ? s.memos.pages[padDay] ?? "" : ""
        guard let image = NoteSprite.padLine(text, font: font) else {
            padNode.isHidden = true
            padShown = nil
            return
        }
        let key = "\(text)|\(padRect)"
        if padShown != key {
            padShown = key
            padNode.texture = TextureFactory.texture(image)
            let band = NoteSprite.padBand
            context.space.place(padNode, at: ArtRect(padRect.x + band.x, padRect.y + band.y, image.width, image.height))
        }
        padNode.zPosition = context.placementZ("partition.pad") + 0.5
        padNode.isHidden = false
    }

    /// Note `id`'s image as drawn now (tests, goldens).
    func noteImage(_ note: NoteID) -> PixelBuffer? {
        state?.memos.notes[note].map { NoteSprite.image($0, font: context.font) }
    }

    /// `art` (canvas-sized, unlit) with the notes and the pad's line drawn over it as the scene draws them: the CPU
    /// twin of this element (goldens).
    func compose(over art: PixelBuffer) -> PixelBuffer {
        var out = art
        for n in shownNotes { out.blit(NoteSprite.image(n, font: context.font), at: noteRect(of: n).origin) }
        if let s = state, s.isOut(.dailyPad), !tearing,
           let line = NoteSprite.padLine(s.memos.pages[padDay] ?? "", font: context.font) {
            out.blit(line, at: ArtPoint(padRect.x + NoteSprite.padBand.x, padRect.y + NoteSprite.padBand.y))
        }
        return out
    }

    // MARK: Words

    /// A note's tooltip: lit, its first wrapped line as the title, the next four below it (the last ending "…" when
    /// more remain) and its date ("Oct 18 · D-3"); unlit, only "Sticky Note".
    static func noteTooltip(_ n: StickyNote, today: DayKey, lit: Bool, font: PixelFont?, anchor: ArtRect) -> TooltipSpec {
        var spec = TooltipSpec(title: L10n.text(.stickyNote), anchor: anchor)
        spec.prefersAbove = true
        guard lit else { return spec }
        let lines = wrapped(n.text, font: font)
        if let first = lines.first { spec.title = first }
        var body = Array(lines.dropFirst().prefix(4))
        if lines.count > 5, let last = body.last { body[body.count - 1] = ellipsized(last, font: font) }
        spec.body = body
        if let day = n.day {
            spec.detail = "\(dateText(day, "MMMd")) · \(PartitionArt.ddayText(days: today.days(until: day)))"
        }
        return spec
    }

    /// VoiceOver's name for a note: "Sticky note: ‹first line›" when lit, else "Sticky Note".
    static func noteLabel(_ n: StickyNote, lit: Bool) -> String {
        guard lit, let first = NoteSprite.textLines(n.text).first else { return L10n.text(.stickyNote) }
        return L10n.format(.axStickyNote, [first])
    }

    /// `text`'s lines wrapped to the tooltip's width (empty lines dropped).
    static func wrapped(_ text: String, font: PixelFont?) -> [String] {
        let advance: (Character) -> Int = { font?.advance(of: $0) ?? 6 }
        return NoteSprite.textLines(text).flatMap {
            TextLayout.wrap($0, maxWidth: TooltipArt.maxTextWidth, maxLines: 6, advance: advance)
        }
    }

    /// `line` ending "…", shortened to fit the tooltip's width.
    static func ellipsized(_ line: String, font: PixelFont?) -> String {
        let advance: (Character) -> Int = { font?.advance(of: $0) ?? 6 }
        var chars = Array(line)
        while !chars.isEmpty, TextLayout.width(chars + ["…"], advance: advance) > TooltipArt.maxTextWidth {
            chars.removeLast()
        }
        return String(chars) + "…"
    }

    /// "12 days left", "Today", "3 days ago".
    static func daysText(_ days: Int) -> String {
        if days > 0 { return L10n.format(.daysLeft, [days]) }
        if days == 0 { return L10n.text(.dDayToday) }
        return L10n.format(.daysAgo, [-days])
    }

    /// `day` written with a date template ("MMMd" → "Oct 18", "EEEEMMMMd" → "Sunday, October 18") in the language
    /// the app speaks.
    static func dateText(_ day: DayKey, _ template: String) -> String {
        let f = formatter(template)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = f.timeZone
        guard let date = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else {
            return day.description
        }
        return f.string(from: date)
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let locale = L10n.language.dateLocale(current: .current)
        let key = "\(template)|\(locale.identifier)"
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.calendar = Calendar(identifier: .gregorian)
        f.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = f
        return f
    }

    private static var formatters: [String: DateFormatter] = [:]
}

/// What a note's sprite shows and where.
struct DrawnNote: Equatable {
    var look: NoteSprite.Look
    var rect: ArtRect
    var grown: Bool
}

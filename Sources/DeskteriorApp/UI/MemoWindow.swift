import AppKit
import DeskCore
import DeskScene
import Observation
import SwiftUI

/// Memos (메모, Erratum 31): where sticky notes, day pages and the D-Day are written, since the desk view never takes
/// text keys (Korean input methods, ⌘C/⌘V and ⌘Z inside the text work as in any Mac text view). Two tabs: Calendar (a
/// month grid, the day's page, the notes dated that day, the D-Day) and Sticky Notes (every note, front first, and an
/// editor). It opens beside what was clicked on the desk (a note, the pad, a calendar day), else centred, and follows
/// the store while it is open, like the Inventory.
///
/// Text reaches the model only through `MemoEditor` (debounced, never mid-composition, flushed on blur, tab switch,
/// close, resign-key and quit), and model text never replaces what is being typed. Buttons that change files (Save as
/// Text File on Desktop) run their menu command through `perform`, which the app delegate injects (a menu pick's
/// gesture); this window names no gesture and builds no file request itself.
final class MemoWindowController: NSObject, NSWindowDelegate {
    let model: MemoWindowModel
    private(set) var window: NSWindow?
    private var observer: Int?
    private unowned let store: Store
    private let today: () -> DayKey
    private var sessions = 0
    /// False in tests: the window is built and laid out but never put on screen (nor the app activated).
    var presents = true

    static let contentSize = NSSize(width: 560, height: 420)

    init(store: Store, today: @escaping () -> DayKey, perform: @escaping (MenuCommand) -> Void) {
        self.store = store
        self.today = today
        model = MemoWindowModel(state: store.state, today: today())
        super.init()
        model.perform = perform
        model.dispatch = { [weak self] in self?.store.dispatch($0) }
        model.nextSession = { [weak self] in self?.nextSession() ?? 0 }
        model.todayNow = today
    }

    /// Opens the window on `target`, beside `near` (a screen rect: the note, the pad or the calendar day clicked) when
    /// it is not already open clear of it. `session` continues an editing session begun elsewhere (New Sticky Note's,
    /// so the note and its first words are one undo entry).
    func show(_ target: MemoTarget, near: NSRect?, session: Int?) {
        let wasShown = window?.isVisible == true
        if window == nil { makeWindow() }
        if observer == nil {
            observer = store.observe { [weak self] new, _ in self?.model.state = new }
        }
        model.state = store.state
        model.today = today()
        languageChanged()
        model.open(target, session: session)
        if !wasShown { model.reloadClean() }  // the memos may have changed while it was closed
        guard let window else { return }
        if let near, !wasShown || window.frame.intersects(near) { place(window, beside: near) }
        if presents { AppWindow.present(window) }
    }

    /// New Sticky Note from a menu: what the editors hold is committed first (so it stays its own undo entry, under
    /// the new note's), then a yellow note on the first free spot, and its editor in the same editing session, so the
    /// note and the first words typed into it are one undo entry. The window opens beside `near` of the new note.
    /// Nil, and nothing opens, when the partition is full (its toast says so).
    @discardableResult
    func newNoteFromMenu(near: (NoteID) -> NSRect?) -> NoteID? {
        model.flush()
        let id = store.state.memos.nextNoteID, editing = nextSession()
        store.dispatch(.addNote(NewNote(id: id, text: "", colour: .yellow), session: editing))
        guard store.state.memos.notes[id] != nil else { return nil }
        show(.note(id), near: near(id), session: editing)
        return id
    }

    /// A new editing session (each editor attach starts one).
    func nextSession() -> Int {
        sessions += 1
        return sessions
    }

    /// The window while it is on screen (development screenshots, `--show memos`).
    var shownWindow: NSWindow? { window?.isVisible == true ? window : nil }

    /// Shows the window's text in the current language (Settings ▸ Language changed).
    func languageChanged() {
        window?.title = tr(.memosTitle)
        model.language = L10n.language
    }

    /// Commits what the editors hold (quit, a folder switch).
    func flush() {
        model.flush()
    }

    /// The editors show what the model holds now (after an Undo or Redo picked from the status menu).
    func reloadClean() {
        model.reloadClean()
    }

    /// Closes the window for good (its store is going away: another folder is mirrored).
    func close() {
        window?.close()
        window = nil
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        model.flush()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.today = today()
    }

    func windowWillClose(_ notification: Notification) {
        model.flush()
        if let observer { store.removeObserver(observer) }
        observer = nil
    }

    // MARK: Private

    private func makeWindow() {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        let hosting = NSHostingController(rootView: MemoWindowView(model: model))
        hosting.sizingOptions = [.minSize]
        w.contentViewController = hosting
        w.setContentSize(Self.contentSize)
        w.center()
        w.delegate = self
        window = w
    }

    /// Moves the window beside `target` (right, left, below, above), inside the visible frame of the screen it is on;
    /// centred when it fits nowhere beside it.
    private func place(_ window: NSWindow, beside target: NSRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(target) }) ?? window.screen ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame, size = window.frame.size, gap: CGFloat = 16
        let candidates = [
            NSPoint(x: target.maxX + gap, y: target.midY - size.height / 2),
            NSPoint(x: target.minX - gap - size.width, y: target.midY - size.height / 2),
            NSPoint(x: target.midX - size.width / 2, y: target.minY - gap - size.height),
            NSPoint(x: target.midX - size.width / 2, y: target.maxY + gap),
        ]
        for origin in candidates {
            var frame = NSRect(origin: origin, size: size)
            frame.origin.x = min(max(frame.minX, area.minX), area.maxX - size.width)
            frame.origin.y = min(max(frame.minY, area.minY), area.maxY - size.height)
            if !frame.intersects(target) {
                window.setFrameOrigin(frame.origin)
                return
            }
        }
        window.center()
    }
}

/// The Memos window's state: the model, the tab, the month shown, the day and note being edited, and the D-Day
/// editor. Its two `MemoEditor`s carry the text; everything else goes out as actions or menu commands.
@Observable
final class MemoWindowModel {
    enum Tab: Hashable { case calendar, notes }

    var state: DeskState
    /// The language the window speaks (the views re-render when it changes).
    var language = L10n.language
    private(set) var tab = Tab.calendar
    /// The first day of the month the grid shows.
    private(set) var month: DayKey
    /// The day the Calendar tab edits.
    private(set) var day: DayKey
    /// The note the Sticky Notes tab edits (it may have been taken off since).
    private(set) var note: NoteID?
    /// Today on the room's clock (ringed red in the grid; the D-Day counts from it).
    var today: DayKey
    /// The D-Day title field is open.
    var editingDDay = false
    var dDayDraft = ""
    let dayEditor = MemoEditor()
    let noteEditor = MemoEditor()
    @ObservationIgnored var dispatch: (DeskAction) -> Void = { _ in }
    /// Runs a menu command as the app delegate does (the file-changing buttons go only through here).
    @ObservationIgnored var perform: (MenuCommand) -> Void = { _ in }
    @ObservationIgnored var nextSession: () -> Int = { 0 }
    @ObservationIgnored var todayNow: (() -> DayKey)?

    init(state: DeskState, today: DayKey) {
        self.state = state
        self.today = today
        day = today
        month = Self.firstOfMonth(today)
        dayEditor.commit = { [weak self] target, text, session in
            guard case let .day(d) = target else { return }
            self?.dispatch(.editDayPage(d, text: text, session: session))
        }
        noteEditor.commit = { [weak self] target, text, session in
            guard case let .note(id) = target else { return }
            self?.dispatch(.editNote(id, text: text, session: session))
        }
    }

    // MARK: Opening

    /// Shows `target`: today's or a day's page, a note, the list, or the D-Day editor.
    func open(_ target: MemoTarget, session: Int? = nil) {
        switch target {
        case .today:
            switchTab(.calendar)
            select(day: today, session: session)
            dayEditor.focus()
        case let .day(d):
            switchTab(.calendar)
            select(day: d, session: session)
            dayEditor.focus()
        case let .note(id):
            switchTab(.notes)
            select(note: id, session: session)
            noteEditor.focus()
        case .notes:
            switchTab(.notes)
            if selectedNote == nil { select(note: frontNotes.first?.id, session: session) }
        case .dDay:
            switchTab(.calendar)
            select(day: book.dDay?.day ?? today, session: session)
            beginDDay()
        }
    }

    /// A tab switch commits what the editors hold first. A window first opened on a note has no day page yet: the
    /// Calendar tab then edits today's.
    func switchTab(_ new: Tab) {
        guard new != tab else { return }
        flush()
        tab = new
        if new == .calendar, dayEditor.target == nil {
            if let todayNow { today = todayNow() }
            select(day: today)
        }
    }

    /// Edits `d`'s page (and shows its month); choosing the day being edited again changes nothing.
    func select(day d: DayKey, session: Int? = nil) {
        month = Self.firstOfMonth(d)
        guard d != day || dayEditor.target != .day(d) || session != nil else { return }
        day = d
        editingDDay = false
        dayEditor.attach(.day(d), session: session ?? nextSession())
    }

    /// Edits note `id` (nil: none).
    func select(note id: NoteID?, session: Int? = nil) {
        let target = id.map { MemoEditor.Target.note($0) }
        guard id != note || noteEditor.target != target || session != nil else { return }
        note = id
        noteEditor.attach(target, session: session ?? nextSession())
    }

    /// Commits both editors now (tab switch, resign-key, close, quit); then they show the model's text.
    func flush() {
        dayEditor.flush()
        noteEditor.flush()
        reloadClean()
    }

    /// An editor with nothing to commit whose text view shows other text than the model's shows the model's again: a
    /// focused editor never takes model text by itself (`NoteTextView`), so an Undo from the status menu, or a change
    /// made while the window was closed, would otherwise stay unseen and be committed back by the next keystroke.
    func reloadClean() {
        if dayEditor.target == .day(day), !dayEditor.isDirty, let tv = dayEditor.textView, tv.string != pageText {
            dayEditor.reload()
        }
        if let note, noteEditor.target == .note(note), !noteEditor.isDirty, let tv = noteEditor.textView,
           tv.string != (selectedNote?.text ?? "") {
            noteEditor.reload()
        }
    }

    // MARK: Calendar

    func showMonth(_ delta: Int) {
        month = Self.month(month, adding: delta)
    }

    func goToday() {
        if let todayNow { today = todayNow() }
        select(day: today)
    }

    /// A note listed under the day: edited in the Sticky Notes tab.
    func openNote(_ id: NoteID) {
        switchTab(.notes)
        select(note: id)
        noteEditor.focus()
    }

    /// Tear Off as Sticky Note: the page becomes a cream note dated that day (the scene finds it a spot) and the
    /// editor shows the blank page.
    func tearOff() {
        dayEditor.flush()
        perform(.tearOffPage(day))
        dayEditor.attach(.day(day), session: nextSession())
    }

    func saveDay() {
        dayEditor.flush()
        perform(.saveMemoFile(.day(day)))
    }

    func beginDDay() {
        dDayDraft = book.dDay.map { $0.day == day ? $0.title : "" } ?? ""
        editingDDay = true
    }

    /// Set as D-Day: the day being edited, with the title typed (at most 24 graphemes).
    func setDDay() {
        dispatch(.setDDay(DDay(day: day, title: MemoBook.clean(dDayDraft, limit: MemoBook.maxTitle))))
        editingDDay = false
    }

    func clearDDay() {
        perform(.clearDDay)
        editingDDay = false
    }

    // MARK: Sticky notes

    /// New Sticky Note (dated `day` from the Calendar tab), then its editor in the same session: the note and what is
    /// typed into it are one undo entry. Nothing opens when the partition is full (its toast says so).
    func newNote(day d: DayKey? = nil) {
        flush()
        let id = book.nextNoteID, session = nextSession()
        dispatch(.addNote(NewNote(id: id, text: "", colour: .yellow, day: d), session: session))
        guard book.notes[id] != nil else { return }
        switchTab(.notes)
        select(note: id, session: session)
        noteEditor.focus()
    }

    func setColour(_ c: NoteColour) {
        if let note { perform(.noteColour(note, c)) }
    }

    /// The Date toggle: dated today when turned on.
    func setDated(_ on: Bool) {
        guard let note else { return }
        dispatch(.noteDay(note, on ? (selectedNote?.day ?? today) : nil))
    }

    func setNoteDay(_ date: Date) {
        guard let note else { return }
        dispatch(.noteDay(note, DayKey(date: date)))
    }

    func raise() {
        if let note { perform(.raiseNote(note)) }
    }

    func saveNote() {
        noteEditor.flush()
        if let note { perform(.saveMemoFile(.note(note))) }
    }

    func removeNote() {
        noteEditor.flush()
        if let note { perform(.removeNote(note)) }
    }

    func bringBackPartition() {
        perform(.bringBack(.partition))
    }

    // MARK: What the views show

    var book: MemoBook { state.memos }
    var pageText: String { book.pages[day] ?? "" }
    var selectedNote: StickyNote? { note.flatMap { book.notes[$0] } }
    var frontNotes: [StickyNote] { book.backToFront.reversed() }
    var notesForDay: [StickyNote] { book.notes(on: day).reversed() }
    var connected: Bool { state.access == .connected }
    var partitionOut: Bool { state.isOut(.partition) }
    var isFull: Bool { book.notes.count >= MemoBook.maxNotes }
    var canTearOff: Bool { dayEditor.count > 0 && partitionOut && !isFull }
    var canSaveDay: Bool { dayEditor.count > 0 && connected }
    var canSaveNote: Bool { noteEditor.count > 0 && connected }
    var marks: [Int: CalendarMark] { book.marks(year: month.year, month: month.month) }

    /// Whether `n` is already in front of every other note.
    func isFrontmost(_ n: StickyNote) -> Bool { frontNotes.first?.id == n.id }

    /// The 42 cells of the month grid, Sunday first (nil outside the month).
    var cells: [DayKey?] {
        let lead = month.weekday, days = month.wallTime.daysInMonth
        return (0..<42).map { i in
            let d = i - lead + 1
            return (1...days).contains(d) ? DayKey(year: month.year, month: month.month, day: d) : nil
        }
    }

    /// "S M T W T F S" / "일 월 화 수 목 금 토".
    var weekdaySymbols: [String] {
        var calendar = Self.calendar
        calendar.locale = L10n.locale
        return calendar.veryShortStandaloneWeekdaySymbols
    }

    /// "October 2026" / "2026년 10월".
    func monthTitle(_ first: DayKey) -> String {
        first.date.formatted(Self.style.month(.wide).year())
    }

    func adjacentMonth(_ delta: Int) -> DayKey { Self.month(month, adding: delta) }

    /// "Sunday, October 18, 2026" / "2026년 10월 18일 일요일".
    var dayHeading: String {
        day.date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: L10n.locale,
                                            calendar: Self.calendar))
    }

    /// "Oct 30" / "10월 30일".
    func shortDate(_ d: DayKey) -> String {
        d.date.formatted(Self.style.month(.abbreviated).day())
    }

    /// The D-Day line: "중간고사 · Oct 30 · D-12" (nil while none is set).
    var dDayLine: String? {
        guard let d = book.dDay else { return nil }
        let parts = [d.title, shortDate(d.day), PartitionArt.ddayText(days: today.days(until: d.day))]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A note's first line, or "Empty note".
    func noteTitle(_ n: StickyNote) -> String {
        Self.firstLine(n.text) ?? tr(.emptyNote)
    }

    /// What VoiceOver says for a day's cell: the date, then its memo, notes and the D-Day.
    func cellLabel(_ d: DayKey, _ m: CalendarMark) -> String {
        var parts = [d.date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: L10n.locale,
                                                       calendar: Self.calendar))]
        if m.contains(.memo) { parts.append(tr(.memoWord)) }
        let n = book.notes(on: d).count
        if n == 1 { parts.append(tr(.oneNote)) } else if n > 1 { parts.append(L10n.format(.notesCount, [n])) }
        if m.contains(.dDay), let dDay = book.dDay { parts.append(L10n.format(.dDayNamed, [dDay.title])) }
        return parts.joined(separator: ", ")
    }

    // MARK: Helpers

    static let calendar = Calendar(identifier: .gregorian)

    private static var style: Date.FormatStyle {
        Date.FormatStyle(locale: L10n.locale, calendar: calendar)
    }

    static func firstOfMonth(_ d: DayKey) -> DayKey {
        DayKey(year: d.year, month: d.month, day: 1) ?? d
    }

    /// The first of the month `n` months from `first`'s.
    static func month(_ first: DayKey, adding n: Int) -> DayKey {
        let index = first.year * 12 + first.month - 1 + n
        return DayKey(year: index / 12, month: index % 12 + 1, day: 1) ?? first
    }

    /// The first line that holds more than spaces, trimmed; nil when there is none.
    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

extension DayKey {
    /// Noon of the day in this Mac's time zone (formatting and the date picker).
    var date: Date {
        DateComponents(calendar: MemoWindowModel.calendar, timeZone: .current, year: year, month: month, day: day,
                       hour: 12).date ?? Date(timeIntervalSince1970: 0)
    }

    /// The day `date` falls on in this Mac's time zone (the room clock's reading of it).
    init(date: Date) {
        self.init(SceneClock.wallTime(date, calendar: MemoWindowModel.calendar))
    }
}

extension NoteColour {
    /// The paper's face and edge as the desk draws them (steps 5 and 4 of the colour's Apollo ramp).
    var face: Ink {
        switch self {
        case .yellow: .walnut5
        case .pink: .purple5
        case .sky: .blue5
        case .lime: .green5
        case .orange: .red5
        case .cream: .oak5
        }
    }

    var edge: Ink {
        switch self {
        case .yellow: .walnut4
        case .pink: .purple4
        case .sky: .blue4
        case .lime: .green4
        case .orange: .red4
        case .cream: .oak4
        }
    }
}

extension Ink {
    /// The ink as a SwiftUI colour (the window's marks match the wall calendar's, and the chips the notes').
    var swatch: Color { Color(cgColor: color.cgColor) }
}

// MARK: - Views

/// The two tabs under a segmented control (a plain hosted window gets no tab bar from `TabView`).
struct MemoWindowView: View {
    @Bindable var model: MemoWindowModel

    var body: some View {
        let _ = model.language
        VStack(spacing: 10) {
            Picker(tr(.memosTitle), selection: Binding(get: { model.tab }, set: { model.switchTab($0) })) {
                Text(tr(.tabCalendar)).tag(MemoWindowModel.Tab.calendar)
                Text(tr(.tabNotes)).tag(MemoWindowModel.Tab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch model.tab {
            case .calendar: MemoCalendarTab(model: model)
            case .notes: MemoNotesTab(model: model)
            }
        }
        .padding(12)
        .frame(width: MemoWindowController.contentSize.width, height: MemoWindowController.contentSize.height)
    }
}

/// The Calendar tab: the month grid and the day's notes on the left, the day's page and the D-Day on the right.
struct MemoCalendarTab: View {
    @Bindable var model: MemoWindowModel

    var body: some View {
        let _ = model.language
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                MemoMonthGrid(model: model)
                Divider()
                MemoDayNotes(model: model)
            }
            .frame(width: MemoMonthGrid.cell.width * 7)
            Divider()
            MemoDayPage(model: model)
        }
    }
}

/// The month: ‹ Today ›, the weekdays (Sunday red, Saturday blue) and the days. A dot marks a page, a square dated
/// notes, a purple ring the D-Day; today is filled red, the day being edited ringed blue (the wall calendar's inks).
struct MemoMonthGrid: View {
    @Bindable var model: MemoWindowModel
    static let cell = CGSize(width: 32, height: 28)

    var body: some View {
        let _ = model.language
        let cells = model.cells, marks = model.marks, symbols = model.weekdaySymbols
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Text(model.monthTitle(model.month)).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Button { model.showMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(model.monthTitle(model.adjacentMonth(-1)))
                Button(tr(.today)) { model.goToday() }
                Button { model.showMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel(model.monthTitle(model.adjacentMonth(1)))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols.indices.contains(i) ? symbols[i] : "")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Self.weekdayColour(i, plain: .secondary))
                        .frame(width: Self.cell.width)
                }
            }
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            let d = cells[row * 7 + col]
                            MemoDayCell(model: model, day: d, weekday: col, marks: d.flatMap { marks[$0.day] } ?? [])
                                .frame(width: Self.cell.width, height: Self.cell.height)
                        }
                    }
                }
            }
        }
    }

    static func weekdayColour(_ weekday: Int, plain: Color) -> Color {
        switch weekday {
        case 0: Ink.red4.swatch
        case 6: Ink.blue3.swatch
        default: plain
        }
    }
}

struct MemoDayCell: View {
    let model: MemoWindowModel
    let day: DayKey?
    let weekday: Int
    let marks: CalendarMark

    var body: some View {
        if let day {
            let isToday = day == model.today, isSelected = day == model.day
            Button { model.select(day: day) } label: {
                ZStack {
                    if isToday { Circle().fill(Ink.red4.swatch).frame(width: 22, height: 22) }
                    if marks.contains(.dDay) {
                        Circle().strokeBorder(Ink.purple3.swatch, lineWidth: 1.5).frame(width: 25, height: 25)
                    }
                    if isSelected { Circle().strokeBorder(Ink.blue3.swatch, lineWidth: 2).frame(width: 28, height: 28) }
                    Text(String(day.day))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(isToday ? Color.white : MemoMonthGrid.weekdayColour(weekday, plain: .primary))
                        .offset(y: -2)
                    HStack(spacing: 2) {
                        if marks.contains(.memo) { Circle().fill(Ink.blue3.swatch).frame(width: 4, height: 4) }
                        if marks.contains(.note) { Rectangle().fill(Ink.blue3.swatch).frame(width: 4, height: 4) }
                    }
                    .offset(y: 8)
                }
                .frame(width: MemoMonthGrid.cell.width, height: MemoMonthGrid.cell.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.cellLabel(day, marks))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Color.clear
        }
    }
}

/// Notes for This Day (each opens in the Sticky Notes tab) and New Note for This Day.
struct MemoDayNotes: View {
    @Bindable var model: MemoWindowModel

    var body: some View {
        let _ = model.language
        let notes = model.notesForDay
        VStack(alignment: .leading, spacing: 6) {
            Text(tr(.notesForDay)).font(.subheadline.weight(.semibold))
            if !notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes, id: \.id) { n in
                            Button { model.openNote(n.id) } label: {
                                HStack(spacing: 6) {
                                    MemoNoteChip(colour: n.colour)
                                    Text(model.noteTitle(n)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: min(CGFloat(notes.count) * 20, 60))
            }
            Button(tr(.newNoteForDay)) { model.newNote(day: model.day) }
                .controlSize(.small)
                .disabled(model.isFull)
            Spacer(minLength: 0)
        }
    }
}

/// The day's page (its own editor and counter), Tear Off and Save, and the D-Day.
struct MemoDayPage: View {
    @Bindable var model: MemoWindowModel

    var body: some View {
        let _ = model.language
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.dayHeading).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "\(model.dayEditor.count)/\(MemoBook.maxText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            NoteTextView(editor: model.dayEditor, text: model.pageText, placeholder: tr(.dayPlaceholder))
                .memoEditorFrame()
                .frame(height: 140)
            ViewThatFits(in: .horizontal) {
                HStack { tearOff; save }
                VStack(alignment: .leading) { tearOff; save }
            }
            .controlSize(.small)
            if !model.connected {
                Text(tr(.connectToSave)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Divider()
            MemoDDayRow(model: model)
        }
    }

    private var tearOff: some View {
        Button(tr(.tearOff)) { model.tearOff() }.disabled(!model.canTearOff)
    }

    private var save: some View {
        Button(tr(.saveTextFile)) { model.saveDay() }.disabled(!model.canSaveDay)
    }
}

/// The D-Day line ("중간고사 · Oct 30 · D-12") with Clear D-Day, and Set as D-Day… with its title field.
struct MemoDDayRow: View {
    @Bindable var model: MemoWindowModel

    var body: some View {
        let _ = model.language
        VStack(alignment: .leading, spacing: 6) {
            if let line = model.dDayLine {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill").foregroundStyle(Ink.red4.swatch)
                    Text(line).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button(tr(.clearDDay)) { model.clearDDay() }
                }
            }
            if model.editingDDay {
                HStack(spacing: 6) {
                    TextField(tr(.dDayTitle), text: $model.dDayDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.setDDay() }
                    Button(tr(.ok)) { model.setDDay() }
                    Button(tr(.cancel)) { model.editingDDay = false }
                }
            } else {
                Button(tr(.setAsDDay)) { model.beginDDay() }
            }
        }
        .controlSize(.small)
    }
}

/// The Sticky Notes tab: every note, front first, with New Sticky Note; the editor of the one chosen.
struct MemoNotesTab: View {
    @Bindable var model: MemoWindowModel

    var body: some View {
        let _ = model.language
        let notes = model.frontNotes
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                List(selection: Binding(get: { model.note }, set: { model.select(note: $0) })) {
                    ForEach(notes, id: \.id) { n in
                        HStack(spacing: 8) {
                            MemoNoteChip(colour: n.colour)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.noteTitle(n))
                                    .lineLimit(1)
                                    .foregroundStyle(MemoWindowModel.firstLine(n.text) == nil ? .secondary : .primary)
                                if let d = n.day {
                                    Text(model.shortDate(d)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tag(n.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .overlay {
                    if notes.isEmpty { Text(tr(.noNotes)).foregroundStyle(.secondary) }
                }
                Button(tr(.newNote)) { model.newNote() }
                    .disabled(model.isFull)
            }
            .frame(width: 196)
            Divider()
            MemoNoteEditor(model: model)
        }
    }
}

/// One note's editor: its text, colour, date, Bring to Front, Save and Remove; a banner while the partition is put
/// away; a line when the note was taken off.
struct MemoNoteEditor: View {
    @Bindable var model: MemoWindowModel

    var body: some View {
        let _ = model.language
        VStack(alignment: .leading, spacing: 8) {
            if !model.partitionOut {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox")
                    Text(tr(.partitionAway)).font(.callout)
                    Spacer(minLength: 4)
                    Button(tr(.bringBackMenu)) { model.bringBackPartition() }.controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            }
            if let n = model.selectedNote {
                editor(n)
            } else {
                Spacer()
                if model.note != nil {
                    Text(tr(.noteGone)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func editor(_ n: StickyNote) -> some View {
        HStack(spacing: 6) {
            ForEach(NoteColour.allCases, id: \.self) { c in
                Button { model.setColour(c) } label: {
                    Circle()
                        .fill(c.face.swatch)
                        .overlay(Circle().strokeBorder(c.edge.swatch))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay {
                            if n.colour == c { Circle().strokeBorder(Color.primary, lineWidth: 2) }
                        }
                }
                .buttonStyle(.plain)
                .help(L10n.tr(c.title))
                .accessibilityLabel(L10n.tr(c.title))
                .accessibilityAddTraits(n.colour == c ? .isSelected : [])
            }
            Spacer(minLength: 4)
            Text(verbatim: "\(model.noteEditor.count)/\(MemoBook.maxText)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        NoteTextView(editor: model.noteEditor, text: n.text)
            .memoEditorFrame()
            .frame(height: 150)
        HStack(spacing: 8) {
            Toggle(tr(.dateToggle), isOn: Binding(get: { n.day != nil }, set: { model.setDated($0) }))
            if let d = n.day {
                DatePicker(tr(.dateToggle), selection: Binding(get: { d.date }, set: { model.setNoteDay($0) }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .environment(\.locale, L10n.locale)
                    .environment(\.calendar, MemoWindowModel.calendar)
            }
            Spacer(minLength: 0)
        }
        ViewThatFits(in: .horizontal) {
            HStack { raise(n); save }
            VStack(alignment: .leading) { raise(n); save }
        }
        .controlSize(.small)
        if !model.connected {
            Text(tr(.connectToSave)).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        HStack {
            Spacer()
            Button(tr(.removeNote), role: .destructive) { model.removeNote() }.controlSize(.small)
        }
    }

    private func raise(_ n: StickyNote) -> some View {
        Button(tr(.bringToFront)) { model.raise() }.disabled(model.isFrontmost(n))
    }

    private var save: some View {
        Button(tr(.saveTextFile)) { model.saveNote() }.disabled(!model.canSaveNote)
    }
}

/// A note's colour, as a small square of its paper.
struct MemoNoteChip: View {
    let colour: NoteColour

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(colour.face.swatch)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(colour.edge.swatch))
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The text-field look of a note editor: the text background and a hairline rounded border.
    func memoEditorFrame() -> some View {
        background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

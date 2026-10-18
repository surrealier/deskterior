/// Sticky notes, the day pages and the D-Day (Erratum 31). Memo actions emit no `.persist`: `MemoSaver` follows
/// `state.memos`. Text is kept as `MemoBook.clean` makes it; day keys always arrive in the action (`DeskScene.today`,
/// the Memos window), so the reducer reads no calendar. Where a note rests is `PartitionLayout`'s to say.
extension Reducer {
    /// `.addNote`, `.editNote`, `.noteColour`, `.noteDay`, `.moveNote`, `.raiseNote`, `.removeNote`, `.editDayPage`,
    /// `.tearOffPage`, `.setDDay`.
    static func reduceMemos(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect] {
        switch a {
        case let .addNote(n, _):
            // Ids are never reused: a note's id is `nextNoteID` or later (a stale one, taken since, is refused).
            guard s.memos.notes[n.id] == nil, n.id.number >= s.memos.nextNoteID.number else { return [] }
            guard s.memos.notes.count < MemoBook.maxNotes else { return [.toast(.partitionFull)] }
            let pos = n.at.flatMap { PartitionLayout.snap($0, in: s) } ?? PartitionLayout.firstFreeSpot(in: s)
            s.memos.notes[n.id] = StickyNote(id: n.id, text: MemoBook.clean(n.text), colour: n.colour, pos: pos,
                                             z: topZ(s) + 1, day: n.day, created: env.now, edited: env.now)
            s.memos.nextNote = max(s.memos.nextNote, n.id.number + 1)
            // A note made where it was dropped needs no pop: it is already there.
            return n.at == nil ? [.play(.notePop, .note(n.id)), .wakeLoop] : [.wakeLoop]

        case let .editNote(id, text, _):
            let clean = MemoBook.clean(text)
            guard let note = s.memos.notes[id], note.text != clean else { return [] }
            s.memos.notes[id]?.text = clean
            s.memos.notes[id]?.edited = env.now
            return [.wakeLoop]

        case let .noteColour(id, colour):
            guard let note = s.memos.notes[id], note.colour != colour else { return [] }
            s.memos.notes[id]?.colour = colour
            s.memos.notes[id]?.edited = env.now
            return [.wakeLoop]

        case let .noteDay(id, day):
            guard let note = s.memos.notes[id], note.day != day else { return [] }
            s.memos.notes[id]?.day = day
            s.memos.notes[id]?.edited = env.now
            return [.wakeLoop]

        case let .moveNote(id, p):
            // Nowhere valid near the drop: nothing changes, and the scene springs the note back.
            guard s.memos.notes[id] != nil, let spot = PartitionLayout.snap(p, in: s) else { return [] }
            let z = topZ(s, except: id) + 1
            s.memos.notes[id]?.pos = spot
            s.memos.notes[id]?.z = z
            return [.wakeLoop]

        case let .raiseNote(id):
            let z = topZ(s, except: id) + 1
            guard let note = s.memos.notes[id], note.z < z else { return [] }
            s.memos.notes[id]?.z = z
            return [.wakeLoop]

        case let .removeNote(id):
            guard s.memos.notes.removeValue(forKey: id) != nil else { return [] }
            return [.wakeLoop]

        case let .editDayPage(day, text, _):
            let clean = MemoBook.clean(text)
            guard (s.memos.pages[day] ?? "") != clean else { return [] }
            s.memos.pages[day] = clean.isEmpty ? nil : clean
            return [.wakeLoop]

        case let .tearOffPage(day, at):
            // The page moves into a cream note dated that day; it is not copied.
            guard let text = s.memos.pages[day], !text.isEmpty, s.isOut(.partition) else { return [] }
            guard s.memos.notes.count < MemoBook.maxNotes else { return [.toast(.partitionFull)] }
            let id = s.memos.nextNoteID
            let pos = at.flatMap { PartitionLayout.snap($0, in: s) } ?? PartitionLayout.firstFreeSpot(in: s)
            s.memos.notes[id] = StickyNote(id: id, text: text, colour: .cream, pos: pos, z: topZ(s) + 1, day: day,
                                           created: env.now, edited: env.now)
            s.memos.nextNote = max(s.memos.nextNote, id.number + 1)
            s.memos.pages[day] = nil
            return at == nil ? [.play(.notePop, .note(id)), .wakeLoop] : [.wakeLoop]

        case let .setDDay(d):
            let dDay = d.map { DDay(day: $0.day, title: MemoBook.clean($0.title, limit: MemoBook.maxTitle)) }
            guard dDay != s.memos.dDay else { return [] }
            let shows = s.memos.dDay == nil && dDay != nil
            s.memos.dDay = dDay
            // A card that now shows takes its place on the felt: a note resting there moves aside.
            if shows { _ = settleNotes(&s) }
            return [.wakeLoop]

        default:
            return []
        }
    }

    /// The frontmost note's z (−1 with none), leaving out `id`.
    private static func topZ(_ s: DeskState, except id: NoteID? = nil) -> Int {
        s.memos.notes.values.filter { $0.id != id }.map(\.z).max() ?? -1
    }
}

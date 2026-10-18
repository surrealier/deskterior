import DeskCore

/// The desk partition in the room (Erratum 31) and the room's side of Put Away (Erratum 30): the memo clips and the
/// partition share the partition's hit-test slot (the clips in front), the wall calendar takes its own (installed with
/// the room controls); the dust puff where an object leaves or comes back, and a new note's pop.
extension RoomContent {
    /// Builds and installs the memo clips and the partition (called once from `init`).
    func installPartition() {
        let placed: () -> PlacedElement? = { [unowned self] in elements.first { $0.id == "partition" } }
        let clips = MemoClipsElement(context: context)
        clips.placed = placed
        clips.activeCarry = { [unowned self] in router.drag as? CarrySession }
        clips.refreshHover = { [unowned self, unowned clips] in
            let before = hovered
            _ = router.refreshHover()
            if hovered == before { restyleHover(clips) }
        }
        install([clips, PartitionElement(context: context, placed: placed)], inSlotOf: "partition")
    }

    var partitionElement: PartitionElement? { extras.lazy.compactMap { $0 as? PartitionElement }.first }
    var memoClipsElement: MemoClipsElement? { extras.lazy.compactMap { $0 as? MemoClipsElement }.first }
    var calendarElement: CalendarElement? { extras.lazy.compactMap { $0 as? CalendarElement }.first }

    /// Model animations for putting away and bringing back (a dust puff at the bottom centre of where the object
    /// stands; none for wall decor, none with Reduce Motion) and a new note's pop. True when it was one of those.
    func playPartition(_ id: AnimationID, _ target: AnimTarget) -> Bool {
        switch (id, target) {
        case let (.putAway, .stowable(object)), let (.bringBack, .stowable(object)):
            if !context.reduceMotion, let name = StowCatalog.spec(object).anchor, let r = layout.anchors[name] {
                context.fx.puff(at: ArtPoint(r.midX, r.maxY))
            }
            return true
        case let (.notePop, .note(note)):
            partitionElement?.playPop(note)
            return true
        default:
            return false
        }
    }

    /// The room's day may have turned (midnight, a clock preview past it): the pad shows that day's page.
    func roomTimeChanged(from old: RoomState) {
        guard DayKey(old.time) != DayKey(state.time) else { return }
        partitionElement?.render()
    }
}

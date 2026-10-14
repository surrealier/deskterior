/// The desk mat, the brush and Clear the Desk (DESIGN §2.2 E9, E10, E16; M9). Mat commands only ask the scene's cloth
/// to move (it commits its pose with `matSettled` when it settles); the brush commits where it came to rest; a drop
/// that joins a covered pile slides it in with the same move (`tuckUnderMat`); Clear the Desk applies its whole
/// `ClearDeskPlan` at once, as one journaled change ("Clear the Desk"), and the scene plays it.
extension Reducer {
    static func reduceMat(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect] {
        switch a {
        case let .mat(command):
            return [.play(.matCommand, .mat(command)), .wakeLoop]
        case let .brushSettled(p):
            let desk = DeskPlanePhysics.desk
            guard p.isFinite else { return [] }
            let at = SIMD2(min(max(p.x, desk.x), desk.x + desk.width), min(max(p.y, desk.d), desk.d + desk.depth))
            guard at != s.brush.pos else { return [] }
            s.brush.pos = at
            return [.persist, .wakeLoop]
        case let .tuckUnderMat(keys, pile, at):
            // The drop itself (an existing pile keeps its place there), then the pile slides in to `at`.
            var effects = dropOnDesk(&s, keys.map(s.currentKey), pile: pile, at: at, grid: env.grid)
            if let p = s.piles[pile], p != at, !effects.isEmpty {
                s.piles[pile] = at
                effects = [.persist, .wakeLoop]
            }
            return effects
        default:
            return []
        }
    }

    /// Clear the Desk: the plan's layout at once (monitor off, phone face down, drawers shut, loose piles and floor
    /// tokens under the mat), then the scene's brush pass and "TIDY!" (played even on a desk that is already tidy).
    static func reduceClearDesk(_ s: inout DeskState, _ env: ReduceEnv) -> [Effect] {
        let plan = ClearDeskPlan.make(s)
        var effects: [Effect] = plan.powerOff ? [.play(.crtOff, .monitor)] : []
        plan.apply(to: &s, grid: env.grid)
        effects.append(.play(.clearDesk, .clearDesk(plan)))
        return effects + (plan.changesLayout ? [.persist, .wakeLoop] : [.wakeLoop])
    }
}

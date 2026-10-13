import Foundation

/// Container commands (DESIGN §2.2 E3–E6, §2.1 non-destructive un-hiding): Open / Close from a container's menu,
/// the phone's face (committed by `PhoneMachine` at the start of a flip), and the reveal Show on Desk does. Each
/// only sets where an element should come to rest; the scene animates there (a drawer slides, the chair rolls,
/// the phone flips) and its own settle commits agree with it. None of these is journaled: opening a drawer is
/// not a layout change to undo.
extension Reducer {
    static func reduceContainer(_ s: inout DeskState, _ a: DeskAction) -> [Effect] {
        let changed: Bool
        switch a {
        case let .openContainer(id):
            changed = revealContainer(&s, id)
        case let .closeContainer(id):
            changed = shutContainer(&s, id)
        case let .phoneFace(down):
            changed = s.phone.faceDown != down
            s.phone.faceDown = down
        default:
            changed = false
        }
        return changed ? [.persist, .wakeLoop] : []
    }

    /// Opens `id` for the user to see into: a drawer all the way (left as it is when already open); a cabinet
    /// drawer also shuts the other two (they are interlocked) and, when the chair stands in front of the cabinet,
    /// rolls it clear (`chairClearX`); the phone turns face up. Other containers show their contents already.
    /// True when the model changed.
    @discardableResult
    public static func revealContainer(_ s: inout DeskState, _ id: ContainerID) -> Bool {
        let before = s
        if id == .phone {
            s.phone.faceDown = false
        } else if let travel = id.spec.travel {
            if s.drawerOpening(id) < Visibility.drawerOpen { s.drawers[id] = DrawerState(p: travel) }
            for other in DrawerSim.interlocked(id) where s.drawerOpening(other) > restingGap(other, s) {
                s.drawers[other] = DrawerState(p: restingGap(other, s))
            }
            if !DrawerSim.interlocked(id).isEmpty,
               DrawerSim.cabinetOpenLimit(travel: travel, chairX: s.chair.x) < travel {
                s.chair.x = chairClearX
            }
        }
        return s != before
    }

    /// Shuts `id`: a drawer to its resting gap (0, or ajar when overfull), the phone face down. True when the
    /// model changed.
    @discardableResult
    public static func shutContainer(_ s: inout DeskState, _ id: ContainerID) -> Bool {
        let before = s
        if id == .phone {
            s.phone.faceDown = true
        } else if id.isDrawer, s.drawerOpening(id) > restingGap(id, s) {
            s.drawers[id] = DrawerState(p: restingGap(id, s))
        }
        return s != before
    }

    /// The opening a shut drawer rests at: its jam gap for the items it holds.
    static func restingGap(_ id: ContainerID, _ s: DeskState) -> Float {
        id.spec.closedLimit(count: s.tokens.count(in: id))
    }

    /// The chair's left edge two pixels short of blocking the cabinet (DESIGN §2.2 E5: an overlap of more than
    /// `chairBlockOverlap` px blocks it).
    public static var chairClearX: Float {
        Float(CoreLayout.cabinet.minX + DrawerSim.Params.standard.chairBlockOverlap - CoreLayout.chair.w - 2)
    }
}

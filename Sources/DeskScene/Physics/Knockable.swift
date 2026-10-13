import DeskCore

/// An installed element that reacts to a desk knock (DESIGN §2.2 E11): a double-click on the apron or a drawer slam
/// calls `knock(_:)` on every installed element that conforms. Drawer elements conform to close themselves: each
/// drawer in `plan.drawerCloses` they list in `knockedDrawers` snaps shut on its live sim and commits its own
/// `drawerSettled`; drawers nobody lists are committed straight from `DeskKnock.actions`. A knock never changes
/// where a token lives.
public protocol Knockable: AnyObject {
    /// Drawers this element closes itself on a knock.
    var knockedDrawers: Set<ContainerID> { get }
    func knock(_ plan: DeskKnock.Plan)
}

extension Knockable {
    public var knockedDrawers: Set<ContainerID> { [] }
}

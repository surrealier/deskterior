import DeskCore
import SpriteKit

/// The desk's apron (DESIGN §2.2 E11): a double-click knocks the desk (1 s cooldown; `PhysicsHub.knock`). It plays
/// the knock's wobbles for the props it does not own: the monitor (with its screen), the phone, the lamp, the plant
/// and the keyboard shake a pixel sideways in stepped frames. The apron itself takes no drops and has no ring.
final class ApronElement: DeskElement {
    let id = "apron"
    let root = SKNode()
    unowned let hub: PhysicsHub
    /// The nodes that wobble for each prop (the room's sprites and whatever element draws over them).
    var wobbleNodes: (DeskKnock.Wobbler) -> [SKNode] = { _ in [] }
    private var wobble: (plan: DeskKnock.Plan, frame: Int)?
    private var moved: [ObjectIdentifier: (node: SKNode, x: CGFloat)] = [:]

    init(hub: PhysicsHub) {
        self.hub = hub
    }

    var context: SceneContext { hub.context }

    func layout(_ layout: SceneLayout) {
        restore()
        wobble = nil
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        let r = context.layout.rect(CoreLayout.apron)
        guard r.contains(p) else { return nil }
        return Hit(element: id, part: "apron", rect: r)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle { .none }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard case let .click(p, _, count) = gesture else { return .pass }
        if count == 2 { hub.knock(atCoreX: hub.core(p).x) }
        return .handled
    }

    // MARK: Wobbles

    /// Plays the knock's wobbles (the pen cup wobbles by itself).
    func wobble(_ plan: DeskKnock.Plan) {
        restore()
        wobble = (plan, 0)
        apply()
    }

    private func apply() {
        guard let w = wobble else { return }
        for (prop, hop) in w.plan.wobbles where prop != .penCup {
            let lean = hop.lean(atFrame: w.frame)
            for node in wobbleNodes(prop) {
                let id = ObjectIdentifier(node)
                let base = moved[id]?.x ?? node.position.x
                moved[id] = (node, base)
                node.position.x = base + CGFloat(lean) * ArtSpace.unitsPerPixel
            }
        }
    }

    private func restore() {
        for (_, m) in moved { m.node.position.x = m.x }
        moved.removeAll()
    }

    var needsFrames: Bool { wobble != nil }

    func step(_ dt: Double) {
        guard var w = wobble else { return }
        w.frame += 1
        if w.frame >= w.plan.frames {
            wobble = nil
            restore()
        } else {
            wobble = w
            apply()
        }
    }

    func settle() {
        wobble = nil
        restore()
    }
}

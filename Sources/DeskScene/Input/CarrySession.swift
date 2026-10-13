import DeskCore
import SpriteKit

/// Carries tokens with the pointer (DESIGN §2.1 Drag): no physics body; the stack follows one frame behind with
/// a 2-px lift over its shadow on the L8 carry layer (the shadow trails fast sideways moves), and shows "+N" for a
/// multi-selection. Each move asks the `DropResolver` where a release would go, so the screen can bracket the
/// landing cell. Hovering a page dot for 0.6 s turns to that page (spring-loading; a scroll pages too). On
/// release: accept → one `.move` action (the reducer swaps, or pours several tokens into the nearest free cells,
/// which print in 40 ms apart); bonk → "BONK", a 1-px shake and a spring back over 6 frames, the lift settling
/// as it lands; no verdict → spring back. Esc springs back too. The model is not touched until the drop, so an
/// interrupted carry leaves every token where it was.
final class CarrySession: DragController {
    enum Phase: Equatable {
        case carrying
        /// Flying home from `from` (canvas top-left of the lead icon), `t` in 0…1.
        case springing(from: SIMD2<Float>, t: Double)
        case done
        // MARK: physics
        /// Left the hand on an arc (`PhysicsHub.release`): the flight draws it and lands it (`landed()`).
        case flying
    }

    static let lift = 2
    static let springFrames = 6.0
    /// Sideways speed (art px per frame) past which the shadow trails the stack.
    static let leanSpeed: Float = 3
    /// Hovering a page dot this long turns to its page (DESIGN §2.1 spring-loading).
    static let springLoadDelay = 0.6

    let keys: [TokenKey]
    /// Canvas top-left of each token's icon when picked up (lead first).
    let origins: [ArtPoint]
    private unowned let context: SceneContext
    /// Pointer offset from the lead icon's top-left.
    private let grab: SIMD2<Float>
    private(set) var phase: Phase = .carrying
    private(set) var pointer: SIMD2<Float>
    /// Where the stack is drawn (one frame behind the pointer).
    private(set) var shown: SIMD2<Float>
    private var previous: SIMD2<Float>
    private var lean = 0
    private var lift = CarrySession.lift
    private(set) var verdict: DropResolver.Resolution?
    /// The page dot under the stack and how long it has been there.
    private var springLoad: (page: Int, t: Double)?
    private let node = SKSpriteNode()
    private var stackImages: [Int: PixelBuffer] = [:]

    init(keys: [TokenKey], origins: [ArtPoint], grab: SIMD2<Float>, context: SceneContext) {
        precondition(!keys.isEmpty && keys.count == origins.count, "a carry needs tokens and their origins")
        self.keys = keys
        self.origins = origins
        self.context = context
        let o = SIMD2(Float(origins[0].x), Float(origins[0].y))
        self.grab = grab - o
        pointer = grab
        shown = grab
        previous = grab
        node.zPosition = CGFloat(RoomLayer.carry.rawValue * 1000)
        context.carryLayer.addChild(node)
        context.screen?.carried.formUnion(keys)
        redraw()
        place(topLeft(of: shown))
    }

    var isFinished: Bool { phase == .done }
    var needsFrames: Bool { phase != .done }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard phase == .carrying else { return }
        pointer = p
        let r = DropResolver.resolve(keys, at: artPixel(p), elements: context.dropTargets())
        verdict = r
        if case let .accept(loc)? = r?.verdict, let cell = loc.cell {
            context.screen?.dropTarget = cell
        } else {
            context.screen?.dropTarget = nil
        }
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard phase == .carrying else { return }
        moved(to: p, mods: mods)
        context.screen?.dropTarget = nil
        // M7: drops on the bare desk, flings and falls leave the hand on an arc.
        if context.physics?.release(self, at: p, velocity: velocity) == true { return }
        let lead = topLeft(of: p)
        switch verdict?.verdict {
        case let .accept(.container(id, _))?
            where keys.allSatisfy({ context.state?.tokens.location(of: $0)?.container == id }):
            // Back into the container they all came from: not a move (no reorder, nothing to undo).
            springBack(from: lead)
        case let .accept(loc)?:
            // Landed: the model change the drop causes must not re-aim this carry.
            phase = .done
            context.dispatch(.move(keys, to: loc))
            finish()
            // Several tokens pour in one after another (40 ms apart).
            if keys.count > 1 { context.screen?.playPrintIn(keys) }
        case let .bonk(reason)?:
            context.fx.pop(.bonk, at: ArtPoint(Int(p.x), Int(p.y) - 4))
            context.shake(frames: 2)
            if let reason { context.toast(reason) }
            context.bonks += 1
            springBack(from: lead)
        case nil:
            springBack(from: lead)
        }
    }

    func cancelled() {
        guard phase == .carrying else { return }
        context.screen?.dropTarget = nil
        springBack(from: topLeft(of: shown))
    }

    func step(_ dt: Double) {
        switch phase {
        case .carrying:
            let dx = pointer.x - previous.x
            let newLean = dx > Self.leanSpeed ? 1 : (dx < -Self.leanSpeed ? -1 : 0)
            shown = previous
            previous = pointer
            if newLean != lean {
                lean = newLean
                redraw()
            }
            place(topLeft(of: shown))
            stepSpringLoad(dt)
        case let .springing(from, t):
            let next = t + dt * 60 / Self.springFrames
            if next >= 1 {
                finish()
            } else {
                phase = .springing(from: from, t: next)
                let e = Float(1 - (1 - next) * (1 - next))
                let to = SIMD2(Float(origins[0].x), Float(origins[0].y))
                // The lift comes down with the flight, the shadow closing in under the icon.
                let newLift = Int((Float(Self.lift) * (1 - e)).rounded())
                if newLift != lift {
                    lift = newLift
                    redraw()
                }
                place(from + (to - from) * e)
            }
        case .done, .flying:
            break
        }
    }

    /// Hard sleep or teardown: the tokens are home at once (or, in the air, land now).
    func finishNow() {
        if phase == .carrying { context.screen?.dropTarget = nil }
        if phase == .flying { context.physics?.landNow(self) }
        finish()
    }

    // MARK: physics

    /// Canvas point of the lead icon's base (bottom centre) with the pointer at `p`: where a release falls from.
    func basePoint(at p: SIMD2<Float>) -> SIMD2<Float> {
        topLeft(of: p) + SIMD2(8, 16)
    }

    /// The physics hub took the release: the stack's sprite gives way to the flight's.
    func handOff() {
        phase = .flying
        springLoad = nil
        node.isHidden = true
    }

    /// The flight landed (and committed where).
    func landed() {
        finish()
    }

    // MARK: Private

    private func artPixel(_ p: SIMD2<Float>) -> ArtPoint { ArtPoint(Int(p.x.rounded(.down)), Int(p.y.rounded(.down))) }

    private func topLeft(of pointer: SIMD2<Float>) -> SIMD2<Float> { pointer - grab }

    /// Counts how long the pointer rests on a page dot; at `springLoadDelay` the screen turns to that page.
    private func stepSpringLoad(_ dt: Double) {
        guard let page = context.screen?.monitor?.springPage(at: artPixel(pointer)) else {
            springLoad = nil
            return
        }
        let t = (springLoad?.page == page ? springLoad!.t : 0) + dt
        if t >= Self.springLoadDelay {
            springLoad = nil
            context.dispatch(.setPage(page))
            moved(to: pointer, mods: [])
        } else {
            springLoad = (page, t)
        }
    }

    private func springBack(from: SIMD2<Float>) {
        lean = 0
        springLoad = nil
        redraw()
        phase = .springing(from: from, t: 0)
    }

    private func finish() {
        phase = .done
        node.removeFromParent()
        // Only this carry's tokens: another carry may already be in hand.
        if let screen = context.screen {
            let mine = Set(keys + keys.compactMap { context.state?.currentKey(for: $0) })
            screen.carried.subtract(mine)
            screen.render()
        }
    }

    /// The stack image: up to three icons offset up-right and lifted, a dithered shadow below (trailing a fast
    /// sideways move by a pixel), and a "+N" badge for more than one token. Origin = the lead icon's resting
    /// top-left minus `stackPadding`.
    private func redraw() {
        let id = lean * 10 + lift
        let image = stackImages[id] ?? makeStack(lean: lean, lift: lift)
        stackImages[id] = image
        node.texture = TextureFactory.texture(image)
        node.size = CGSize(width: CGFloat(image.width) * ArtSpace.unitsPerPixel, height: CGFloat(image.height) * ArtSpace.unitsPerPixel)
    }

    static let stackPadding = ArtPoint(2, 8)

    private func makeStack(lean: Int, lift: Int) -> PixelBuffer {
        guard let s = context.state else { return PixelBuffer(width: 1, height: 1) }
        let icons = keys.prefix(3).compactMap { k in s.tokens.meta(of: k).map { TokenArt.icon(k, $0, context) } }
        let pad = Self.stackPadding
        var c = PixelCanvas(width: 16 + pad.x + 8, height: 16 + pad.y + Self.lift + 2)
        // The shadow where the stack would rest (a 50% dither, so it reads on anything), 1 px right and `lift` px
        // down; a fast sideways move leaves it a pixel behind. Gone once the stack has landed.
        if lift > 0, let lead = icons.first {
            let dx = 1 - lean
            for y in 0..<lead.height {
                for x in 0..<lead.width where lead.pixel(x, y).a != 0 && (x + y) % 2 == 0 {
                    c.plot(pad.x + x + dx, pad.y + y + lift, .neutral0)
                }
            }
        }
        for (i, icon) in icons.enumerated().reversed() {
            c.blit(icon, at: ArtPoint(pad.x + 2 * i, pad.y - lift - 2 * i))
        }
        if keys.count > 1 {
            let badge = Digits.badge("+\(keys.count)")
            c.blit(badge, at: ArtPoint(min(c.width - badge.width, pad.x + 10), 0))
        }
        return c.buffer
    }

    /// Places the stack so the lead icon's resting top-left is at `p`.
    private func place(_ p: SIMD2<Float>) {
        let image = stackImages[lean * 10 + lift]
        let size = image?.size ?? ArtSize(1, 1)
        let pad = Self.stackPadding
        let origin = ArtPoint(Int(p.x.rounded()) - pad.x, Int(p.y.rounded()) - pad.y)
        context.space.place(node, at: ArtRect(origin: origin, size: size))
    }
}

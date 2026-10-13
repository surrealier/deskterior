import DeskCore
import SpriteKit

/// Carries tokens with the pointer (DESIGN §2.1 Drag): no physics body; the stack follows one frame behind with
/// a 2-px lift over its shadow on the L8 carry layer, leans with fast sideways moves, and shows "+N" for a
/// multi-selection. Each move asks the `DropResolver` where a release would go, so the screen can bracket the
/// landing cell. On release: accept → one `.move` action (the reducer swaps, or pours several tokens into the
/// nearest free cells, which print in 40 ms apart); bonk → "BONK", a 1-px
/// shake and a spring back over 6 frames; no verdict → spring back. Esc springs back too. The model is not
/// touched until the drop, so an interrupted carry leaves every token where it was.
final class CarrySession: DragController {
    enum Phase: Equatable {
        case carrying
        /// Flying home from `from` (canvas top-left of the lead icon), `t` in 0…1.
        case springing(from: SIMD2<Float>, t: Double)
        case done
    }

    static let lift = 2
    static let springFrames = 6.0
    /// Sideways speed (art px per frame) past which the stack leans.
    static let leanSpeed: Float = 3

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
    private(set) var verdict: DropResolver.Resolution?
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
        context.screen?.carried = Set(keys)
        redraw()
        place(topLeft(of: shown), lifted: true)
    }

    var isFinished: Bool { phase == .done }
    var needsFrames: Bool { phase != .done }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard phase == .carrying else { return }
        pointer = p
        let r = DropResolver.resolve(keys, at: ArtPoint(Int(p.x.rounded(.down)), Int(p.y.rounded(.down))),
                                     elements: context.dropTargets())
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
        let lead = topLeft(of: p)
        switch verdict?.verdict {
        case let .accept(loc)?:
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
            place(topLeft(of: shown), lifted: true)
        case let .springing(from, t):
            let next = t + dt * 60 / Self.springFrames
            if next >= 1 {
                finish()
            } else {
                phase = .springing(from: from, t: next)
                let e = Float(1 - (1 - next) * (1 - next))
                let to = SIMD2(Float(origins[0].x), Float(origins[0].y))
                let p = from + (to - from) * e
                place(ArtPoint(Int(p.x.rounded()), Int(p.y.rounded())), lifted: false)
            }
        case .done:
            break
        }
    }

    /// Hard sleep or teardown: the tokens are home at once.
    func finishNow() {
        if phase == .carrying { context.screen?.dropTarget = nil }
        finish()
    }

    // MARK: Private

    private func topLeft(of pointer: SIMD2<Float>) -> SIMD2<Float> { pointer - grab }

    private func springBack(from: SIMD2<Float>) {
        lean = 0
        redraw()
        phase = .springing(from: from, t: 0)
    }

    private func finish() {
        phase = .done
        node.removeFromParent()
        context.screen?.carried = []
        context.screen?.render()
    }

    /// The stack image: up to three icons offset up-right, the lead leaning with the motion, a dithered shadow
    /// `lift` px below, and a "+N" badge for more than one token. Origin = the lead icon's top-left minus
    /// `stackPadding`.
    private func redraw() {
        let image = stackImages[lean] ?? makeStack(lean: lean)
        stackImages[lean] = image
        node.texture = TextureFactory.texture(image)
        node.size = CGSize(width: CGFloat(image.width) * ArtSpace.unitsPerPixel, height: CGFloat(image.height) * ArtSpace.unitsPerPixel)
    }

    static let stackPadding = ArtPoint(2, 8)

    private func makeStack(lean: Int) -> PixelBuffer {
        guard let s = context.state else { return PixelBuffer(width: 1, height: 1) }
        let icons = keys.prefix(3).compactMap { k in s.tokens.meta(of: k).map { TokenArt.icon(k, $0, context) } }
        let pad = Self.stackPadding
        var c = PixelCanvas(width: 16 + pad.x + 8, height: 16 + pad.y + Self.lift + 2)
        // Shadow where the stack would rest, a 50% dither so it reads as a shadow on anything.
        if let lead = icons.first {
            for y in 0..<lead.height {
                for x in 0..<lead.width where lead.pixel(x, y).a != 0 && (x + y) % 2 == 0 {
                    c.plot(pad.x + x + 1, pad.y + y + Self.lift, .neutral0)
                }
            }
        }
        for (i, icon) in icons.enumerated().reversed() {
            var image = icon
            if i == 0, lean != 0 { image = Self.leaning(icon, lean) }
            c.blit(image, at: ArtPoint(pad.x + 2 * i, pad.y - Self.lift - 2 * i))
        }
        if keys.count > 1 {
            let badge = Digits.badge("+\(keys.count)")
            c.blit(badge, at: ArtPoint(min(c.width - badge.width, pad.x + 10), 0))
        }
        return c.buffer
    }

    /// The icon sheared one pixel at the top in the direction of travel (a lean, no rotation blur).
    static func leaning(_ icon: PixelBuffer, _ dir: Int) -> PixelBuffer {
        var out = PixelBuffer(width: icon.width, height: icon.height)
        for y in 0..<icon.height {
            let shift = y < icon.height / 2 ? dir : 0
            for x in 0..<icon.width {
                let sx = x - shift
                if sx >= 0, sx < icon.width { out[x, y] = icon[sx, y] }
            }
        }
        return out
    }

    /// Places the stack so the lead icon's top-left is at `p` (lifted while carried).
    private func place(_ p: SIMD2<Float>, lifted: Bool) {
        place(ArtPoint(Int(p.x.rounded()), Int(p.y.rounded())), lifted: lifted)
    }

    private func place(_ p: ArtPoint, lifted: Bool) {
        let image = stackImages[lean]
        let size = image?.size ?? ArtSize(1, 1)
        let pad = Self.stackPadding
        // While springing home the lift settles too: the drawn icon lands exactly on its cell.
        let origin = ArtPoint(p.x - pad.x, p.y - pad.y + (lifted ? 0 : Self.lift))
        context.space.place(node, at: ArtRect(origin: origin, size: size))
    }
}

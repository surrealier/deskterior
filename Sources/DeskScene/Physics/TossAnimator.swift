import DeskCore
import SpriteKit

/// Things in the air (DESIGN §2.2 E8, E11; §2.1 juice): flung carries, piles pushed off the desk, pens and balls
/// spilling, drops into the basket. Each flight follows an analytic path (a `Ballistics.Toss` in desk space, or a
/// hop in core px), drawn on the fx band above the under-desk furniture and below the chair, its sprite's bottom
/// centre on the path, over a shadow on the desk (or its front lip while it flies just in front of it) or the floor.
/// A ball inside the wastebasket is clipped at the front rim, so it drops in behind it; a token headed for the
/// basket crumples into a paper ball (over two frames) as it nears the mouth and stays one until it lands, where a
/// miss uncrumples. Each rim contact calls `onRim`. On touchdown it squashes for three frames, as hard as it landed
/// (none in the basket), then `onLand` commits where it ended. `landAll` (hard sleep) lands everything at once.
/// Deterministic: time comes only from `step`.
final class TossAnimator {
    enum Path {
        case toss(Ballistics.Toss)
        /// From `from` to `to` (core px), `height` px over the straight line at its middle, in `duration` s.
        case hop(from: SIMD2<Float>, to: SIMD2<Float>, height: Float, duration: Float)
    }

    /// How a flight looks in the air.
    enum Look {
        /// The token stack.
        case token
        /// The token, crumpling into a paper ball near the basket's mouth.
        case crumpling
        /// A paper ball until it lands (balls rolling out of a tipped basket uncrumple on the floor).
        case ball
    }

    final class Flight {
        let keys: [TokenKey]
        let path: Path
        /// The flying image and the image px of its bottom centre.
        let image: PixelBuffer
        let base: ArtPoint
        let look: Look
        let ball: PixelBuffer
        /// Squash on touchdown: `PileArt.squash` amount (0: none).
        let squashAmount: Int
        let onLand: (Flight) -> Void
        let node = SKSpriteNode()
        /// Its shadow on the desk or the floor below it.
        let shadow = SKSpriteNode()
        var shadowShown: (key: Int, origin: ArtPoint)?
        var t: Float = 0
        /// Seconds before it sets off (hidden until then).
        var delay: Float
        /// Frames of squash shown so far, once it has touched down.
        var squashFrame: Int?
        var shown: (key: Int, origin: ArtPoint)?
        var landed = false
        /// Steps since it started crumpling (nil: not yet); a crumpled token stays a ball until it lands.
        var crumpleAge: Int?
        /// Rim contacts already played.
        var rimsPlayed = 0
        lazy var squash: [PixelBuffer] = PileArt.squash(image, amount: squashAmount)
        /// Halfway to a ball: the image squeezed by whole rows and columns, outline kept.
        lazy var halfBall: PixelBuffer = PileArt.reshaped(
            image, to: ArtSize(max(1, image.width * 3 / 5), max(1, image.height * 3 / 5)))

        var squashes: Bool { squashAmount > 0 }

        init(keys: [TokenKey], path: Path, image: PixelBuffer, base: ArtPoint, look: Look, ball: PixelBuffer,
             squash: Int, delay: Float, onLand: @escaping (Flight) -> Void) {
            self.keys = keys
            self.delay = delay
            self.path = path
            self.image = image
            self.base = base
            self.look = look
            self.ball = ball
            self.squashAmount = squash
            self.onLand = onLand
        }

        var duration: Float {
            switch path {
            case let .toss(toss): toss.duration
            case let .hop(_, _, _, d): max(d, 1.0 / 60)
            }
        }

        var toss: Ballistics.Toss? {
            if case let .toss(t) = path { return t }
            return nil
        }
    }

    /// Steps a squash frame is held.
    static let squashHold = 2
    /// A crumpling token turns into a ball this close (canvas px) to the basket's mouth.
    static let crumpleDistance: Float = 26
    /// Steps a crumpling token shows its half-crumpled frame.
    static let crumpleHold = 2

    let root = SKNode()
    /// Shadows draw in the desk's and the floor's own bands (not on the flight's).
    let shadows = SKNode()
    private(set) var flights: [Flight] = []
    private unowned let context: SceneContext
    /// A toss touched a rim top at this core point (the ball's centre).
    var onRim: (SIMD2<Float>) -> Void = { _ in }
    /// Desk shadows one oak step down; floor ones in the darkest walnut so they read on the boards and the rug.
    private lazy var shadowImages: [PixelBuffer] = [Self.shadowImage(.oak2, wide: true), Self.shadowImage(.oak2, wide: false),
                                                     Self.shadowImage(.walnut0, wide: true),
                                                     Self.shadowImage(.walnut0, wide: false)]

    init(context: SceneContext, z: CGFloat) {
        self.context = context
        root.zPosition = z
    }

    var needsFrames: Bool { !flights.isEmpty }

    /// Tokens in the air now (not those whose flight has come down and is committing).
    var flyingKeys: Set<TokenKey> { Set(flights.filter { !$0.landed }.flatMap(\.keys)) }

    @discardableResult
    func launch(_ keys: [TokenKey], path: Path, image: PixelBuffer, base: ArtPoint, crumples: Bool = false,
                squash: Int = 2, delay: Float = 0, look: Look? = nil, onLand: @escaping (Flight) -> Void) -> Flight {
        let seed = keys.first.map(InteriorRaster.seed) ?? 0
        let f = Flight(keys: keys, path: path, image: image, base: base, look: look ?? (crumples ? .crumpling : .token),
                       ball: PropArt.paperBall(Int(seed % 3)).image, squash: squash, delay: delay, onLand: onLand)
        f.node.anchorPoint = .zero
        root.addChild(f.node)
        f.shadow.anchorPoint = .zero
        f.shadow.isHidden = true
        shadows.addChild(f.shadow)
        flights.append(f)
        place(f)
        return f
    }

    func step(_ dt: Double) {
        guard !flights.isEmpty else { return }
        for f in flights {
            if f.delay > 0 {
                f.delay -= Float(dt)
                if f.delay > 0 { continue }
            }
            if let s = f.squashFrame {
                f.squashFrame = s + 1
            } else {
                f.t += Float(dt)
                if let age = f.crumpleAge { f.crumpleAge = age + 1 }
                playRims(f)
                if f.t >= f.duration { f.squashFrame = f.squashes ? 0 : 3 * Self.squashHold }
            }
            if let s = f.squashFrame, s >= 3 * Self.squashHold {
                finish(f)
            } else {
                place(f)
            }
        }
        flights.removeAll { $0.landed }
    }

    /// Lands `flight` now (a hard sleep, or the carry it belongs to was cut short).
    func land(_ flight: Flight) {
        guard !flight.landed else { return }
        finish(flight)
        flights.removeAll { $0 === flight }
    }

    /// Hard sleep: everything lands where its path ends.
    func landAll() {
        let all = flights
        flights.removeAll()
        for f in all { finish(f) }
    }

    /// Rim contacts the flight has reached by now.
    private func playRims(_ f: Flight) {
        guard let toss = f.toss else { return }
        while f.rimsPlayed < toss.rimContacts.count, toss.rimContacts[f.rimsPlayed] <= f.t {
            let p = toss.position(at: toss.rimContacts[f.rimsPlayed])
            f.rimsPlayed += 1
            onRim(toss.projection.project(p) - SIMD2(0, Ballistics.Params.standard.radius))
        }
    }

    private func finish(_ f: Flight) {
        guard !f.landed else { return }
        f.landed = true
        f.node.removeFromParent()
        f.shadow.removeFromParent()
        f.onLand(f)
    }

    // MARK: Paths

    /// Core point of the path's bottom at time `t`, and the desk-space point for tosses.
    static func point(_ path: Path, at t: Float) -> (core: SIMD2<Float>, desk: SIMD3<Float>?) {
        switch path {
        case let .toss(toss):
            let p = toss.position(at: t)
            return (toss.projection.project(p), p)
        case let .hop(from, to, height, duration):
            let u = min(max(t / max(duration, 1e-3), 0), 1)
            let q = from + (to - from) * u
            return (SIMD2(q.x, q.y - height * 4 * u * (1 - u)), nil)
        }
    }

    /// Where a flight ends (core px).
    static func end(_ path: Path) -> SIMD2<Float> {
        switch path {
        case let .toss(toss): toss.projection.project(toss.end)
        case let .hop(_, to, _, _): to
        }
    }

    // MARK: Drawing

    /// The basket's mouth centre and the rows it hides below its front rim (core px).
    static let mouth = SIMD2<Float>(Float(CoreLayout.wastebasketMouth.midX), Float(CoreLayout.wastebasketMouth.minY + 3))
    static let rimClipY = CoreLayout.wastebasketMouth.minY + 4

    private func place(_ f: Flight) {
        let layout = context.layout
        guard f.delay <= 0 else {
            f.node.isHidden = true
            f.shadow.isHidden = true
            return
        }
        var (core, desk) = Self.point(f.path, at: min(f.t, f.duration))
        if let toss = f.toss, case .floor = toss.landing, toss.end.y <= 1 {
            // In front of the desk, it falls to the floor line and no further.
            core.y = f.squashFrame != nil ? Float(CoreLayout.floorY) : min(core.y, Float(CoreLayout.floorY))
        }
        var image = f.image
        var base = f.base
        var key = 0
        let nearMouth = simd_length(core - Self.mouth) <= Self.crumpleDistance
        let inside = desk.map { Self.insideBasket($0, f.toss) } ?? (f.look == .crumpling && nearMouth && core.y > Self.mouth.y)
        if f.look == .crumpling, f.crumpleAge == nil, nearMouth || inside { f.crumpleAge = 0 }
        if f.squashFrame == nil, f.look == .ball || f.crumpleAge != nil {
            if let age = f.crumpleAge, age < Self.crumpleHold {
                image = f.halfBall
                base = ArtPoint(image.width / 2, image.height - max(0, f.image.height - f.base.y) * 3 / 5)
                key = 2
            } else {
                image = f.ball
                base = ArtPoint(f.ball.width / 2, f.ball.height)
                key = 1
            }
        }
        var origin = layout.point(ArtPoint(Int(core.x.rounded()) - base.x, Int(core.y.rounded()) - base.y))
        if let s = f.squashFrame, f.squashes {
            // Touchdown: the squash (a crumpled miss uncrumples into it).
            image = f.squash[min(2, s / Self.squashHold)]
            origin = origin - ArtPoint(2, 2)
            key = 10 + min(2, s / Self.squashHold)
        }
        placeShadow(f, core: core, desk: desk, hidden: inside || f.squashFrame != nil)
        if inside {
            // Below the front rim it is behind the basket's front.
            let clip = layout.y(Self.rimClipY) - origin.y
            if clip <= 0 {
                f.node.isHidden = true
                return
            }
            if clip < image.height {
                image = image.cropped(to: ArtRect(0, 0, image.width, clip))
                key = 100 + clip
            }
        }
        f.node.isHidden = false
        if f.shown?.key != key {
            f.node.texture = TextureFactory.texture(image)
        }
        if f.shown?.key != key || f.shown?.origin != origin {
            context.space.place(f.node, at: ArtRect(origin: origin, size: image.size))
            f.shown = (key, origin)
        }
    }

    /// The shadow straight below the flight: on the desk top while over it (on its front lip while it flies just in
    /// front of the desk above the top, so it reads as in front of the desk, not over it), else on the floor (at the
    /// floor line in front of the desk); smaller the higher it flies. Hops along the floor keep theirs on the line.
    private func placeShadow(_ f: Flight, core: SIMD2<Float>, desk: SIMD3<Float>?, hidden: Bool) {
        var ground: (point: SIMD2<Float>, onDesk: Bool, height: Float)?
        if let p = desk, let toss = f.toss {
            let b = Ballistics.Params.standard
            let overDesk = b.deskX.contains(p.x) && p.y >= b.frontPlaneD - 0.5 && p.y <= b.backD && p.z >= -0.5
            let z: Float = overDesk ? 0 : b.floorZ
            var q = toss.projection.project(SIMD3(p.x, overDesk ? max(p.y, 0) : p.y, z))
            if !overDesk { q.y = min(q.y, Float(CoreLayout.floorY + 1)) }
            ground = (q, overDesk, p.z - z)
        } else if case let .hop(from, to, _, _) = f.path, abs(from.y - to.y) < 1, from.y >= Float(CoreLayout.floorY - 2) {
            ground = (SIMD2(core.x, from.y + (to.y - from.y) * min(f.t / max(f.duration, 1e-3), 1)), false,
                      from.y - core.y)
        }
        guard !hidden, let ground else {
            f.shadow.isHidden = true
            return
        }
        let wide = ground.height < 28
        let index = (ground.onDesk ? 0 : 2) + (wide ? 0 : 1)
        let image = shadowImages[index]
        let origin = context.layout.point(ArtPoint(Int(ground.point.x.rounded()) - image.width / 2,
                                                   Int(ground.point.y.rounded()) - 1))
        if f.shadowShown?.key != index {
            f.shadow.texture = TextureFactory.texture(image)
        }
        if f.shadowShown?.key != index || f.shadowShown?.origin != origin {
            context.space.place(f.shadow, at: ArtRect(origin: origin, size: image.size))
            f.shadowShown = (index, origin)
        }
        f.shadow.zPosition = ground.onDesk ? Self.deskShadowZ : Self.floorShadowZ
        f.shadow.isHidden = false
    }

    static let deskShadowZ = CGFloat(RoomLayer.deskSurface.rawValue * 1000 + 450)
    static let floorShadowZ = CGFloat(RoomLayer.underDesk.rawValue * 1000 - 2)

    /// A flat dithered shadow: 10×2 near the ground, 6×2 higher up.
    static func shadowImage(_ ink: Ink, wide: Bool) -> PixelBuffer {
        let w = wide ? 10 : 6
        var c = PixelCanvas(width: w, height: 2)
        for x in 0..<w where x > 0 && x < w - 1 || x % 2 == 0 { c.plot(x, 0, ink) }
        for x in 1..<(w - 1) where (x + 1) % 2 == 0 || (x > 1 && x < w - 2) { c.plot(x, 1, ink) }
        return c.buffer
    }

    /// The ball is below the rim between the basket's walls (Ballistics' basket, for a toss headed in).
    static func insideBasket(_ p: SIMD3<Float>, _ toss: Ballistics.Toss?) -> Bool {
        let b = Ballistics.Params.standard
        guard toss?.isIn == true || (toss?.rimHits ?? 0) > 0 else { return false }
        return abs(p.y - b.basketD) <= b.rimRadius && p.z + b.radius < b.rimZ && abs(p.x - b.basketX) < b.rimRadius
    }
}

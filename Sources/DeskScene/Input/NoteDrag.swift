import DeskCore
import SpriteKit

/// A sticky note in hand (Erratum 31; a `DragController` like `BrushDrag` and `ClockHandDrag`). The note rides the
/// carry layer a pixel up over a 1-px neutral5 shadow, keeping the point it was grabbed by, and a 1-px
/// `Role.selection` ghost shows where it would rest: `PartitionLayout.snap` of where it is now.
///
/// - Let go over the wastebasket's mouth (its live `mouthRect`, 4 px more all round) and a note on the partition comes
///   off (`removeNote`): it balls up and falls in over four 12 fps frames and the toast says so (⌘Z puts it back). A
///   new note (peeled or torn) springs back instead.
/// - Let go with a ghost on show and it rests there: `moveNote` (which brings it to the front), or `addNote` /
///   `tearOffPage` for a new one.
/// - Anywhere else, or Esc, it springs back over six frames.
///
/// With Reduce Motion there is no lift, and the spring back and the crumple are instant. It needs frames only while
/// in hand or settling; the model changes only on the release.
class NoteDrag: DragController {
    enum Kind: Equatable {
        /// A note on the partition moves (or comes off).
        case move(NoteID)
        /// A new yellow note peeled off the cube.
        case peel
        /// The day's page torn off the pad: a cream note dated that day.
        case tear(DayKey)
    }

    enum Phase: Equatable {
        case carrying
        /// Flying home from `from` (canvas top-left), `t` in 0…1.
        case springing(from: SIMD2<Float>, t: Double)
        /// Balled up, falling from `from` into the basket at `to` (canvas centres), `t` seconds in.
        case crumpling(from: SIMD2<Float>, to: SIMD2<Float>, t: Double)
        case done
    }

    static let springFrames = 6.0
    static let crumpleFrames = 4
    /// How far the note is lifted over its shadow while in hand.
    static let lift = 1
    /// How far past the basket's mouth a release still drops a note in.
    static let mouthReach = 4

    let kind: Kind
    let colour: NoteColour
    unowned let context: SceneContext
    /// Canvas top-left the note springs back to (where it rested, or the cube or pad it came from).
    let home: ArtPoint
    /// The pixel it is held by, from its top-left (so it moves in whole pixels with the pointer's).
    let grab: ArtPoint
    private(set) var phase: Phase = .carrying
    private(set) var pointer: SIMD2<Float>
    /// Where a release now would rest the note (core px), if anywhere.
    private(set) var spot: ArtPoint?
    let image: PixelBuffer
    let node = SKSpriteNode()
    let ghost = SKSpriteNode()
    private let onFinish: () -> Void
    private let lift: Int
    /// Rows of the note on show from its top (a peel shows it coming off the cube); nil: all of it.
    var reveal: Int? {
        didSet { if reveal != oldValue, phase == .carrying { redraw() } }
    }

    /// Picks up a note drawn as `image` that rests (or came from) canvas `home`, held by its pixel `grab` with the
    /// pointer at `pointer`. `onFinish` runs once when it is home, resting or in the basket.
    init(kind: Kind, colour: NoteColour, image: PixelBuffer, home: ArtPoint, grab: ArtPoint, pointer: SIMD2<Float>,
         context: SceneContext, onFinish: @escaping () -> Void) {
        self.kind = kind
        self.colour = colour
        self.image = image
        self.home = home
        self.grab = grab
        self.pointer = pointer
        self.context = context
        self.onFinish = onFinish
        lift = context.reduceMotion ? 0 : Self.lift
        node.zPosition = CGFloat(RoomLayer.carry.rawValue * 1000 + 2)
        ghost.zPosition = CGFloat(RoomLayer.carry.rawValue * 1000 + 1)
        ghost.isHidden = true
        ghost.texture = TextureFactory.texture(Self.ghostImage)
        context.carryLayer.addChild(ghost)
        context.carryLayer.addChild(node)
        redraw()
        moved(to: pointer, mods: [])
    }

    var isFinished: Bool { phase == .done }
    var needsFrames: Bool { phase != .done }

    // MARK: DragController

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard phase == .carrying else { return }
        pointer = p
        place(topLeft(of: p))
        spot = overBasket(p) ? nil : snap(topLeft(of: p))
        if let spot {
            context.space.place(ghost, at: context.layout.rect(PartitionLayout.noteRect(at: spot)))
            ghost.isHidden = false
        } else {
            ghost.isHidden = true
        }
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard phase == .carrying else { return }
        moved(to: p, mods: mods)
        ghost.isHidden = true
        if overBasket(p) {
            if case let .move(id) = kind { return takeOff(id) }
            return springBack()
        }
        guard let spot, let s = context.state else { return springBack() }
        switch kind {
        case let .move(id):
            context.dispatch(.moveNote(id, to: spot))
        case .peel:
            let note = NewNote(id: s.memos.nextNoteID, text: "", colour: .yellow, at: spot)
            context.dispatch(.addNote(note, session: nil))
        case let .tear(day):
            context.dispatch(.tearOffPage(day, at: spot))
        }
        finish()
    }

    func cancelled() {
        guard phase == .carrying else { return }
        ghost.isHidden = true
        springBack()
    }

    func step(_ dt: Double) {
        switch phase {
        case .carrying, .done:
            break
        case let .springing(from, t):
            let next = t + dt * 60 / Self.springFrames
            if next >= 1 - 1e-9 { return finish() }
            phase = .springing(from: from, t: next)
            let e = Float(1 - (1 - next) * (1 - next))
            let to = SIMD2(Float(home.x), Float(home.y))
            place(from + (to - from) * e)
        case let .crumpling(from, to, t):
            let next = t + dt
            let frame = Int((next + 1e-9) / DecorAnimation.frameTime)
            if frame >= Self.crumpleFrames { return finish() }
            phase = .crumpling(from: from, to: to, t: next)
            // It falls: slow at first, fastest as it drops in.
            let u = Float(next / (DecorAnimation.frameTime * Double(Self.crumpleFrames)))
            showCrumple(frame, at: from + (to - from) * (u * u))
        }
    }

    /// Hard sleep or teardown: home (or in the basket) at once.
    func finishNow() {
        guard phase != .done else { return }
        finish()
    }

    // MARK: Geometry

    /// The note's canvas top-left with the pointer at `p`.
    func topLeft(of p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(Float(Int(p.x.rounded(.down)) - grab.x), Float(Int(p.y.rounded(.down)) - grab.y))
    }

    /// The valid resting spot (core px) nearest a note whose canvas top-left is `topLeft`.
    func snap(_ topLeft: SIMD2<Float>) -> ArtPoint? {
        guard let s = context.state else { return nil }
        let o = context.layout.coreOrigin
        return PartitionLayout.snap(ArtPoint(Int(topLeft.x.rounded()) - o.x, Int(topLeft.y.rounded()) - o.y), in: s)
    }

    /// The pixel at the middle of a note drawn as `image` (where a new one is held).
    static func middle(of image: PixelBuffer) -> ArtPoint { ArtPoint(image.width / 2, image.height / 2) }

    /// Whether `p` is over the upright wastebasket's mouth (a little past it all round).
    func overBasket(_ p: SIMD2<Float>) -> Bool {
        guard let basket = context.physics?.basket, basket.isUpright else { return false }
        let pixel = ArtPoint(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
        return basket.mouthRect.insetBy(-Self.mouthReach, -Self.mouthReach).contains(pixel)
    }

    // MARK: Endings

    /// Into the wastebasket: the note comes off now, and balls up on its way in.
    private func takeOff(_ id: NoteID) {
        context.dispatch(.removeNote(id))
        context.toast(.noteRemoved)
        guard !context.reduceMotion, let basket = context.physics?.basket else { return finish() }
        let mouth = basket.mouthRect
        let tl = topLeft(of: pointer)
        let from = tl + SIMD2(Float(image.width) / 2, Float(image.height) / 2)
        phase = .crumpling(from: from, to: SIMD2(Float(mouth.midX), Float(mouth.maxY)), t: 0)
        showCrumple(0, at: from)
    }

    private func springBack() {
        // With Reduce Motion the note is home at once.
        if context.reduceMotion { return finish() }
        phase = .springing(from: topLeft(of: pointer), t: 0)
    }

    /// Done: the sprites go, and the element shows the note where the model has it.
    func finish() {
        guard phase != .done else { return }
        phase = .done
        node.removeFromParent()
        ghost.removeFromParent()
        onFinish()
    }

    // MARK: Drawing

    /// The note as carried: `reveal` rows of it, lifted over its 1-px shadow.
    private func redraw() {
        let rows = min(image.height, max(1, reveal ?? image.height))
        let shown = rows < image.height ? image.cropped(to: ArtRect(0, 0, image.width, rows)) : image
        var c = PixelCanvas(width: shown.width + 1, height: shown.height + 1 + lift)
        c.blit(PixelText.silhouette(shown, Self.shadowInk), at: ArtPoint(1, 1 + lift))
        c.blit(shown, at: .zero)
        node.texture = TextureFactory.texture(c.buffer)
        node.size = CGSize(width: CGFloat(c.width) * ArtSpace.unitsPerPixel,
                           height: CGFloat(c.height) * ArtSpace.unitsPerPixel)
        carriedSize = c.size
    }

    private var carriedSize = ArtSize(1, 1)

    /// Places the carried note so its resting top-left is at canvas `p` (lifted by `lift`).
    private func place(_ p: SIMD2<Float>) {
        let origin = ArtPoint(Int(p.x.rounded()), Int(p.y.rounded()) - lift)
        context.space.place(node, at: ArtRect(origin: origin, size: carriedSize))
    }

    private func showCrumple(_ frame: Int, at centre: SIMD2<Float>) {
        let ball = PartitionArt.noteCrumple(colour, frame: frame).image
        node.texture = TextureFactory.texture(ball)
        let origin = ArtPoint(Int(centre.x.rounded()) - ball.width / 2, Int(centre.y.rounded()) - ball.height / 2)
        context.space.place(node, at: ArtRect(origin: origin, size: ball.size))
    }

    static let shadowInk = Ink.neutral5

    /// The 1-px outline of a note where it would rest.
    static let ghostImage: PixelBuffer = {
        var c = PixelCanvas(width: PartitionLayout.noteSize.w, height: PartitionLayout.noteSize.h)
        c.roundedRectStroke(c.bounds, radius: 1, Role.selection)
        return c.buffer
    }()
}

/// Today's page torn off the daily memo pad (Erratum 31): the page curls up off the pad for three 12 fps frames
/// (`PartitionArt.padPeel`) while a cream note, dated that day and holding the page's text, comes away in the hand
/// (a `NoteDrag`). Let go on the felt and the page becomes that note (`tearOffPage`: the text moves, the page goes
/// blank); elsewhere it springs back to the pad and nothing changes.
final class PageTear: NoteDrag {
    private let curl = SKSpriteNode()
    private var animation: DecorAnimation?
    /// Canvas top-left of the curl frames (over the pad's page).
    private let curlOrigin: ArtPoint

    init(day: DayKey, image: PixelBuffer, pad: ArtRect, pointer: SIMD2<Float>, context: SceneContext,
         onFinish: @escaping () -> Void) {
        curlOrigin = pad.origin + PartitionArt.padPeelOrigin
        super.init(kind: .tear(day), colour: .cream, image: image, home: ArtPoint(pad.x + 4, pad.y + 14),
                   grab: Self.middle(of: image), pointer: pointer, context: context, onFinish: onFinish)
        curl.zPosition = context.placementZ("partition.pad") + 0.75
        curl.isHidden = true
        context.carryLayer.addChild(curl)
        if !context.reduceMotion {
            animation = DecorAnimation(count: 3)
            showCurl(0)
        }
    }

    override var needsFrames: Bool { super.needsFrames || animation != nil }

    override func step(_ dt: Double) {
        super.step(dt)
        guard var a = animation else { return }
        a.advance(dt)
        if a.isFinished {
            animation = nil
            curl.isHidden = true
        } else {
            animation = a
            showCurl(a.index)
        }
    }

    override func finish() {
        animation = nil
        curl.removeFromParent()
        super.finish()
    }

    private func showCurl(_ frame: Int) {
        let image = PartitionArt.padPeel(frame).image
        curl.texture = TextureFactory.texture(image)
        context.space.place(curl, at: ArtRect(origin: curlOrigin, size: image.size))
        curl.isHidden = false
    }
}

/// A new sticky note peeled off the cube (Erratum 31): a yellow note comes away in the hand over three 12 fps frames
/// (a third of it more each frame) and is a `NoteDrag` from then on. Let go on the felt and it sticks there
/// (`addNote`); elsewhere it springs back onto the cube and nothing changes.
final class CubePeel: NoteDrag {
    private var animation: DecorAnimation?

    init(image: PixelBuffer, cube: ArtRect, pointer: SIMD2<Float>, context: SceneContext,
         onFinish: @escaping () -> Void) {
        let home = ArtPoint(cube.midX - image.width / 2, cube.minY - image.height / 2)
        super.init(kind: .peel, colour: .yellow, image: image, home: home, grab: Self.middle(of: image),
                   pointer: pointer, context: context, onFinish: onFinish)
        if !context.reduceMotion {
            animation = DecorAnimation(count: 3)
            reveal = image.height / 3
        }
    }

    override var needsFrames: Bool { super.needsFrames || animation != nil }

    override func step(_ dt: Double) {
        super.step(dt)
        guard var a = animation else { return }
        a.advance(dt)
        if a.isFinished {
            animation = nil
            reveal = nil
        } else {
            animation = a
            reveal = image.height * (a.index + 1) / 3
        }
    }
}

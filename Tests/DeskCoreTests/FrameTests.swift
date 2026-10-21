import Foundation
import Testing
@testable import DeskCore

/// The picture frame (Erratum 33): the photo's geometry in the framed print, the `FramePhoto` value and its `rows`,
/// which tokens can hang, `frame.json`, the reducer and the journal, the menus, the room plan and the walls, and the
/// words. (DeskCoreTests sees DeskCore and DeskPixels only, so the toasts' English is spelled out here; the
/// `ToastKey.english` ↔ table check is KoreanFitTests'.)
@Suite("Picture frame (Erratum 33)")
struct FrameTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    static let sample = FramePhoto.sample
    /// A second photo: solid blue3.
    static let blue = FramePhoto(PixelBuffer(width: 26, height: 34, fill: Ink.blue3.color))!
    /// The MBA layout `ArtCatalog.room()` builds.
    static let mba = DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2, topInsetPt: 33)
    static let day = WallTime(year: 2026, month: 10, day: 18, hour: 10, minute: 0)

    static func isApolloOpaque(_ b: PixelBuffer) -> Bool {
        b.pixels.allSatisfy { Apollo.index(of: $0) != nil }
    }

    // MARK: Geometry

    @Test("Hung, the photo fills the 26×34 window; the oak frame and mat are the print's")
    func photoGeometry() {
        let size = ArtSize(32, 40)
        let window = DecorArt.photoWindow(in: size)
        #expect(window == ArtRect(3, 3, 26, 34))
        #expect(window.size == FramePhoto.size)
        let printSprite = DecorArt.frame(size)
        let hungSprite = DecorArt.frame(size, photo: Self.sample.image)
        let print = printSprite.image, hung = hungSprite.image
        #expect(print.size == size && hung.size == size)
        var outsideDiffers = 0, insideDiffers = 0
        for y in 0..<size.h {
            for x in 0..<size.w {
                if window.contains(ArtPoint(x, y)) {
                    if hung[x, y] != Self.sample.image[x - 3, y - 3] { insideDiffers += 1 }
                } else if hung[x, y] != print[x, y] {
                    outsideDiffers += 1
                }
            }
        }
        #expect(outsideDiffers == 0, "every pixel outside the window is the print's")
        #expect(insideDiffers == 0, "every pixel inside the window is the photo's")
        // The 1-px mat ring: neutral9 left, right and top; the mat's bottom row stays neutral8.
        #expect(hung[2, 10] == Ink.neutral9.color && hung[29, 10] == Ink.neutral9.color)
        #expect(hung[10, 2] == Ink.neutral9.color && hung[10, 37] == Ink.neutral8.color)
        #expect(printSprite.name == "decor.frame" && hungSprite.name == "decor.frame.photo")
        #expect(Self.isApolloOpaque(print) && Self.isApolloOpaque(hung))
        #expect(print != hung)
    }

    @Test("A photo of another size, or a frame of another size, gives the print")
    func photoSizeMismatch() {
        let narrow = PixelBuffer(width: 25, height: 34, fill: Ink.blue3.color)
        let a = DecorArt.frame(ArtSize(32, 40), photo: narrow)
        #expect(a.name == "decor.frame" && a.image == DecorArt.frame(ArtSize(32, 40)).image)
        let b = DecorArt.frame(ArtSize(30, 38), photo: Self.sample.image)
        #expect(b.name == "decor.frame" && b.image == DecorArt.frame(ArtSize(30, 38)).image)
        // Through `sprite`, the photo reaches only the frame.
        let frame = WallDecor(.frame, ArtRect(10, 10, 32, 40))
        #expect(DecorArt.sprite(frame, photo: Self.sample.image).name == "decor.frame.photo")
        #expect(DecorArt.sprite(frame).name == "decor.frame")
        let shelf = WallDecor(.shelf, ArtRect(10, 10, 92, 36))
        #expect(DecorArt.sprite(shelf, photo: Self.sample.image) == DecorArt.sprite(shelf))
    }

    // MARK: FramePhoto

    @Test("A photo is exactly 26×34 opaque Apollo pixels; its digest and description")
    func photoValidation() {
        #expect(FramePhoto(PixelBuffer(width: 26, height: 34, fill: Ink.blue3.color)) != nil)
        #expect(FramePhoto(PixelBuffer(width: 25, height: 34, fill: Ink.blue3.color)) == nil)
        #expect(FramePhoto(PixelBuffer(width: 26, height: 35, fill: Ink.blue3.color)) == nil)
        var clear = PixelBuffer(width: 26, height: 34, fill: Ink.blue3.color)
        clear[4, 5] = .clear
        #expect(FramePhoto(clear) == nil, "one clear pixel")
        var foreign = PixelBuffer(width: 26, height: 34, fill: Ink.blue3.color)
        foreign[20, 30] = RGBA8(1, 2, 3, 255)
        #expect(Apollo.index(of: RGBA8(1, 2, 3, 255)) == nil)
        #expect(FramePhoto(foreign) == nil, "one off-palette pixel")
        var half = PixelBuffer(width: 26, height: 34, fill: Ink.blue3.color)
        half[0, 0] = RGBA8(Ink.blue3.color.r, Ink.blue3.color.g, Ink.blue3.color.b, 128)
        #expect(FramePhoto(half) == nil, "one translucent pixel")
        // The sample passes, and is a picture (more than one colour).
        #expect(FramePhoto(Self.sample.image) == Self.sample)
        #expect(Self.sample.image.size == FramePhoto.size && Set(Self.sample.image.pixels).count > 4)
        // Digest: 16 lower-case hex digits, equal for equal photos, different for different ones.
        let d = Self.sample.digest
        #expect(d.count == 16 && d.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(d == FramePhoto.digest(Self.sample.image) && d == FramePhoto(Self.sample.image)!.digest)
        #expect(d != Self.blue.digest)
        let text = "\(Self.sample)"
        #expect(text.hasPrefix("photo ") && !text.contains("\n") && text == "photo \(d)")
    }

    @Test("rows: 34 strings of 26 alphabet characters round-trip; any other shape or character is refused")
    func rows() {
        let p = Self.sample
        let rows = p.rows
        #expect(rows.count == 34 && rows.allSatisfy { $0.count == 26 })
        #expect(FramePhoto(rows: rows) == p)
        #expect(FramePhoto.alphabet.count == Apollo.count && Set(FramePhoto.alphabet).count == Apollo.count)
        // Index 0 is "0", index 45 is "J".
        var b = PixelBuffer(width: 26, height: 34, fill: Apollo.colors[0])
        b[1, 0] = Apollo.colors[45]
        b[2, 0] = Apollo.colors[10]
        let q = FramePhoto(b)!
        #expect(q.rows[0].hasPrefix("0Ja0") && q.rows[1] == String(repeating: "0", count: 26))
        #expect(FramePhoto(rows: q.rows) == q)
        #expect(FramePhoto(rows: Array(repeating: String(repeating: "J", count: 26), count: 34))?.image
            == PixelBuffer(width: 26, height: 34, fill: Ink.neutral9.color))
        // 33 rows, a 25-character row, a 27-character row, or a "?" are not a photo.
        #expect(FramePhoto(rows: Array(rows.prefix(33))) == nil)
        #expect(FramePhoto(rows: rows + [rows[0]]) == nil)
        var short = rows
        short[5] = String(short[5].dropLast())
        #expect(FramePhoto(rows: short) == nil)
        var long = rows
        long[5] += "0"
        #expect(FramePhoto(rows: long) == nil)
        var odd = rows
        odd[7] = "?" + odd[7].dropFirst()
        #expect(odd[7].count == 26 && FramePhoto(rows: odd) == nil)
        var upper = rows
        upper[0] = "K" + upper[0].dropFirst()
        #expect(FramePhoto(rows: upper) == nil, "K is past index 45")
    }

    @Test("Which tokens can hang: a picture that is local, not an alias and not a package")
    func refusal() {
        func meta(_ kind: FileKind, alias: Bool = false, package: Bool = false, dataless: Bool = false) -> TokenMeta {
            TokenMeta(name: "p.png", kind: kind, isPackage: package, isDataless: dataless, isAlias: alias)
        }
        #expect(FramePhoto.refusal(for: meta(.image)) == nil)
        #expect(FramePhoto.refusal(for: meta(.screenshot)) == nil)
        #expect(FramePhoto.refusal(for: meta(.text)) == .notAPhoto)
        #expect(FramePhoto.refusal(for: meta(.folder)) == .notAPhoto)
        #expect(FramePhoto.refusal(for: meta(.pdf)) == .notAPhoto)
        #expect(FramePhoto.refusal(for: meta(.image, alias: true)) == .notAPhoto)
        #expect(FramePhoto.refusal(for: meta(.image, package: true)) == .notAPhoto)
        #expect(FramePhoto.refusal(for: meta(.image, dataless: true)) == .photoInCloud)
        #expect(FramePhoto.refusal(for: meta(.text, dataless: true)) == .notAPhoto, "not a photo comes first")
    }

    // MARK: frame.json

    /// Every key of a JSON value, nested ones included.
    static func keys(_ object: Any) -> [String] {
        if let d = object as? [String: Any] { return d.keys.sorted() + d.values.flatMap { keys($0) } }
        if let a = object as? [Any] { return a.flatMap { keys($0) } }
        return []
    }

    @Test("frame.json round-trips the photo; keys sorted; no file name, path or URL; no photo, no key")
    func documentRoundTrip() throws {
        let data = try FrameDocument(photo: Self.sample, savedAt: F.t0).encoded()
        let doc = try FrameDocument.decode(data)
        #expect(doc.photo == Self.sample && doc.savedAt == F.t0 && doc.schema == 1 && doc.app == DeskCore.version)
        #expect(try FrameDocument.decode(doc.encoded()) == doc)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"schema\" : 1"))
        let order = ["\"app\"", "\"photo\"", "\"rows\"", "\"size\"", "\"savedAt\"", "\"schema\""]
            .map { text.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        #expect(order.compactMap { $0 }.sorted() == order.compactMap { $0 }, "keys are sorted")
        let object = try JSONSerialization.jsonObject(with: data)
        let keys = Self.keys(object)
        #expect(Set(keys) == ["app", "photo", "rows", "size", "savedAt", "schema"])
        #expect(!keys.contains { k in ["path", "name", "url"].contains { k.lowercased().contains($0) } })
        let photo = try #require((object as? [String: Any])?["photo"] as? [String: Any])
        #expect(photo["size"] as? [Int] == [26, 34] && photo["rows"] as? [String] == Self.sample.rows)
        // No photo: no "photo" key, and it decodes to none.
        let none = try FrameDocument(photo: nil, savedAt: F.t0).encoded()
        #expect(!String(decoding: none, as: UTF8.self).contains("\"photo\""))
        #expect(try FrameDocument.decode(none).photo == nil)
    }

    @Test("frame.json decodes leniently per field; no schema and a newer schema are refused")
    func documentLenient() throws {
        func decode(_ s: String) throws -> FrameDocument { try FrameDocument.decode(Data(s.utf8)) }
        let bad = try decode(#"{"schema":1,"photo":{"size":[26,34],"rows":["x"]}}"#)
        #expect(bad.photo == nil && bad.schema == 1)
        #expect(try decode(#"{"schema":1,"app":5}"#).app == "")
        #expect(try decode(#"{"schema":1,"savedAt":"yesterday"}"#).savedAt == nil)
        let rows = Self.sample.rows.map { "\"\($0)\"" }.joined(separator: ",")
        #expect(try decode(#"{"schema":1,"photo":{"size":[25,34],"rows":["# + rows + "]}}").photo == nil)
        #expect(try decode(#"{"schema":1,"photo":{"size":[26,34],"rows":["# + rows + "]}}").photo == Self.sample)
        #expect(try decode(#"{"schema":1,"photo":"sunset"}"#).photo == nil)
        #expect(throws: Migrations.Failure.missingSchema) { try decode("{}") }
        #expect(throws: Migrations.Failure.newerSchema(2)) { try decode(#"{"schema":2}"#) }
        #expect(throws: Migrations.Failure.notAnObject) { try decode("[1]") }
    }

    // MARK: Reducer and journal

    @Test("Hang and Remove: the photo changes, the loop wakes, and nothing touches a file or persists desk.json")
    func reducer() {
        var s = F.mirrored(["a"])
        var all: [Effect] = []
        let hang = reduce(&s, .hangPhoto(Self.sample), env)
        #expect(s.framePhoto == Self.sample && hang == [.wakeLoop])
        let again = reduce(&s, .hangPhoto(Self.sample), env)
        #expect(again.isEmpty && s.framePhoto == Self.sample)
        let other = reduce(&s, .hangPhoto(Self.blue), env)
        #expect(s.framePhoto == Self.blue && other == [.wakeLoop])
        let remove = reduce(&s, .removePhoto, env)
        #expect(s.framePhoto == nil && remove == [.wakeLoop])
        let removeAgain = reduce(&s, .removePhoto, env)
        #expect(removeAgain.isEmpty && s.framePhoto == nil)
        all = hang + again + other + remove + removeAgain
        #expect(!all.contains { $0.touchesFiles || $0.mutatesFiles })
        #expect(!all.contains(.persist))
        #expect(!DeskAction.hangPhoto(Self.sample).isRequest && !DeskAction.removePhoto.isRequest)
        #expect(s.violations().isEmpty)
    }

    @Test("Undo and redo bring the photo back as it was, with labels, and no file effect")
    func undo() {
        var s = F.mirrored(["a"])
        var journal = UndoJournal()
        var all: [Effect] = []
        func run(_ a: DeskAction) -> [Effect] {
            let e = Reducer.reduce(&s, journal: &journal, a, env)
            all += e
            return e
        }
        _ = run(.hangPhoto(Self.sample))
        #expect(journal.undoLabel == "Hang Photo" && s.framePhoto == Self.sample)
        #expect(run(.undo) == [.persist, .wakeLoop] && s.framePhoto == nil)
        #expect(journal.redoLabel == "Hang Photo")
        #expect(run(.redo) == [.persist, .wakeLoop] && s.framePhoto == Self.sample)
        // Another photo over it: undo brings the first back.
        _ = run(.hangPhoto(Self.blue))
        #expect(s.framePhoto == Self.blue && journal.undoLabel == "Hang Photo")
        _ = run(.undo)
        #expect(s.framePhoto == Self.sample)
        // Remove: its own entry; undo hangs the photo again.
        _ = run(.removePhoto)
        #expect(journal.undoLabel == "Remove Photo" && s.framePhoto == nil)
        _ = run(.undo)
        #expect(s.framePhoto == Self.sample)
        // A no-op is not journaled.
        let depth = journal.undoStack.count
        _ = run(.hangPhoto(Self.sample))
        #expect(journal.undoStack.count == depth)
        #expect(UndoJournal.label(for: .hangPhoto(Self.sample)) == "Hang Photo")
        #expect(UndoJournal.label(for: .removePhoto) == "Remove Photo")
        #expect(UndoJournal.coalesceKey(for: .hangPhoto(Self.sample)) == nil)
        #expect(!all.contains { $0.touchesFiles || $0.mutatesFiles })
    }

    @Test("The photo is in the undo snapshot and is element state, but never in desk.json")
    func snapshotAndDocument() throws {
        var s = F.mirrored(["a", "b"])
        s.framePhoto = Self.sample
        #expect(LayoutSnapshot(s).framePhoto == Self.sample)
        #expect(LayoutSnapshot(F.mirrored(["a"])).framePhoto == nil)
        // Another folder's layout is adopted: the photo stays.
        var adopting = s
        adopting.adoptLayout(of: F.mirrored(["x", "y", "z"]))
        #expect(adopting.framePhoto == Self.sample)
        var other = F.mirrored(["x"])
        other.framePhoto = Self.blue
        adopting.adoptLayout(of: other)
        #expect(adopting.framePhoto == Self.sample, "the adopted layout's photo is not taken")
        // desk.json neither stores nor restores it.
        let data = try DeskDocument(state: s, savedAt: F.t0).encoded()
        #expect(try DeskDocument.decode(data).makeState().framePhoto == nil)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("framePhoto") && !text.contains("rows") && !text.contains("photo"))
        var plain = s
        plain.framePhoto = nil
        #expect(try DeskDocument(state: plain, savedAt: F.t0).encoded() == data, "desk.json is the same with or without")
    }

    // MARK: Menus

    @Test("The frame's menu; frame commands' actions and demo names; every title translates")
    func menus() {
        var s = F.mirrored(["a"])
        #expect(MenuSpec.frame(s).ids == ["choosePhoto"])
        #expect(MenuSpec.frame(s).item("choosePhoto")?.command == .choosePhoto)
        #expect(MenuSpec.frame(s).item("choosePhoto")?.title == "Choose Photo…")
        var hung = s
        hung.framePhoto = Self.sample
        let withPhoto = MenuSpec.frame(hung)
        #expect(withPhoto.ids == ["choosePhoto", "removePhoto"])
        #expect(withPhoto.item("removePhoto")?.command == .removePhoto && withPhoto.item("removePhoto")?.isEnabled == true)
        #expect(MenuCommand.choosePhoto.action(s) == nil)
        #expect(MenuCommand.hangInFrame(F.key(1)).action(s) == nil)
        if case .removePhoto? = MenuCommand.removePhoto.action(hung) {} else { Issue.record("removePhoto is the model's") }
        #expect(MenuCommand.choosePhoto.demoName == "choosePhoto")
        #expect(MenuCommand.hangInFrame(F.key(1)).demoName == "hangInFrame")
        #expect(MenuCommand.removePhoto.demoName == "removePhoto")
        #expect(StowCatalog.stowID(forElement: "frame") == .wallShelf)
        // Titles: the frame's, with and without a photo, and an image token's (L10nTests.menusCovered builds only
        // text tokens). None carries a file name except Quick Look's, through its template.
        var titles: Set<String> = []
        func collect(_ spec: MenuSpec) {
            for id in spec.ids {
                if let item = spec.item(id), !item.isSeparator { titles.insert(item.title) }
            }
        }
        collect(MenuSpec.frame(s))
        collect(MenuSpec.frame(hung))
        s = F.mirrored(["p.png"], kind: .image)
        let token = MenuSpec.token([F.key(1)], s)
        #expect(token.item("hangInFrame") != nil)
        collect(token)
        #expect(titles.isSuperset(of: ["Choose Photo…", "Remove Photo", "Hang in Picture Frame"]))
        for t in titles.sorted() {
            #expect(L10n.knows(t), "\(t) is not in the table")
            #expect(L10n.tr(t, .ko) != t || t.hasPrefix("HDMI "), "\(t) is not translated")
        }
    }

    @Test("Hang in Picture Frame: one local picture while the frame is out, enabled while connected")
    func tokenMenu() {
        var s = F.mirrored(["a.png"], kind: .image)
        let m = MenuSpec.token([F.key(1)], s)
        #expect(m.items.compactMap { $0.isSeparator ? nil : $0.id }
            == ["open", "quickLook", "reveal", "copy", "hangInFrame", "moveTo", "trash"])
        #expect(m.item("hangInFrame")?.command == .hangInFrame(F.key(1)))
        #expect(m.item("hangInFrame")?.title == "Hang in Picture Frame" && m.item("hangInFrame")?.isEnabled == true)
        // The rest of the menu is as for any token.
        #expect(m.items.filter(\.isSeparator).count == 2 && m.items[4].id == "hangInFrame" && m.items[5].isSeparator)
        // A screenshot hangs too.
        let shot = F.mirrored(["Screenshot.png"], kind: .screenshot)
        #expect(MenuSpec.token([F.key(1)], shot).item("hangInFrame")?.command == .hangInFrame(F.key(1)))
        // Not for two pictures, a text file, an alias, an iCloud placeholder, or while the wall shelf is put away.
        let two = F.mirrored(["a.png", "b.png"], kind: .image)
        #expect(MenuSpec.token([F.key(1), F.key(2)], two).item("hangInFrame") == nil)
        #expect(MenuSpec.token([F.key(1)], two).item("hangInFrame") != nil)
        let text = F.mirrored(["a.txt"])
        #expect(MenuSpec.token([F.key(1)], text).item("hangInFrame") == nil)
        #expect(MenuSpec.token([F.key(1)], text).items.compactMap { $0.isSeparator ? nil : $0.id }
            == ["open", "quickLook", "reveal", "copy", "moveTo", "trash"])
        var alias = s
        alias.tokens.updateMeta(F.key(1), TokenMeta(name: "a.png", kind: .image, isAlias: true))
        #expect(MenuSpec.token([F.key(1)], alias).item("hangInFrame") == nil)
        var cloud = s
        cloud.tokens.updateMeta(F.key(1), TokenMeta(name: "a.png", kind: .image, isDataless: true))
        #expect(MenuSpec.token([F.key(1)], cloud).item("hangInFrame") == nil)
        var away = s
        away.stowed = [.wallShelf]
        #expect(MenuSpec.token([F.key(1)], away).item("hangInFrame") == nil)
        away.stowed = [.wallArt, .pegboard]
        #expect(MenuSpec.token([F.key(1)], away).item("hangInFrame") != nil, "only the wall shelf takes the frame")
        // A key no longer on the desk: no item.
        #expect(MenuSpec.token([F.key(9)], s).item("hangInFrame") == nil)
        // Not connected: shown, disabled.
        for access in [DesktopAccess.notConnected, .connecting, .denied] {
            s.access = access
            let off = MenuSpec.token([F.key(1)], s).item("hangInFrame")
            #expect(off != nil && off?.isEnabled == false, "\(access)")
        }
    }

    // MARK: Room and walls

    @Test("The room plan: the frame's placement shows the photo; nothing else changes")
    func roomPlan() {
        let layout = LayoutSolver.solve(display: Self.mba)
        let plain = RoomState(time: Self.day)
        var photo = plain
        photo.framePhoto = Self.sample.image
        let a = RoomPlan.placements(layout, plain), b = RoomPlan.placements(layout, photo)
        #expect(a.map(\.id) == b.map(\.id))
        let frames = a.filter { $0.id.hasPrefix("decor.frame.") }
        #expect(frames.count == 1)
        var changed: [String] = []
        for (p, q) in zip(a, b) {
            #expect(p.rect == q.rect && p.layer == q.layer, "\(p.id)")
            if p.image != q.image { changed.append(p.id) }
            guard p.id.hasPrefix("decor.frame.") else { continue }
            let hung = DecorArt.frame(p.rect.size, photo: Self.sample.image)
            #expect(q.sprite == hung && q.sprite.name == "decor.frame.photo")
            #expect(p.sprite == DecorArt.frame(p.rect.size))
        }
        #expect(changed == frames.map(\.id))
        // Put away with the wall shelf: no frame either way.
        var away = plain
        away.stowed = [.wallShelf]
        var awayPhoto = photo
        awayPhoto.stowed = [.wallShelf]
        #expect(!RoomPlan.placements(layout, away).contains { $0.id.hasPrefix("decor.frame.") })
        #expect(!RoomPlan.placements(layout, awayPhoto).contains { $0.id.hasPrefix("decor.frame.") })
        #expect(RoomPlan.placements(layout, away).map(\.id) == RoomPlan.placements(layout, awayPhoto).map(\.id))
        // `only: ["decor"]` rebuilds it too.
        #expect(RoomPlan.placements(layout, photo, only: ["decor"]).contains { $0.sprite.name == "decor.frame.photo" })
        // Lit, day and night, the room stays Apollo-only, and the photo dims with it.
        let lit = RoomPlan.render(layout, photo)
        #expect(Self.isApolloOpaque(lit))
        var night = photo
        night.time = WallTime(year: 2026, month: 10, day: 18, hour: 22, minute: 0)
        #expect(Self.isApolloOpaque(RoomPlan.render(layout, night)))
        #expect(lit != RoomPlan.render(layout, plain))
    }

    @Test("Other displays' walls: their framed print shows the photo, and takes drops at its rect")
    func walls() throws {
        let grid = PixelGrid(display: Self.mba)
        let layout = LayoutSolver.solve(grid: grid)
        let plain = RoomState(time: Self.day)
        var photo = plain
        photo.framePhoto = Self.sample.image
        var blue = plain
        blue.framePhoto = Self.blue.image
        let with = WallArt.compose(layout, photo), without = WallArt.compose(layout, plain)
        #expect(with != without)
        let rect = try #require(WallArt.frameRect(layout))
        let window = DecorArt.photoWindow(in: rect.size).offsetBy(rect.x, rect.y)
        #expect(with.cropped(to: window) == Self.sample.image)
        #expect(without.cropped(to: window) != Self.sample.image)
        // Only the frame's rect changes.
        for y in 0..<with.height {
            for x in 0..<with.width where !rect.contains(ArtPoint(x, y)) && with[x, y] != without[x, y] {
                Issue.record("(\(x), \(y)) outside the frame changed")
            }
        }
        let signatures = [plain, photo, blue].map { WallArt.signature(grid: grid, state: $0) }
        #expect(Set(signatures).count == 3)
        #expect(WallArt.signature(grid: grid, state: photo) == WallArt.signature(grid: grid, state: photo))
        let lit = WallArt.render(grid: grid, state: photo)
        #expect(Self.isApolloOpaque(lit) && lit != WallArt.render(grid: grid, state: plain))
        // frameRect is the `.frame` of the wall's decor, 32×40, and nil with the wall shelf away.
        let frames = WallArt.decor(layout).filter { $0.kind == .frame }
        #expect(frames.count == 1 && frames.first?.rect == rect && rect.size == ArtSize(32, 40))
        #expect(WallArt.frameRect(layout, stowed: [.wallShelf]) == nil)
        #expect(WallArt.frameRect(layout, stowed: [.wallArt, .stringLights]) == rect)
        // Put away, the wall shows neither the photo nor the print.
        var away = photo
        away.stowed = [.wallShelf]
        var awayPlain = plain
        awayPlain.stowed = [.wallShelf]
        #expect(WallArt.compose(layout, away) == WallArt.compose(layout, awayPlain))
        #expect(WallArt.signature(grid: grid, state: away) != WallArt.signature(grid: grid, state: photo))
    }

    // MARK: Words

    @Test("The frame's words in English and Korean")
    func words() {
        #expect(L10n.tr("Undo Hang Photo", .ko) == "실행 취소: 사진 걸기")
        #expect(L10n.tr("Undo Remove Photo", .ko) == "실행 취소: 사진 빼기")
        #expect(L10n.tr("Choose Photo…", .ko) == "사진 선택…")
        #expect(L10n.tr("Remove Photo", .ko) == "사진 빼기")
        #expect(L10n.tr("Hang in Picture Frame", .ko) == "사진 액자에 걸기")
        let toasts = [
            "That isn't a photo.", "One photo at a time.", "Download it from iCloud first.", "That photo can't be read.",
            "The photo can't be saved this time.",
        ]
        for t in toasts {
            #expect(L10n.knows(t), "\(t)")
            #expect(L10n.tr(t, .ko) != t, "\(t)")
            #expect(L10n.tr(t, .en) == t)
        }
        #expect(L10n.text(.pictureFrame, .en) == "Picture Frame" && L10n.text(.pictureFrame, .ko) == "사진 액자")
        #expect(L10n.text(.axFrameEmpty, .en) == "No photo" && L10n.text(.axFramePhoto, .en) == "Your photo")
        #expect(L10n.text(.panelHangPhoto, .ko) == "걸기")
    }
}

import Foundation

/// `frame.json`, schema 1 (Erratum 33): the photo hung in the picture frame, as its pixels (`FramePhoto.rows`), kept apart
/// from `desk.json` so it is the app's (not a mirrored folder's) and survives Reset Layout, folder switches and a
/// downgrade. `StateStore.loadFrame` / `saveFrame` read and write it. Keys are sorted; with no photo there is no `photo`
/// key. It never holds the photo's file, name or path. Decoding is lenient per field (a malformed photo is none); a newer
/// schema is refused, so a newer file is never overwritten.
public struct FrameDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int = FrameDocument.currentSchema
    public var app: String = DeskCore.version
    public var savedAt: Date?
    /// The photo hung; nil: the print.
    public var photo: FramePhoto?

    /// The document for `photo` (nil: the print), saved at `savedAt` by `app`.
    public init(photo: FramePhoto?, savedAt: Date, app: String = DeskCore.version) {
        self.app = app
        self.savedAt = savedAt
        self.photo = photo
    }

    /// A schema newer than this build's throws `Migrations.Failure.newerSchema` (the file is kept as it is); a missing one
    /// `Migrations.Failure.missingSchema`; then every field degrades on its own.
    public static func decode(_ data: Data) throws -> FrameDocument {
        let n = try Migrations.schema(of: data)
        guard n <= currentSchema else { throw Migrations.Failure.newerSchema(n) }
        return try DeskDocument.makeDecoder().decode(FrameDocument.self, from: data)
    }

    /// Pretty, key-sorted JSON (`DeskDocument.makeEncoder()`).
    public func encoded() throws -> Data {
        try DeskDocument.makeEncoder().encode(self)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case schema, app, savedAt, photo }

    /// The schema must be a number; every other field falls back on its own (an unreadable photo is none).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        app = c.lenient(.app, default: "")
        savedAt = c.lenient(.savedAt, default: nil)
        photo = c.lenient(.photo, default: nil)
    }

    /// `schema`, `app`, and `savedAt` and `photo` when present.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(app, forKey: .app)
        try c.encodeIfPresent(savedAt, forKey: .savedAt)
        try c.encodeIfPresent(photo, forKey: .photo)
    }
}

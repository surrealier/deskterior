import Foundation

/// Upgrades older `desk.json` files (DESIGN §13). Schema steps rewrite the JSON; layout steps clamp or re-map
/// coordinates when elements move between versions.
public enum Migrations {
    public static let currentSchema = 1
    public static let currentLayoutVersion = 1

    /// `schemaSteps[n]` turns a schema-`n` document into schema `n + 1`.
    public static let schemaSteps: [Int: @Sendable (Data) throws -> Data] = [:]
    /// `layoutSteps[n]` turns layout version `n` into `n + 1`.
    public static let layoutSteps: [Int: @Sendable (inout DeskDocument) -> Void] = [:]

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAnObject
        case missingSchema
        /// Written by a newer Deskterior; never downgraded or overwritten in place.
        case newerSchema(Int)
        case noStep(from: Int)

        public var description: String {
            switch self {
            case .notAnObject: "desk.json is not a JSON object"
            case .missingSchema: "desk.json has no schema number"
            case let .newerSchema(n): "desk.json uses schema \(n), newer than \(Migrations.currentSchema)"
            case let .noStep(n): "no migration from schema \(n)"
            }
        }
    }

    /// The schema number of a document.
    public static func schema(of data: Data) throws -> Int {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notAnObject }
        guard let n = object["schema"] as? Int else { throw Failure.missingSchema }
        return n
    }

    /// `data` upgraded to `currentSchema`.
    public static func migrate(_ data: Data) throws -> Data {
        var n = try schema(of: data)
        guard n <= currentSchema else { throw Failure.newerSchema(n) }
        var out = data
        while n < currentSchema {
            guard let step = schemaSteps[n] else { throw Failure.noStep(from: n) }
            out = try step(out)
            n += 1
        }
        return out
    }

    public static func migrateLayout(_ doc: inout DeskDocument) {
        while doc.layoutVersion < currentLayoutVersion {
            layoutSteps[doc.layoutVersion]?(&doc)
            doc.layoutVersion += 1
        }
    }
}

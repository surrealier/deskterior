import Testing
@testable import DeskCore

/// Decoding enforces the same invariants as the initializers (M1 review F14).
@Suite("Codable validation")
struct CodableValidationTests {
    @Test func projectionRoundTrips() throws {
        let p = DeskProjection(frontY: 200, k: 0.25)
        #expect(try TestSupport.decodeJSON(DeskProjection.self, TestSupport.encodeJSON(p)) == p)
        #expect(try TestSupport.decodeJSON(DeskProjection.self, #"{"frontY":232,"k":0.5}"#) == .standard)
    }

    @Test func projectionRejectsANonPositiveDepthFactor() {
        for json in [#"{"frontY":232,"k":0}"#, #"{"frontY":232,"k":-0.5}"#, #"{"frontY":232}"#] {
            #expect(throws: DecodingError.self, "\(json)") { try TestSupport.decodeJSON(DeskProjection.self, json) }
        }
    }

    @Test func inkRoundTrips() throws {
        for raw in 0...UInt8(Apollo.count) {
            let ink = Ink(raw: raw)
            #expect(try TestSupport.decodeJSON(Ink.self, TestSupport.encodeJSON(ink)) == ink)
        }
        #expect(try TestSupport.encodeJSON(Ink.blue3) == #"{"raw":4}"#)
        #expect(try TestSupport.decodeJSON(Ink.self, #"{"raw":46}"#) == .neutral9)
    }

    @Test func inkRejectsOutOfRangeRaw() {
        for json in [#"{"raw":47}"#, #"{"raw":200}"#, #"{"raw":-1}"#, #"{}"#] {
            #expect(throws: DecodingError.self, "\(json)") { try TestSupport.decodeJSON(Ink.self, json) }
        }
    }
}

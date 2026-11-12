import DeskCore
import Foundation
import Testing

@Suite("SHA-1 (portable)")
struct SHA1Tests {
    @Test("FIPS 180 vectors, across the 55/56/64-byte padding edges")
    func vectors() {
        #expect(SHA1.hex(Data()) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(SHA1.hex(Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(SHA1.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        #expect(SHA1.hex(Data("The quick brown fox jumps over the lazy dog".utf8))
            == "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
        #expect(SHA1.hex(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }
}

@Suite("File kinds by extension (portable)")
struct FileKindTableTests {
    @Test("Extensions map to kinds in any case; folders, screenshots and unknown files")
    func classify() {
        #expect(FileKindTable.kind(forExtension: "PDF") == .pdf)
        #expect(FileKindTable.kind(forExtension: "hwpx") == .doc)
        #expect(FileKindTable.kind(forExtension: "exe") == .app)
        #expect(FileKindTable.kind(forExtension: "msi") == .dmg)
        #expect(FileKindTable.kind(forExtension: "nope") == .unknown)
        #expect(FileKindTable.classify(name: "Photos", isDirectory: true) == .folder)
        #expect(FileKindTable.classify(name: "Screenshot 2026-11-11 101010.png", isDirectory: false) == .screenshot)
        #expect(FileKindTable.classify(name: "스크린샷 2026-11-11.png", isDirectory: false) == .screenshot)
        #expect(FileKindTable.classify(name: "holiday.png", isDirectory: false) == .image)
        #expect(FileKindTable.classify(name: "holiday.png", isDirectory: false, isScreenCapture: true) == .screenshot)
        #expect(FileKindTable.classify(name: "README", isDirectory: false) == .unknown)
    }
}

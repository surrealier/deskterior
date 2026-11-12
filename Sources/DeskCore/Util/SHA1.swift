import Foundation

/// SHA-1 (FIPS 180-4) for cache keys and file names (`IconCache.key`, `StateStore.asideURL`): the same digests
/// CryptoKit's `Insecure.SHA1` gives, on platforms without CryptoKit (docs/WINDOWS.md WP5). Not for security.
public enum SHA1 {
    /// The 20-byte digest of `data`.
    public static func digest(_ data: Data) -> [UInt8] {
        var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }

        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let o = chunk + i * 4
                w[i] = UInt32(message[o]) << 24 | UInt32(message[o + 1]) << 16 | UInt32(message[o + 2]) << 8
                    | UInt32(message[o + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var (a, b, c, d, e) = h
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, rotl(b, 30), a, t)
            }
            h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
        }
        return [h.0, h.1, h.2, h.3, h.4].flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - $0 * 8)) } }
    }

    /// The digest as 40 lowercase hex digits.
    public static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(40)
        for b in digest(data) {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }
}

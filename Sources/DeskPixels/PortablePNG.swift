import DeskCore
import Foundation

/// PNG ⇄ `PixelBuffer` in plain Swift (zlib inflate and deflate included), for platforms without ImageIO.
///
/// - Decodes every standard PNG: bit depths 1–16, greyscale, RGB, palette (with `tRNS`), grey + alpha, RGBA, and
///   Adam7 interlacing. 16-bit samples keep their high byte. Colour-management chunks are ignored: Deskterior's
///   PNGs are sRGB already. Fully transparent pixels become `.clear`, as `PixelBuffer(cgImage:)` makes them.
/// - Encodes RGBA8, non-interlaced, adaptive row filters, one fixed-Huffman deflate block with LZ77 matches.
///
/// macOS keeps ImageIO (`PNGCodec`); `PNGCodecParityTests` checks this codec against it on every golden.
public enum PortablePNG {
    public enum DecodeError: Error, Equatable {
        case notPNG, truncated, badChunk(String), unsupported(String), badZlib(String), badFilter(UInt8)
    }

    // MARK: Encode

    /// PNG bytes for `b` (RGBA8, row 0 = top); empty `Data` for an empty buffer.
    public static func encode(_ b: PixelBuffer) -> Data {
        guard b.width > 0, b.height > 0 else { return Data() }
        let w = b.width, h = b.height, stride = w * 4
        var raw = [UInt8](repeating: 0, count: stride * h)
        b.withUnsafePixels { px in
            for i in 0..<(w * h) {
                let c = px[i]
                raw[i * 4] = c.r
                raw[i * 4 + 1] = c.g
                raw[i * 4 + 2] = c.b
                raw[i * 4 + 3] = c.a
            }
        }
        var filtered = [UInt8]()
        filtered.reserveCapacity((stride + 1) * h)
        var candidate = [UInt8](repeating: 0, count: stride)
        var best = [UInt8](repeating: 0, count: stride)
        for y in 0..<h {
            let row = y * stride, prev = (y - 1) * stride
            var bestType: UInt8 = 0
            var bestScore = Int.max
            for type in UInt8(0)...4 {
                var score = 0
                for x in 0..<stride {
                    let cur = raw[row + x]
                    let a = x >= 4 ? raw[row + x - 4] : 0
                    let up = y > 0 ? raw[prev + x] : 0
                    let ul = (y > 0 && x >= 4) ? raw[prev + x - 4] : 0
                    let v: UInt8
                    switch type {
                    case 0: v = cur
                    case 1: v = cur &- a
                    case 2: v = cur &- up
                    case 3: v = cur &- UInt8((Int(a) + Int(up)) / 2)
                    default: v = cur &- paeth(a, up, ul)
                    }
                    candidate[x] = v
                    score += abs(Int(Int8(bitPattern: v)))
                }
                if score < bestScore {
                    bestScore = score
                    bestType = type
                    swap(&best, &candidate)
                }
            }
            filtered.append(bestType)
            filtered.append(contentsOf: best)
        }

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = [UInt8]()
        ihdr.appendBigEndian(UInt32(w))
        ihdr.appendBigEndian(UInt32(h))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        appendChunk("IHDR", ihdr, to: &out)
        appendChunk("sRGB", [0], to: &out)
        appendChunk("IDAT", Zlib.compress(filtered), to: &out)
        appendChunk("IEND", [], to: &out)
        return out
    }

    // MARK: Decode

    /// Decodes PNG bytes into RGBA8; nil if `d` is not a PNG this codec reads.
    public static func decode(_ d: Data) -> PixelBuffer? {
        try? decodeOrThrow(d)
    }

    public static func decodeOrThrow(_ d: Data) throws(DecodeError) -> PixelBuffer {
        let bytes = [UInt8](d)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { throw .notPNG }

        var pos = 8
        var width = 0, height = 0, depth = 0, colorType = 0, interlace = 0
        var palette: [RGBA8] = []
        var transparency: [UInt8] = []
        var idat: [UInt8] = []
        var sawHeader = false
        while true {
            guard pos + 8 <= bytes.count else { throw .truncated }
            let length = Int(bytes.readBigEndian(at: pos))
            let type = String(decoding: bytes[(pos + 4)..<(pos + 8)], as: UTF8.self)
            let start = pos + 8
            guard length >= 0, start + length + 4 <= bytes.count else { throw .truncated }
            let body = bytes[start..<(start + length)]
            pos = start + length + 4 // skip the CRC: a damaged chunk shows up as bad zlib or bad sizes
            switch type {
            case "IHDR":
                guard length == 13 else { throw .badChunk(type) }
                width = Int(bytes.readBigEndian(at: start))
                height = Int(bytes.readBigEndian(at: start + 4))
                depth = Int(bytes[start + 8])
                colorType = Int(bytes[start + 9])
                guard bytes[start + 10] == 0, bytes[start + 11] == 0 else { throw .unsupported("compression or filter method") }
                interlace = Int(bytes[start + 12])
                sawHeader = true
            case "PLTE":
                guard length % 3 == 0 else { throw .badChunk(type) }
                palette = stride(from: start, to: start + length, by: 3).map { RGBA8(bytes[$0], bytes[$0 + 1], bytes[$0 + 2], 255) }
            case "tRNS":
                transparency = Array(body)
            case "IDAT":
                idat.append(contentsOf: body)
            case "IEND":
                break
            default:
                break
            }
            if type == "IEND" { break }
        }
        guard sawHeader, width > 0, height > 0, width <= 1 << 15, height <= 1 << 15 else { throw .badChunk("IHDR") }
        let channels: Int
        switch colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: throw .unsupported("colour type \(colorType)")
        }
        let allowed: Set<Int> = colorType == 0 ? [1, 2, 4, 8, 16] : colorType == 3 ? [1, 2, 4, 8] : [8, 16]
        guard allowed.contains(depth) else { throw .unsupported("bit depth \(depth) for colour type \(colorType)") }
        guard interlace == 0 || interlace == 1 else { throw .unsupported("interlace \(interlace)") }
        if colorType == 3 {
            guard !palette.isEmpty else { throw .badChunk("PLTE") }
            for (i, a) in transparency.enumerated() where i < palette.count { palette[i].a = a }
        }

        let data: [UInt8]
        do { data = try Zlib.decompress(idat) } catch { throw .badZlib("\(error)") }
        let bitsPerPixel = channels * depth
        let pixelBytes = max(1, bitsPerPixel / 8)
        var pixels = [RGBA8](repeating: .clear, count: width * height)
        var offset = 0

        // Adam7 passes: (x0, y0, dx, dy); a non-interlaced image is one pass over everything.
        let passes: [(Int, Int, Int, Int)] = interlace == 1
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)]
        for (x0, y0, dx, dy) in passes {
            let pw = (width - x0 + dx - 1) / dx, ph = (height - y0 + dy - 1) / dy
            guard pw > 0, ph > 0 else { continue }
            let rowBytes = (pw * bitsPerPixel + 7) / 8
            var prev = [UInt8](repeating: 0, count: rowBytes)
            var cur = [UInt8](repeating: 0, count: rowBytes)
            for py in 0..<ph {
                guard offset + 1 + rowBytes <= data.count else { throw .truncated }
                let filter = data[offset]
                for i in 0..<rowBytes { cur[i] = data[offset + 1 + i] }
                offset += 1 + rowBytes
                try unfilter(&cur, prev: prev, type: filter, bpp: pixelBytes)
                for px in 0..<pw {
                    pixels[(y0 + py * dy) * width + x0 + px * dx] = sample(
                        cur, px, depth: depth, channels: channels, colorType: colorType,
                        palette: palette, transparency: transparency
                    )
                }
                swap(&prev, &cur)
            }
        }
        return PixelBuffer(width: width, height: height, pixels: pixels)
    }

    // MARK: Alpha

    /// What drawing a straight-alpha colour into a premultiplied RGBA8 bitmap and reading it back gives: the round
    /// trip `PixelBuffer(cgImage:)` makes on macOS (same formulas as `CGBridge`).
    @inline(__always)
    public static func throughPremultiplied(_ c: RGBA8) -> RGBA8 {
        switch c.a {
        case 0: return .clear
        case 255: return c
        default:
            let a = UInt32(c.a)
            func pre(_ v: UInt8) -> UInt32 { (UInt32(v) * a + 127) / 255 }
            func un(_ v: UInt32) -> UInt8 { UInt8(min(255, (v * 255 + a / 2) / a)) }
            return RGBA8(un(pre(c.r)), un(pre(c.g)), un(pre(c.b)), c.a)
        }
    }

    // MARK: Private

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }

    private static func unfilter(_ row: inout [UInt8], prev: [UInt8], type: UInt8, bpp: Int) throws(DecodeError) {
        let n = row.count
        switch type {
        case 0: return
        case 1: for i in bpp..<max(bpp, n) { row[i] = row[i] &+ row[i - bpp] }
        case 2: for i in 0..<n { row[i] = row[i] &+ prev[i] }
        case 3:
            for i in 0..<n {
                let a = i >= bpp ? Int(row[i - bpp]) : 0
                row[i] = row[i] &+ UInt8((a + Int(prev[i])) / 2)
            }
        case 4:
            for i in 0..<n {
                let a = i >= bpp ? row[i - bpp] : 0
                let c = i >= bpp ? prev[i - bpp] : 0
                row[i] = row[i] &+ paeth(a, prev[i], c)
            }
        default: throw .badFilter(type)
        }
    }

    private static func sample(
        _ row: [UInt8], _ x: Int, depth: Int, channels: Int, colorType: Int, palette: [RGBA8], transparency: [UInt8]
    ) -> RGBA8 {
        func value(_ channel: Int) -> Int {
            switch depth {
            case 8: return Int(row[x * channels + channel])
            case 16: return Int(row[(x * channels + channel) * 2]) << 8 | Int(row[(x * channels + channel) * 2 + 1])
            default:
                let bit = x * depth
                let byte = row[bit / 8]
                let shift = 8 - depth - bit % 8
                return Int(byte >> UInt8(shift)) & ((1 << depth) - 1)
            }
        }
        func to8(_ v: Int) -> UInt8 {
            switch depth {
            case 16: return UInt8(v >> 8)
            case 8: return UInt8(v)
            default: return UInt8(v * 255 / ((1 << depth) - 1))
            }
        }
        func transparentKey(_ values: [Int]) -> Bool {
            guard transparency.count == values.count * 2 else { return false }
            for (i, v) in values.enumerated() where Int(transparency[i * 2]) << 8 | Int(transparency[i * 2 + 1]) != v {
                return false
            }
            return true
        }
        let c: RGBA8
        switch colorType {
        case 0:
            let g = value(0)
            c = RGBA8(to8(g), to8(g), to8(g), transparentKey([g]) ? 0 : 255)
        case 2:
            let r = value(0), g = value(1), b = value(2)
            c = RGBA8(to8(r), to8(g), to8(b), transparentKey([r, g, b]) ? 0 : 255)
        case 3:
            let i = value(0)
            c = i < palette.count ? palette[i] : RGBA8(0, 0, 0, 255)
        case 4:
            let g = to8(value(0))
            c = RGBA8(g, g, g, to8(value(1)))
        default:
            c = RGBA8(to8(value(0)), to8(value(1)), to8(value(2)), to8(value(3)))
        }
        return throughPremultiplied(c)
    }

    private static func appendChunk(_ type: String, _ body: [UInt8], to out: inout Data) {
        var chunk = [UInt8]()
        chunk.appendBigEndian(UInt32(body.count))
        let typeBytes = Array(type.utf8)
        chunk.append(contentsOf: typeBytes)
        chunk.append(contentsOf: body)
        chunk.appendBigEndian(CRC32.checksum(typeBytes + body))
        out.append(contentsOf: chunk)
    }
}

// MARK: - CRC-32, Adler-32

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

enum Adler32 {
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let end = min(bytes.count, i + 5552)
            while i < end {
                a += UInt32(bytes[i])
                b += a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }
}

// MARK: - zlib

enum Zlib {
    enum Failure: Error, Equatable { case header, truncated, badBlock, badCode, badDistance, checksum }

    // RFC 1951 tables.
    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
                                    67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                                  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
                                   11, 11, 12, 12, 13, 13]
    static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    // MARK: Inflate

    private struct BitReader {
        let data: [UInt8]
        var pos: Int
        var buffer: UInt32 = 0
        var count = 0

        mutating func bits(_ n: Int) throws(Failure) -> Int {
            while count < n {
                guard pos < data.count else { throw .truncated }
                buffer |= UInt32(data[pos]) << UInt32(count)
                pos += 1
                count += 8
            }
            let v = Int(buffer & ((1 << UInt32(n)) - 1))
            buffer >>= UInt32(n)
            count -= n
            return v
        }

        mutating func alignToByte() {
            buffer = 0
            count = 0
        }
    }

    /// Canonical Huffman decoding table (`puff.c`'s layout): codes per length, then symbols in code order, plus a
    /// 9-bit lookup for the short codes.
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []
        /// For the first 9 bits read LSB first: (symbol << 4) | length, or -1 when the code is longer.
        var fast = [Int](repeating: -1, count: 512)

        init(lengths: [Int]) throws(Failure) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var left = 1
            for len in 1...15 {
                left <<= 1
                left -= counts[len]
                if left < 0 { throw .badCode }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offsets[len + 1] = offsets[len] + counts[len] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, l) in lengths.enumerated() where l != 0 {
                symbols[offsets[l]] = symbol
                offsets[l] += 1
            }
            // Fast table: walk the canonical codes.
            var code = 0, index = 0
            for len in 1...15 {
                for _ in 0..<counts[len] {
                    if len <= 9 {
                        var reversed = 0
                        for b in 0..<len where code & (1 << (len - 1 - b)) != 0 { reversed |= 1 << b }
                        var fill = reversed
                        while fill < 512 {
                            fast[fill] = symbols[index] << 4 | len
                            fill += 1 << len
                        }
                    }
                    code += 1
                    index += 1
                }
                code <<= 1
            }
        }

        func decode(_ r: inout BitReader) throws(Failure) -> Int {
            // Try the 9-bit table with whatever bits are available.
            while r.count < 9, r.pos < r.data.count {
                r.buffer |= UInt32(r.data[r.pos]) << UInt32(r.count)
                r.pos += 1
                r.count += 8
            }
            let peek = Int(r.buffer & 511)
            let entry = fast[peek]
            if entry >= 0, entry & 15 <= r.count {
                let len = entry & 15
                r.buffer >>= UInt32(len)
                r.count -= len
                return entry >> 4
            }
            // Slow path: bit by bit.
            var code = 0, first = 0, index = 0
            for len in 1...15 {
                code |= try r.bits(1)
                let count = counts[len]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw .badCode
        }
    }

    private static let fixedTables: (Huffman, Huffman) = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        // The fixed tables are valid by construction.
        let lit = try! Huffman(lengths: lengths)
        let dist = try! Huffman(lengths: [Int](repeating: 5, count: 30))
        return (lit, dist)
    }()

    static func decompress(_ input: [UInt8]) throws(Failure) -> [UInt8] {
        guard input.count >= 6 else { throw .truncated }
        let cmf = Int(input[0]), flg = Int(input[1])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0, flg & 0x20 == 0 else { throw .header }
        var r = BitReader(data: input, pos: 2)
        var out = [UInt8]()
        out.reserveCapacity(input.count * 4)
        var final = 0
        repeat {
            final = try r.bits(1)
            switch try r.bits(2) {
            case 0:
                r.alignToByte()
                guard r.pos + 4 <= input.count else { throw .truncated }
                let len = Int(input[r.pos]) | Int(input[r.pos + 1]) << 8
                let nlen = Int(input[r.pos + 2]) | Int(input[r.pos + 3]) << 8
                guard len == ~nlen & 0xFFFF else { throw .badBlock }
                r.pos += 4
                guard r.pos + len <= input.count else { throw .truncated }
                out.append(contentsOf: input[r.pos..<(r.pos + len)])
                r.pos += len
            case 1:
                try inflateBlock(&r, &out, fixedTables.0, fixedTables.1)
            case 2:
                let nlen = try r.bits(5) + 257, ndist = try r.bits(5) + 1, ncode = try r.bits(4) + 4
                guard nlen <= 286, ndist <= 30 else { throw .badBlock }
                var codeLengths = [Int](repeating: 0, count: 19)
                for i in 0..<ncode { codeLengths[codeLengthOrder[i]] = try r.bits(3) }
                let lencode = try Huffman(lengths: codeLengths)
                var lengths = [Int]()
                lengths.reserveCapacity(nlen + ndist)
                while lengths.count < nlen + ndist {
                    let sym = try lencode.decode(&r)
                    switch sym {
                    case 0...15: lengths.append(sym)
                    case 16:
                        guard let last = lengths.last else { throw .badBlock }
                        lengths.append(contentsOf: repeatElement(last, count: 3 + (try r.bits(2))))
                    case 17: lengths.append(contentsOf: repeatElement(0, count: 3 + (try r.bits(3))))
                    default: lengths.append(contentsOf: repeatElement(0, count: 11 + (try r.bits(7))))
                    }
                }
                guard lengths.count == nlen + ndist, lengths[256] != 0 else { throw .badBlock }
                let lit = try Huffman(lengths: Array(lengths[0..<nlen]))
                let dist = try Huffman(lengths: Array(lengths[nlen...]))
                try inflateBlock(&r, &out, lit, dist)
            default:
                throw .badBlock
            }
        } while final == 0
        // Adler-32 trailer (big-endian) on the next byte boundary.
        r.alignToByte()
        if r.pos + 4 <= input.count {
            let expected = input.readBigEndian(at: r.pos)
            guard expected == Adler32.checksum(out) else { throw .checksum }
        }
        return out
    }

    private static func inflateBlock(_ r: inout BitReader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman) throws(Failure) {
        while true {
            let sym = try lit.decode(&r)
            if sym < 256 {
                out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let li = sym - 257
                guard li < 29 else { throw .badCode }
                let length = lengthBase[li] + (try r.bits(lengthExtra[li]))
                let di = try dist.decode(&r)
                guard di < 30 else { throw .badDistance }
                let distance = distBase[di] + (try r.bits(distExtra[di]))
                guard distance <= out.count else { throw .badDistance }
                let start = out.count - distance
                if distance >= length {
                    out.append(contentsOf: out[start..<(start + length)])
                } else {
                    for i in 0..<length { out.append(out[start + i]) }
                }
            }
        }
    }

    // MARK: Deflate (fixed Huffman, LZ77 with hash chains)

    private struct BitWriter {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var count = 0

        mutating func write(_ value: Int, _ n: Int) {
            buffer |= UInt32(value) << UInt32(count)
            count += n
            while count >= 8 {
                bytes.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                count -= 8
            }
        }

        /// A Huffman code, most significant bit first.
        mutating func writeCode(_ code: Int, _ n: Int) {
            var reversed = 0
            for b in 0..<n where code & (1 << (n - 1 - b)) != 0 { reversed |= 1 << b }
            write(reversed, n)
        }

        mutating func flush() {
            if count > 0 { bytes.append(UInt8(buffer & 0xFF)) }
            buffer = 0
            count = 0
        }
    }

    private static func writeLiteral(_ w: inout BitWriter, _ sym: Int) {
        switch sym {
        case 0...143: w.writeCode(0x30 + sym, 8)
        case 144...255: w.writeCode(0x190 + sym - 144, 9)
        case 256...279: w.writeCode(sym - 256, 7)
        default: w.writeCode(0xC0 + sym - 280, 8)
        }
    }

    private static let lengthSymbol: [(symbol: Int, extra: Int, base: Int)] = (0...258).map { len in
        guard len >= 3 else { return (0, 0, 0) }
        var i = 28
        while lengthBase[i] > len { i -= 1 }
        return (257 + i, lengthExtra[i], lengthBase[i])
    }

    static func compress(_ input: [UInt8]) -> [UInt8] {
        var w = BitWriter()
        w.bytes = [0x78, 0x01]
        w.write(1, 1) // BFINAL
        w.write(1, 2) // fixed Huffman
        let n = input.count
        let window = 32768, maxChain = 64, hashSize = 1 << 15
        var head = [Int](repeating: -1, count: hashSize)
        var prev = [Int](repeating: -1, count: window)
        func hash(_ i: Int) -> Int {
            (Int(input[i]) << 10 ^ Int(input[i + 1]) << 5 ^ Int(input[i + 2])) & (hashSize - 1)
        }
        func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            prev[i & (window - 1)] = head[h]
            head[h] = i
        }
        var i = 0
        while i < n {
            var bestLen = 0, bestDist = 0
            if i + 2 < n {
                var candidate = head[hash(i)]
                var chain = 0
                let maxLen = min(258, n - i)
                while candidate >= 0, i - candidate <= window, chain < maxChain {
                    if input[candidate + bestLen] == input[i + bestLen] || bestLen == 0 {
                        var len = 0
                        while len < maxLen, input[candidate + len] == input[i + len] { len += 1 }
                        if len > bestLen {
                            bestLen = len
                            bestDist = i - candidate
                            if len == maxLen { break }
                        }
                    }
                    let next = prev[candidate & (window - 1)]
                    if next >= candidate { break }
                    candidate = next
                    chain += 1
                }
            }
            if bestLen >= 3 {
                let ls = lengthSymbol[bestLen]
                writeLiteral(&w, ls.symbol)
                if ls.extra > 0 { w.write(bestLen - ls.base, ls.extra) }
                var di = 29
                while distBase[di] > bestDist { di -= 1 }
                w.writeCode(di, 5)
                if distExtra[di] > 0 { w.write(bestDist - distBase[di], distExtra[di]) }
                for k in 0..<bestLen { insert(i + k) }
                i += bestLen
            } else {
                writeLiteral(&w, Int(input[i]))
                insert(i)
                i += 1
            }
        }
        writeLiteral(&w, 256)
        w.flush()
        var out = w.bytes
        out.appendBigEndian(Adler32.checksum(input))
        return out
    }
}

// MARK: - Byte helpers

extension [UInt8] {
    fileprivate mutating func appendBigEndian(_ v: UInt32) {
        append(UInt8(v >> 24 & 0xFF))
        append(UInt8(v >> 16 & 0xFF))
        append(UInt8(v >> 8 & 0xFF))
        append(UInt8(v & 0xFF))
    }

    fileprivate func readBigEndian(at i: Int) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}

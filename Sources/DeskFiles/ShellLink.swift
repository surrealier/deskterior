import Foundation

/// A Windows shortcut (`.lnk`, MS-SHLLINK) to a local path: what a drop-in "alias" is on Windows
/// (docs/WINDOWS.md WP5, `FilePrimitives.writeLink`). Only the bytes; writing them is `FilePrimitives`'.
///
/// The smallest form Explorer resolves: the header, a LinkInfo with the volume's drive type and serial and the
/// target's local path (ANSI with `?` for what ANSI cannot hold, and Unicode, which Explorer prefers), and the
/// terminal extra-data block. No item ID list, no strings, no icon: Explorer fills those in when it first resolves
/// the link.
enum ShellLink {
    /// `FILE_ATTRIBUTE_DIRECTORY` / `FILE_ATTRIBUTE_ARCHIVE` in the header.
    static func data(targetPath: String, isDirectory: Bool, driveType: UInt32 = 3, volumeSerial: UInt32 = 0) -> Data {
        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        // ShellLinkHeader (76 bytes).
        u32(0x4C)
        out.append(contentsOf: [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46])
        let hasLinkInfo: UInt32 = 0x02, isUnicode: UInt32 = 0x80
        u32(hasLinkInfo | isUnicode)
        u32(isDirectory ? 0x10 : 0x20)
        out.append(Data(count: 24))      // creation, access, write times
        u32(0)                            // file size
        u32(0)                            // icon index
        u32(1)                            // SW_SHOWNORMAL
        u16(0)                            // hot key
        out.append(Data(count: 10))      // reserved

        // LinkInfo with the Unicode path fields (header size 0x24).
        let headerSize: UInt32 = 0x24
        let volumeID: Data = {
            var v = Data()
            func v32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { v.append(contentsOf: $0) } }
            v32(17)                       // VolumeIDSize
            v32(driveType)
            v32(volumeSerial)
            v32(0x10)                     // VolumeLabelOffset
            v.append(0)                   // empty label
            return v
        }()
        let ansiPath = Data(targetPath.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") } + [0])
        let ansiSuffix = Data([0])
        var unicodePath = Data()
        for unit in targetPath.utf16 { withUnsafeBytes(of: unit.littleEndian) { unicodePath.append(contentsOf: $0) } }
        unicodePath.append(contentsOf: [0, 0])
        let unicodeSuffix = Data([0, 0])

        let volumeIDOffset = headerSize
        let localBasePathOffset = volumeIDOffset + UInt32(volumeID.count)
        let commonPathSuffixOffset = localBasePathOffset + UInt32(ansiPath.count)
        let localBasePathOffsetUnicode = commonPathSuffixOffset + UInt32(ansiSuffix.count)
        let commonPathSuffixOffsetUnicode = localBasePathOffsetUnicode + UInt32(unicodePath.count)
        let linkInfoSize = commonPathSuffixOffsetUnicode + UInt32(unicodeSuffix.count)

        u32(linkInfoSize)
        u32(headerSize)
        u32(0x01)                         // VolumeIDAndLocalBasePath
        u32(volumeIDOffset)
        u32(localBasePathOffset)
        u32(0)                            // CommonNetworkRelativeLinkOffset
        u32(commonPathSuffixOffset)
        u32(localBasePathOffsetUnicode)
        u32(commonPathSuffixOffsetUnicode)
        out.append(volumeID)
        out.append(ansiPath)
        out.append(ansiSuffix)
        out.append(unicodePath)
        out.append(unicodeSuffix)

        u32(0)                            // TerminalBlock
        return out
    }

    /// The local path a shortcut points to (its LinkInfo's local base path, Unicode when present), or nil when
    /// `data` is not a shortcut to a local path. Reads ours and Explorer's (which put an item ID list first).
    static func targetPath(of data: Data) -> String? {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= b.count else { return nil }
            return Int(b[o]) | Int(b[o + 1]) << 8
        }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        guard u32(0) == 0x4C, let flags = u32(20), flags & 0x02 != 0 else { return nil }
        var info = 76
        if flags & 0x01 != 0 {                       // HasLinkTargetIDList
            guard let idListSize = u16(76) else { return nil }
            info = 78 + idListSize
        }
        guard let headerSize = u32(info + 4), let infoFlags = u32(info + 8), infoFlags & 0x01 != 0 else { return nil }
        if headerSize >= 0x24, let unicodeOffset = u32(info + 28), unicodeOffset > 0 {
            var units: [UInt16] = []
            var o = info + unicodeOffset
            while let unit = u16(o) {
                if unit == 0 { return String(decoding: units, as: UTF16.self) }
                units.append(UInt16(unit))
                o += 2
            }
            return nil
        }
        guard let ansiOffset = u32(info + 16) else { return nil }
        var bytes: [UInt8] = []
        var o = info + ansiOffset
        while o < b.count, b[o] != 0 {
            bytes.append(b[o])
            o += 1
        }
        return o < b.count ? String(decoding: bytes, as: UTF8.self) : nil
    }
}

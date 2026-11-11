import Foundation
import Testing
@testable import DeskFiles

@Suite("Windows shortcuts (.lnk bytes)")
struct ShellLinkTests {
    @Test("A shortcut holds the header, a LinkInfo with the target path and the terminal block, and reads back")
    func roundTrip() {
        for path in [#"C:\Users\me\Documents\report.pdf"#, #"D:\사진\여행 2026"#, #"C:\x\😀.txt"#] {
            let data = ShellLink.data(targetPath: path, isDirectory: path.hasSuffix("2026"), volumeSerial: 0xABCD_1234)
            let b = [UInt8](data)
            #expect(b.count > 76 && b[0] == 0x4C && b[1] == 0 && b[4] == 0x01 && b[5] == 0x14 && b[6] == 0x02)
            #expect(Array(b.suffix(4)) == [0, 0, 0, 0], "terminal block")
            #expect(ShellLink.targetPath(of: data) == path)
        }
    }

    @Test("The ANSI path stands in '?' for what ANSI cannot hold; a shortcut with an item ID list still reads")
    func ansiAndIDList() {
        let data = ShellLink.data(targetPath: #"C:\한\a.txt"#, isDirectory: false)
        // Without the Unicode fields (an older writer), the ANSI path is what reads back.
        var b = [UInt8](data)
        b[76 + 4] = 0x1C                                   // LinkInfoHeaderSize without the Unicode offsets
        #expect(ShellLink.targetPath(of: Data(b)) == #"C:\?\a.txt"#)
        // Explorer's shortcuts put an item ID list (size, bytes) before the LinkInfo.
        var withIDs = [UInt8](data)
        withIDs[20] |= 0x01
        withIDs.insert(contentsOf: [4, 0, 0xDE, 0xAD, 0xBE, 0xEF], at: 76)
        #expect(ShellLink.targetPath(of: Data(withIDs)) == #"C:\한\a.txt"#)
        #expect(ShellLink.targetPath(of: Data("not a link".utf8)) == nil)
    }
}

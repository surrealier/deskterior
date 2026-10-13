import DeskCore
import Testing
@testable import DeskScene

@Suite("Gestures and keys")
struct GesturesTests {
    @Test("Desk keys (Errata 1): Space, ⌘O/⌘↓, ⌘C, ⌘A, ⌘F, ⌘Z/⇧⌘Z, Esc, arrows; nothing destructive")
    func keyCommands() {
        #expect(KeyCommand.from(keyCode: 49, mods: []) == .quickLook)
        #expect(KeyCommand.from(keyCode: 53, mods: []) == .escape)
        #expect(KeyCommand.from(keyCode: 123, mods: []) == .move(dx: -1, dy: 0))
        #expect(KeyCommand.from(keyCode: 126, mods: []) == .move(dx: 0, dy: -1))
        #expect(KeyCommand.from(keyCode: 125, mods: []) == .move(dx: 0, dy: 1))
        #expect(KeyCommand.from(keyCode: 125, mods: .command) == .open)
        #expect(KeyCommand.from(keyCode: 31, mods: .command) == .open)
        #expect(KeyCommand.from(keyCode: 8, mods: .command) == .copy)
        #expect(KeyCommand.from(keyCode: 0, mods: .command) == .selectAll)
        #expect(KeyCommand.from(keyCode: 3, mods: .command) == .find)
        #expect(KeyCommand.from(keyCode: 6, mods: .command) == .undo)
        #expect(KeyCommand.from(keyCode: 6, mods: [.command, .shift]) == .redo)
        // Layout-aware: the character wins over the US key code.
        #expect(KeyCommand.from(keyCode: 6, characters: "c", mods: .command) == .copy)
        // No ⌘⌫, no Delete, no plain letters.
        #expect(KeyCommand.from(keyCode: 51, characters: "\u{7f}", mods: .command) == nil)
        #expect(KeyCommand.from(keyCode: 117, mods: []) == nil)
        #expect(KeyCommand.from(keyCode: 0, characters: "a", mods: []) == nil)
        #expect(KeyCommand.from(keyCode: 49, mods: .command) == nil)
    }

    @Test("Demo key names")
    func keyNames() {
        #expect(KeyCommand(name: "space") == .quickLook)
        #expect(KeyCommand(name: "cmd+down") == .open)
        #expect(KeyCommand(name: "shift+cmd+z") == .redo)
        #expect(KeyCommand(name: "Cmd+F") == .find)
        #expect(KeyCommand(name: "left") == .move(dx: -1, dy: 0))
        #expect(KeyCommand(name: "cmd+delete") == nil && KeyCommand(name: "hyper+a") == nil && KeyCommand(name: "x") == nil)
    }

    @Test("A gesture knows where it happened")
    func gesturePoints() {
        let p = SIMD2<Float>(3, 4)
        #expect(Gesture.press(p, []).point == p)
        #expect(Gesture.click(p, .command, count: 2).point == p)
        #expect(Gesture.dragBegan(from: .zero, at: p, []).point == p)
        #expect(Gesture.scroll(p, delta: .zero, []).point == p)
        #expect(Gesture.cancelPress.point == nil)
    }
}

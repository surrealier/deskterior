import AppKit
import DeskCore
import Observation
import SwiftUI

/// One text editor's link to the model (Erratum 31): what it edits (a sticky note or a day page), in which editing
/// session, and when its text is committed. A commit goes out 0.8 s after the last keystroke, but never while an input
/// method is composing (`hasMarkedText()`: a Korean syllable is never cut in half; the wait starts over), and at once
/// on blur, tab switch, close, resign-key and quit (`flush`, which ends the composition with `unmarkText()` first).
/// Each attach starts a session, and one session is one undo entry (`UndoJournal.record(…, coalesce:)`).
@Observable
final class MemoEditor {
    enum Target: Hashable { case note(NoteID), day(DayKey) }

    /// What the text view last showed from the model: the target, and how often it was (re)loaded.
    struct Shown: Equatable {
        var target: Target?
        var generation: Int
    }

    /// Seconds after the last keystroke.
    static let commitDelay: TimeInterval = 0.8

    private(set) var target: Target?
    private(set) var session = 0
    /// Bumped whenever the text view must show the model's text again: an attach, or a window action on the target
    /// (Tear Off, Remove Note) that changed it.
    private(set) var generation = 0
    /// Graphemes in the text view now (the "%d/1000" counter).
    private(set) var count = 0
    /// Bumped to put the cursor in the text view.
    private(set) var focusRequest = 0
    @ObservationIgnored var delay = MemoEditor.commitDelay
    /// Sends the text to the model (`.editNote`, `.editDayPage`) with the session.
    @ObservationIgnored var commit: (Target, String, Int) -> Void = { _, _, _ in }
    /// The text view while it is on screen.
    @ObservationIgnored weak var textView: NSTextView?
    /// Typed since the last commit.
    @ObservationIgnored private(set) var isDirty = false
    @ObservationIgnored private var latest = ""
    @ObservationIgnored private var due: DispatchWorkItem?

    var shown: Shown { Shown(target: target, generation: generation) }

    /// Edits `target` from now on, in `session`; what was typed for the old target is committed first.
    func attach(_ target: Target?, session: Int) {
        flush()
        self.target = target
        self.session = session
        generation += 1
    }

    func focus() {
        focusRequest += 1
    }

    /// The user typed, pasted or deleted (an input method's composition included).
    func textChanged(_ text: String) {
        latest = text
        count = text.count
        isDirty = true
        arm()
    }

    /// The text view now shows `text` from the model: nothing to commit.
    func showing(_ text: String) {
        latest = text
        count = text.count
        isDirty = false
        due?.cancel()
        due = nil
    }

    /// Commits now (blur, tab switch, close, resign-key, quit), ending a composition first so its text counts.
    func flush() {
        if let tv = textView, tv.hasMarkedText() {
            tv.unmarkText()
            tv.inputContext?.discardMarkedText()
            latest = tv.string
        }
        commitNow()
    }

    /// The text view is being typed in: the first responder of the key window. Model text never replaces its text
    /// then.
    var isFocused: Bool {
        guard let tv = textView, let window = tv.window else { return false }
        return window.isKeyWindow && window.firstResponder === tv
    }

    private func arm() {
        due?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        due = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The pause after the last keystroke is over: commit, unless a composition is still open (then wait again).
    private func fire() {
        due = nil
        if textView?.hasMarkedText() == true { return arm() }
        commitNow()
    }

    private func commitNow() {
        due?.cancel()
        due = nil
        guard isDirty else { return }
        isDirty = false
        guard let target else { return }
        commit(target, latest, session)
    }
}

/// The plain-text editor of a note or a day page (Erratum 31): an `NSTextView` with rich text, smart quotes and dashes
/// off and its own undo (⌘Z inside the text), holding at most `MemoBook.maxText` graphemes, that reports its edits to
/// a `MemoEditor`. It takes the model's `text` when the editor attaches to a target or reloads it, and otherwise only
/// while it is not focused: model text is never pushed into an editor being typed in.
struct NoteTextView: NSViewRepresentable {
    let editor: MemoEditor
    /// The model's text for the editor's target.
    let text: String
    var placeholder = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(editor: editor)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let tv = MemoTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textColor = .textColor
        tv.drawsBackground = false
        tv.delegate = context.coordinator
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? MemoTextView else { return }
        let c = context.coordinator
        c.editor = editor
        editor.textView = tv
        if tv.placeholder != placeholder { tv.placeholder = placeholder }
        tv.isEditable = editor.target != nil
        if c.shown != editor.shown {
            c.shown = editor.shown
            c.show(text, in: tv)
        } else if tv.string != text, !editor.isDirty, !editor.isFocused {
            c.show(text, in: tv)
        }
        if c.focusSeen != editor.focusRequest {
            c.focusSeen = editor.focusRequest
            DispatchQueue.main.async { [weak tv] in
                MainActor.assumeIsolated {
                    guard let tv, tv.isEditable else { return }
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // A tab switch or a close has flushed already; this catches a view that goes any other way (off the main
        // queue's current update, so the model is not changed while SwiftUI updates its views).
        let editor = coordinator.editor
        if editor.textView === scroll.documentView { editor.textView = nil }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { editor.flush() }
        }
    }

    /// Whether replacing `range` of `current` with `replacement` keeps the text within `limit` graphemes and
    /// `MemoBook.maxTextBytes` of UTF-8, as the model keeps it (a change that shortens it always does).
    static func fits(_ current: String, replacing range: NSRange, with replacement: String,
                     limit: Int = MemoBook.maxText) -> Bool {
        let next = (current as NSString).replacingCharacters(in: range, with: replacement)
        let shorter = next.count <= current.count && next.utf8.count <= current.utf8.count
        return shorter || (next.count <= limit && next.utf8.count <= MemoBook.maxTextBytes)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var editor: MemoEditor
        var shown: MemoEditor.Shown?
        var focusSeen = 0
        /// The text's own undo (⌘Z inside the text), apart from the window's and the desk's.
        private let undo = UndoManager()

        init(editor: MemoEditor) {
            self.editor = editor
        }

        /// Shows the model's `text` (no commit follows; the text's own undo starts over).
        func show(_ text: String, in tv: NSTextView) {
            if tv.string != text {
                tv.string = text
                tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
            undo.removeAllActions()
            editor.showing(text)
            tv.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            editor.textChanged(tv.string)
        }

        /// Blur: the text view gave up the keyboard.
        func textDidEndEditing(_ notification: Notification) {
            editor.flush()
        }

        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            if NoteTextView.fits(tv.string, replacing: range, with: replacementString) { return true }
            NSSound.beep()
            return false
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undo
        }
    }
}

/// The note editor's text view: draws a placeholder while it is empty.
final class MemoTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor, .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
        ]
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

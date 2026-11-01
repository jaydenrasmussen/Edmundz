import AppKit
import EdmundzCore

/// The editing surface: a TextKit 2 text view whose content is the raw Markdown, shown live-rendered by the `Styler`.
public final class EditorTextView: NSTextView {
    weak var coordinator: EditorCoordinator?
    var hasInteracted = false

    // The caret stays hidden until the user clicks or types (documents open rendered, nothing to switch).
    public override var shouldDrawInsertionPoint: Bool { hasInteracted && super.shouldDrawInsertionPoint }

    // MARK: applying edits

    /// Applies disjoint edits as one undo step, then sets the selection.
    func apply(_ r: EditResult) {
        if r.edits.isEmpty { setSelectedRange(r.selection); return }
        let sorted = r.edits.sorted { $0.range.location > $1.range.location }
        guard shouldChangeText(inRanges: sorted.map { NSValue(range: $0.range) }, replacementStrings: sorted.map { $0.replacement }) else { return }
        undoManager?.beginUndoGrouping()
        textStorage?.beginEditing()
        for e in sorted { textStorage?.replaceCharacters(in: e.range, with: e.replacement) }
        textStorage?.endEditing()
        undoManager?.endUndoGrouping()
        didChangeText()
        setSelectedRange(r.selection)
        scrollRangeToVisible(r.selection)
    }

    private var text: NSString { string as NSString }
    private var model: DocumentModel? { coordinator?.model }

    private func run(_ body: (NSString, NSRange, DocumentModel) -> EditResult?) {
        guard let model else { return }
        coordinator?.userInteracted()
        if let r = body(text, selectedRange(), model) { apply(r) }
    }

    // MARK: formatting actions (targets of the Format menu)

    @objc func toggleBold(_ sender: Any?) { run { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) } }
    @objc func toggleItalic(_ sender: Any?) { run { FormatCommands.toggleInline(.italic, text: $0, selection: $1, model: $2) } }
    @objc func toggleUnderline(_ sender: Any?) { run { FormatCommands.toggleInline(.underline, text: $0, selection: $1, model: $2) } }
    @objc func toggleStrikethrough(_ sender: Any?) { run { FormatCommands.toggleInline(.strike, text: $0, selection: $1, model: $2) } }
    @objc func toggleInlineCode(_ sender: Any?) { run { FormatCommands.toggleInline(.code, text: $0, selection: $1, model: $2) } }
    @objc func editLink(_ sender: Any?) { run { FormatCommands.link(text: $0, selection: $1, model: $2) } }
    @objc func setHeadingLevel(_ sender: NSMenuItem) { let l = sender.tag; run { FormatCommands.setHeading(l, text: $0, selection: $1, model: $2) } }
    @objc func toggleBulletList(_ sender: Any?) { run { FormatCommands.toggleList(.bullet, text: $0, selection: $1, model: $2) } }
    @objc func toggleNumberedList(_ sender: Any?) { run { FormatCommands.toggleList(.ordered, text: $0, selection: $1, model: $2) } }
    @objc func toggleTaskList(_ sender: Any?) { run { FormatCommands.toggleList(.task, text: $0, selection: $1, model: $2) } }
    @objc func indentItem(_ sender: Any?) { run { FormatCommands.indent(outdent: false, text: $0, selection: $1, model: $2) } }
    @objc func outdentItem(_ sender: Any?) { run { FormatCommands.indent(outdent: true, text: $0, selection: $1, model: $2) } }

    // MARK: keys

    public override func insertNewline(_ sender: Any?) {
        coordinator?.userInteracted()
        if Settings.shared.autoContinueLists, let model, let r = FormatCommands.newline(text: text, selection: selectedRange(), model: model) { apply(r); return }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) {
        coordinator?.userInteracted()
        if let model, let r = FormatCommands.nextCell(text: text, selection: selectedRange(), backward: false, model: model) { apply(r); return }
        if let model, let r = FormatCommands.indent(outdent: false, text: text, selection: selectedRange(), model: model) { apply(r); return }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if let model, let r = FormatCommands.nextCell(text: text, selection: selectedRange(), backward: true, model: model) { apply(r); return }
        if let model, let r = FormatCommands.indent(outdent: true, text: text, selection: selectedRange(), model: model) { apply(r); return }
        super.insertBacktab(sender)
    }

    public override func keyDown(with event: NSEvent) {
        coordinator?.userInteracted()
        super.keyDown(with: event)
    }

    private static let pairs: [String: String] = ["*": "*", "_": "_", "`": "`", "~": "~", "(": ")", "[": "]", "{": "}", "\"": "\""]
    private static let autoClose: Set<String> = ["(", "[", "{", "`", "\""]

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        coordinator?.userInteracted()
        guard Settings.shared.smartPairs, let s = (string as? String) ?? (string as? NSAttributedString)?.string, s.count == 1, replacementRange.location == NSNotFound || replacementRange.length == 0 || true else {
            super.insertText(string, replacementRange: replacementRange); return
        }
        let sel = selectedRange()
        let t = text
        // typing over a selection wraps it
        if sel.length > 0, let close = Self.pairs[s], !hasMarkedText() {
            let inner = t.substring(with: sel)
            let ins = s + inner + close
            apply(EditResult(edits: [TextEdit(sel, ins)], selection: NSRange(location: sel.location + 1, length: sel.length)))
            return
        }
        // typing a closing character that is already next: step over it
        if sel.length == 0, sel.location < t.length, Self.pairs.values.contains(s), s != "*", s != "_", s != "~",
           t.substring(with: NSRange(location: sel.location, length: 1)) == s, !hasMarkedText() {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0)); return
        }
        // auto-close brackets and backticks when the next character is blank or a closer
        if sel.length == 0, Self.autoClose.contains(s), let close = Self.pairs[s], !hasMarkedText() {
            let next: String = sel.location < t.length ? t.substring(with: NSRange(location: sel.location, length: 1)) : ""
            let prevIsWord = sel.location > 0 && (s == "`" || s == "\"") && { () -> Bool in
                guard let u = Unicode.Scalar(t.character(at: sel.location - 1)) else { return false }
                return CharacterSet.alphanumerics.contains(u)
            }()
            if (next.isEmpty || next == " " || next == "\n" || next == ")" || next == "]" || next == "}") && !prevIsWord {
                apply(EditResult(edits: [TextEdit(sel, s + close)], selection: NSRange(location: sel.location + 1, length: 0)))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: paste and drop of images

    public override func paste(_ sender: Any?) {
        if coordinator?.importImages(from: .general) == true { return }
        super.paste(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        if coordinator?.importImages(from: sender.draggingPasteboard, at: characterIndexForInsertion(at: p)) == true { return true }
        return super.performDragOperation(sender)
    }

    // MARK: mouse

    public override func mouseDown(with event: NSEvent) {
        let wasInteracted = hasInteracted
        coordinator?.userInteracted()
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        if let c = coordinator {
            let mods = event.modifierFlags
            if mods.contains(.command), c.openLink(atPoint: p, index: idx, force: true) { return }
            // a plain click opens a rendered link; ⌥-click, or a click while the caret is in the link, edits it instead
            if !mods.contains(.option), !mods.contains(.shift), Settings.shared.openLinksOnClick, event.clickCount == 1,
               c.openLink(atPoint: p, index: idx, force: false) { return }
            if c.toggleTask(at: p, index: idx) { return }
            if c.toggleDetails(at: idx) { return }
        }
        _ = wasInteracted
        super.mouseDown(with: event)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        coordinator?.updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let m = super.menu(for: event) ?? NSMenu()
        let p = convert(event.locationInWindow, from: nil)
        coordinator?.addDiagramItems(to: m, at: characterIndexForInsertion(at: p))
        return m
    }

    // MARK: accessibility: VoiceOver reads the rendered text, without hidden markers
    public override func accessibilityString(for range: NSRange) -> String? {
        guard let plain = coordinator?.plainTextForAccessibility() as NSString?, range.location != NSNotFound else { return super.accessibilityString(for: range) }
        // markers are removed, so map by clamping; exact ranges are only approximate for hidden syntax
        let r = NSIntersectionRange(range, NSRange(location: 0, length: plain.length))
        return plain.substring(with: r)
    }
}

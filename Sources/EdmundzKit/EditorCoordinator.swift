import AppKit
import EdmundzCore

/// Owns one document's editing stack: storage, model, styler, text view, scroll view. It keeps the model in step with edits
/// and restyles exactly the paragraphs whose display depends on the caret or on the edited block.
public final class EditorCoordinator: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    public let scrollView = NSScrollView()
    public let textView: EditorTextView
    public let styler: Styler
    public let model: DocumentModel
    public weak var document: NSDocument?
    private var interacted = false
    private var revealCap = 400
    public private(set) var restyleCount = 0
    private var layoutTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    public init(text: String, documentURL: URL?, interacted: Bool = false) {
        let tv = EditorTextView(usingTextLayoutManager: true)
        textView = tv
        model = DocumentModel(text: text as NSString)
        styler = Styler(model: model)
        super.init()
        self.interacted = interacted
        tv.hasInteracted = interacted
        tv.coordinator = self
        styler.documentURL = documentURL
        styler.selection = interacted ? NSRange(location: 0, length: 0) : NSRange(location: -1, length: 0)

        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false   // off by default: squiggles under hidden syntax are noise; toggle in Edit > Spelling
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = self
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .controlAccentColor
        tv.string = text
        tv.textStorage?.delegate = self
        tv.textContentStorage?.delegate = styler
        tv.textLayoutManager?.delegate = styler

        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)

        styler.attachments.onNeedFolderAccess = { [weak self] folder in
            guard let self else { return }
            if MainActor.assumeIsolated({ FolderAccess.request(for: folder, message: "Edmundz needs access to this folder to show the images in your document.") }) {
                self.styler.attachments.purge(); self.reloadStyles()
            }
        }
        styler.attachments.onLayout = { [weak self] in self?.scheduleRelayout() }
        styler.attachments.onRedraw = { [weak self] in self?.textView.needsDisplay = true }
        ImageStore.shared.onChange = { [weak self] in self?.scheduleRelayout() }
        appearanceObservation = tv.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in self?.appearanceChanged() }
        layoutInsets()
        updateFrontMatterOverrides()
    }

    deinit {
        // NSTextStorage / NSTextContentStorage / NSTextLayoutManager keep unretained delegate pointers to us and to the
        // styler: clear them before either is freed, or teardown can message a dangling object.
        NotificationCenter.default.removeObserver(self)
        appearanceObservation?.invalidate()
        layoutTimer?.invalidate()
        textView.textStorage?.delegate = nil
        textView.textContentStorage?.delegate = nil
        textView.textLayoutManager?.delegate = nil
        textView.delegate = nil
        textView.coordinator = nil
        styler.attachments.onLayout = nil; styler.attachments.onRedraw = nil
    }

    // MARK: text

    public func setText(_ text: String) {
        textView.string = text
        model.reset(text: text as NSString)
        updateFrontMatterOverrides()
        reloadStyles()
    }

    public var string: String { textView.string }

    // MARK: interaction state

    func userInteracted() {
        guard !interacted else { return }
        interacted = true
        textView.hasInteracted = true
        textView.updateInsertionPointStateAndRestartTimer(true)
        selectionDidChange()
    }

    // MARK: layout

    @objc private func frameChanged(_ n: Notification) { layoutInsets() }

    public func layoutInsets() {
        let w = scrollView.contentSize.width
        let measure = Settings.shared.measure
        let side = max(28, (w - measure) / 2)
        let newInset = NSSize(width: side, height: 36)
        if textView.textContainerInset != newInset {
            textView.textContainerInset = newInset
        }
        let col = max(120, min(measure, w - 56))
        if abs(styler.columnWidth - col) > 0.5 {
            styler.columnWidth = col
        }
    }

    private func scheduleRelayout() {
        layoutTimer?.invalidate()
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: false) { [weak self] _ in
            guard let self, let tlm = self.textView.textLayoutManager else { return }
            tlm.invalidateLayout(for: tlm.documentRange)
            self.textView.needsDisplay = true
        }
    }

    // MARK: settings / appearance

    @objc private func settingsChanged(_ n: Notification) {
        styler.attachments.purge(); MathRenderer.purge()
        layoutInsets()
        reloadStyles()
    }

    func appearanceChanged() {
        styler.attachments.purge(); MathRenderer.purge()
        reloadStyles()
    }

    /// Regenerates every paragraph's display (viewport first; TextKit 2 lays out lazily).
    public func reloadStyles() {
        guard let ts = textView.textStorage else { return }
        ts.beginEditing(); ts.edited(.editedAttributes, range: NSRange(location: 0, length: ts.length), changeInLength: 0); ts.endEditing()
    }

    // MARK: storage edits

    public func textStorage(_ ts: NSTextStorage, willProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        model.didEdit(oldRange: NSRange(location: range.location, length: range.length - delta), newLength: range.length, text: ts.string as NSString)
        editTouchedNewlines = delta < 0 || (ts.string as NSString).substring(with: range).contains("\n")
        if delta != 0 && !styler.openDetails.isEmpty {
            styler.openDetails = Set(styler.openDetails.map { $0 > range.location - (delta < 0 ? 0 : 0) ? $0 + delta : $0 })
            // anything that no longer starts a region is dropped on the next rescan
        }
    }
    private var editTouchedNewlines = false

    public func textDidChange(_ notification: Notification) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        if let fm = model.fences.spans.first, fm.kind == .frontMatter, textView.selectedRange().location <= fm.range.end { updateFrontMatterOverrides() }
        else if !styler.familyOverrides.isEmpty, !textView.string.hasPrefix("---") { updateFrontMatterOverrides() }
        if model.lastEditRebuilt { reloadStyles(); return }
        // restyle the rest of the edited block (an emphasis may now span lines, a table column may have widened, ...)
        let at = min(textView.selectedRange().location, max(0, text.length - 1))
        guard text.length > 0 else { return }
        var ranges: [NSRange] = []
        let blk = model.block(at: at, in: text)
        let caretLine = text.lineRange(for: NSRange(location: at, length: 0))
        for l in blk.lines.prefix(revealCap) where l.range != caretLine { ranges.append(l.range) }
        if editTouchedNewlines {
            if blk.range.location > 0 { let p = model.block(at: blk.range.location - 1, in: text); ranges += p.lines.suffix(40).map { $0.range } }
            if blk.range.end < text.length { let nx = model.block(at: blk.range.end, in: text); ranges += nx.lines.prefix(40).map { $0.range } }
        }
        restyle(ranges)
        selectionDidChange()
    }

    // MARK: reveal

    public func textViewDidChangeSelection(_ notification: Notification) { selectionDidChange() }

    func selectionDidChange() {
        let sel = interacted ? textView.selectedRange() : NSRange(location: -1, length: 0)
        guard sel != styler.selection else { return }
        let old = styler.selection
        styler.selection = sel
        restyle(scope(old) + scope(sel))
        // entering or leaving a <details> region shows or collapses its body
        if let ts = textView.textStorage, ts.length > 0 {
            let spanOf: (NSRange) -> DetailsSpan? = { r in r.location >= 0 ? self.model.fences.details(containing: min(r.location, ts.length - 1)) : nil }
            let o = spanOf(old), n = spanOf(sel)
            if o != n { for sp in [o, n].compactMap({ $0 }) where !styler.openDetails.contains(sp.range.location) { restyleLines(in: sp.range) } }
        }
    }

    /// Paragraph ranges whose display depends on the selection `sel`.
    func scope(_ sel: NSRange) -> [NSRange] {
        guard sel.location >= 0, let ts = textView.textStorage, ts.length > 0 else { return [] }
        let text = ts.string as NSString
        let at = min(sel.location, text.length - 1)
        let blk = model.block(at: at, in: text)
        var out: [NSRange] = []
        let endAt = min(max(sel.end, sel.location), text.length)
        // lines touched by the selection
        var p = text.lineRange(for: NSRange(location: at, length: 0))
        out.append(p)
        var guardN = 0
        while p.end < endAt, p.end < text.length, guardN < 200 { p = text.lineRange(for: NSRange(location: p.end, length: 0)); out.append(p); guardN += 1 }
        let kinds = blk.lines.map { $0.kind }
        let blockLevel = blk.widget != nil || kinds.contains { k in
            switch k { case .tableHeader, .tableRow, .tableDelimiter, .frontMatter, .frontMatterFence, .htmlComment: return true; default: return false }
        }
        if blockLevel { out += blk.lines.prefix(revealCap).map { $0.range } }
        else if let f = blk.lines.first, let l = blk.lines.last {
            switch f.kind { case .fenceOpen: out.append(f.range); out.append(l.range); default: break }
        }
        // multi-line runs that contain the caret
        for r in blk.runs where r.range.location <= sel.end && sel.location <= r.range.end {
            let rr = r.range
            if rr.length > 0 {
                var q = text.lineRange(for: NSRange(location: min(rr.location, text.length - 1), length: 0))
                out.append(q)
                var n = 0
                while q.end < rr.end, q.end < text.length, n < 50 { q = text.lineRange(for: NSRange(location: q.end, length: 0)); out.append(q); n += 1 }
            }
        }
        return out
    }

    /// One transaction per range: TextKit coalesces ranges edited in one transaction into a single span and would lay out
    /// everything between far-apart paragraphs (measured in M0: 211 ms).
    func restyle(_ ranges: [NSRange]) {
        guard let ts = textView.textStorage else { return }
        var seen = Set<Int>()
        for r in ranges where r.length > 0 && r.end <= ts.length && seen.insert(r.location).inserted {
            ts.beginEditing(); ts.edited(.editedAttributes, range: r, changeInLength: 0); ts.endEditing()
            restyleCount += 1
        }
    }

    // MARK: <details>

    func restyleLines(in range: NSRange, cap: Int = 3000) {
        let text = textView.string as NSString
        var out: [NSRange] = []
        var p = range.location
        while p < range.end, p < text.length, out.count < cap { let l = text.lineRange(for: NSRange(location: p, length: 0)); out.append(l); p = l.end }
        restyle(out)
    }

    /// A click on a `<summary>` line expands or collapses its region.
    public func toggleDetails(at idx: Int) -> Bool {
        let text = textView.string as NSString
        guard text.length > 0, let d = model.fences.details(containing: min(idx, text.length - 1)), let sum = d.summaryLine,
              idx >= sum.location && idx < sum.end else { return false }
        // while the caret is on the line it shows raw tags; clicking then just edits
        let caret = textView.selectedRange().location
        if interacted, caret >= sum.location && caret < sum.end { return false }
        if styler.openDetails.contains(d.range.location) { styler.openDetails.remove(d.range.location) } else { styler.openDetails.insert(d.range.location) }
        userInteracted()
        restyleLines(in: d.range)
        return true
    }

    // MARK: clicks

    func runAt(_ idx: Int, _ match: (Run) -> Bool) -> Run? {
        let text = textView.string as NSString
        guard text.length > 0 else { return nil }
        let blk = model.block(at: min(idx, text.length - 1), in: text)
        return blk.runs.first { $0.range.location <= idx && idx <= $0.range.end && match($0) }
    }

    func toggleTask(at point: NSPoint, index idx: Int) -> Bool {
        let text = textView.string as NSString
        guard text.length > 0, let (blk, li) = model.line(at: min(idx, text.length - 1), in: text) else { return false }
        let line = blk.lines[li]
        guard let t = line.task, styler.selection.location >= 0 ? !(styler.selection.location >= line.range.location && styler.selection.location <= line.range.end && textView.selectedRange().length == 0) || true : true else { return false }
        // the click must land on the checkbox glyph
        guard let tlm = textView.textLayoutManager, let cs = textView.textContentStorage,
              let start = cs.location(cs.documentRange.location, offsetBy: t.range.location),
              let end = cs.location(start, offsetBy: 1), let tr = NSTextRange(location: start, end: end) else { return false }
        var hit = false
        let origin = textView.textContainerOrigin
        tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, frame, _, _ in
            hit = frame.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -3).contains(point); return false
        }
        // while the caret is on the line the box shows raw "[ ]": clicking just places the caret
        let caretOnLine = textView.selectedRange().location >= line.range.location && textView.selectedRange().location <= line.range.end - 1 && interacted
        guard hit, !caretOnLine else { return false }
        userInteracted()
        let mid = NSRange(location: t.range.location + 1, length: 1)
        textView.apply(EditResult(edits: [TextEdit(mid, t.checked ? " " : "x")], selection: textView.selectedRange()))
        return true
    }

    /// Replaceable so tests do not launch a browser.
    public var linkOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// True when `point` (view coordinates) lies on the displayed text of `range`.
    func point(_ point: NSPoint, hits range: NSRange) -> Bool {
        guard range.length > 0, let tlm = textView.textLayoutManager, let cs = textView.textContentStorage,
              let start = cs.location(cs.documentRange.location, offsetBy: range.location),
              let end = cs.location(start, offsetBy: range.length), let tr = NSTextRange(location: start, end: end) else { return false }
        var hit = false
        let o = textView.textContainerOrigin
        tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, frame, _, _ in
            if frame.width > 0.5, frame.offsetBy(dx: o.x, dy: o.y).insetBy(dx: -1, dy: -2).contains(point) { hit = true; return false }
            return true
        }
        return hit
    }

    /// The link under `point` that is currently shown rendered (its markers hidden): a click there should open it.
    func renderedLink(atPoint p: NSPoint, index idx: Int) -> Run? {
        let text = textView.string as NSString
        guard text.length > 0 else { return nil }
        let i = min(max(idx, 0), text.length - 1)
        let blk = model.block(at: i, in: text)
        // idx may land just after the link when the click is past its last glyph: test the neighbouring runs too
        for r in blk.runs {
            switch r.kind { case .link, .autolink, .footnoteRef: break; default: continue }
            guard r.range.location - 1 <= idx, idx <= r.range.end else { continue }
            let shown = r.content.length > 0 ? r.content : r.range
            if point(p, hits: shown) { return r }
        }
        return nil
    }

    func isRevealed(_ r: Run) -> Bool {
        let s = styler.selection
        guard s.location >= 0 else { return false }
        return s.length > 0 ? NSIntersectionRange(s, r.range).length > 0 : (s.location >= r.range.location && s.location <= r.range.end)
    }

    /// Opens the link under a click. A plain click opens only a link shown rendered; ⌘ (force) opens any link.
    public func openLink(atPoint p: NSPoint, index idx: Int, force: Bool) -> Bool {
        if footnoteDefinitionLabel(atPoint: p, index: idx) != nil, force || !caretOnLine(idx) { return jumpToFootnoteReference(atIndex: idx) }
        guard let run = renderedLink(atPoint: p, index: idx), force || !isRevealed(run) else { return false }
        if run.kind == .footnoteRef { return jumpToFootnoteDefinition(for: run) }
        return open(linkString(run))
    }

    // MARK: footnotes

    /// Where the last footnote click scrolled to (read by tests).
    public private(set) var lastFootnoteJump: NSRange?

    private func caretOnLine(_ idx: Int) -> Bool {
        let t = textView.string as NSString
        guard interacted, t.length > 0 else { return false }
        let line = t.lineRange(for: NSRange(location: min(idx, t.length - 1), length: 0))
        let c = textView.selectedRange().location
        return c >= line.location && c < line.end
    }

    /// The "[^id]:" label under the click, when the definition line is shown rendered.
    func footnoteDefinitionLabel(atPoint p: NSPoint, index idx: Int) -> NSRange? {
        let text = textView.string as NSString
        guard text.length > 0, let (blk, li) = model.line(at: min(max(idx, 0), text.length - 1), in: text) else { return nil }
        let line = blk.lines[li]
        guard line.kind == .footnoteDef, let label = line.number, point(p, hits: label) else { return nil }
        return label
    }

    private func footnoteID(_ label: String) -> String {
        label.trimmingCharacters(in: CharacterSet(charactersIn: "[]^: "))
    }

    private func reveal(_ r: NSRange) {
        textView.scrollRangeToVisible(r)
        textView.showFindIndicator(for: r)      // the system flash, so the landing spot is easy to see
        lastFootnoteJump = r
    }

    /// Reference -> its definition line.
    func jumpToFootnoteDefinition(for run: Run) -> Bool {
        let text = textView.string as NSString
        let id = NSRegularExpression.escapedPattern(for: text.substring(with: run.content))
        let def = text.range(of: "(?m)^ {0,3}\\[\\^\(id)\\]:[^\\n]*", options: .regularExpression)
        guard def.location != NSNotFound else { return false }
        reveal(def)
        return true
    }

    /// Definition label -> the first reference to the same note.
    func jumpToFootnoteReference(atIndex idx: Int) -> Bool {
        let text = textView.string as NSString
        guard text.length > 0, let (blk, li) = model.line(at: min(max(idx, 0), text.length - 1), in: text), let label = blk.lines[li].number else { return false }
        let id = NSRegularExpression.escapedPattern(for: footnoteID(text.substring(with: label)))
        var from = 0
        while from < text.length {
            let r = text.range(of: "\\[\\^\(id)\\]", options: .regularExpression, range: NSRange(location: from, length: text.length - from))
            if r.location == NSNotFound { return false }
            // skip the definition itself (a label at the start of a line followed by ":")
            let isDef = r.end < text.length && text.character(at: r.end) == 0x3A && (r.location == 0 || text.character(at: r.location - 1) == 0x0A || text.character(at: r.location - 1) == 0x20)
            if !isDef { reveal(r); return true }
            from = r.end
        }
        return false
    }

    func linkString(_ run: Run) -> String {
        let text = textView.string as NSString
        switch run.kind {
        case .link(let u): return u
        default: return text.substring(with: run.range).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
    }

    func openLink(at idx: Int) -> Bool {
        guard let run = runAt(idx, { r in if case .link = r.kind { return true }; return r.kind == .autolink }) else { return false }
        let text = textView.string as NSString
        var urlString: String
        switch run.kind {
        case .link(let u): urlString = u
        default: urlString = text.substring(with: run.range).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        return open(urlString)
    }

    @discardableResult
    func open(_ urlString: String) -> Bool {
        if urlString.hasPrefix("#") { return scrollToHeading(slug: String(urlString.dropFirst())) }
        if let u = URL(string: urlString), u.scheme != nil { linkOpener(u); return true }
        if let base = styler.documentURL {
            let target = base.deletingLastPathComponent().appendingPathComponent(urlString.removingPercentEncoding ?? urlString)
            linkOpener(target); return true
        }
        return false
    }

    public static func slug(_ heading: String) -> String {
        var out = ""
        for ch in heading.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) } else if ch == " " { out.append("-") }
        }
        return out
    }

    @discardableResult
    func scrollToHeading(slug: String) -> Bool {
        let text = textView.string as NSString
        var found: NSRange?
        var counts: [String: Int] = [:]
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, stop in
            guard lineRange.length > 1, text.character(at: lineRange.location) == 0x23 else { return }
            var i = lineRange.location
            while i < lineRange.end, text.character(at: i) == 0x23 { i += 1 }
            guard i < lineRange.end, text.character(at: i) == 0x20 else { return }
            let title = text.substring(with: NSRange(location: i + 1, length: lineRange.end - i - 1)).trimmingCharacters(in: .whitespaces)
            var s = Self.slug(title)
            let c = counts[s, default: 0]; counts[s] = c + 1
            if c > 0 { s += "-\(c)" }
            if s == slug { found = lineRange; stop.pointee = true }
        }
        guard let r = found else { return false }
        userInteracted()
        textView.setSelectedRange(NSRange(location: r.location, length: 0))
        textView.scrollRangeToVisible(r)
        return true
    }

    /// Pointing hand over a link that a click would open.
    func updateCursor(at p: NSPoint) {
        guard Settings.shared.openLinksOnClick else { return }
        let idx = textView.characterIndexForInsertion(at: p)
        if let r = renderedLink(atPoint: p, index: idx), !isRevealed(r) { NSCursor.pointingHand.set(); return }
        if footnoteDefinitionLabel(atPoint: p, index: idx) != nil, !caretOnLine(idx) { NSCursor.pointingHand.set() }
    }

    // MARK: diagram context menu

    func addDiagramItems(to menu: NSMenu, at idx: Int) {
        let text = textView.string as NSString
        guard text.length > 0 else { return }
        let blk = model.block(at: min(idx, text.length - 1), in: text)
        guard blk.widget == .mermaid else { return }
        let att = styler.attachments.mermaid(source: blk.widgetSource, maxWidth: styler.columnWidth)
        menu.insertItem(NSMenuItem.separator(), at: 0)
        let png = NSMenuItem(title: "Copy Diagram as PNG", action: #selector(copyDiagramPNG(_:)), keyEquivalent: ""); png.target = self; png.representedObject = att
        let svg = NSMenuItem(title: "Copy Diagram as SVG", action: #selector(copyDiagramSVG(_:)), keyEquivalent: ""); svg.target = self; svg.representedObject = att
        menu.insertItem(svg, at: 0); menu.insertItem(png, at: 0)
    }

    @objc private func copyDiagramPNG(_ sender: NSMenuItem) {
        guard let att = sender.representedObject as? MediaAttachment, let img = att.rendered else { return }
        let size = NSSize(width: img.size.width * 2, height: img.size.height * 2)
        let out = NSImage(size: size, flipped: false) { r in img.draw(in: r); return true }
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png)
    }

    @objc private func copyDiagramSVG(_ sender: NSMenuItem) {
        guard let att = sender.representedObject as? MediaAttachment, let svg = att.svg else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(svg, forType: .string)
    }

    // MARK: accessibility

    /// Rendered text for VoiceOver: the source with hidden syntax markers removed.
    public func plainTextForAccessibility() -> String? {
        let text = textView.string as NSString
        guard text.length < 200_000 else { return nil }
        let out = NSMutableString(string: text)
        var removals: [NSRange] = []
        var seenBlocks = Set<Int>()
        var pos = 0
        while pos < text.length {
            let line = text.lineRange(for: NSRange(location: pos, length: 0))
            let blank = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank { pos = line.end; continue }          // a blank line resolves to its neighbours' block: skip it
            let blk = model.block(at: pos, in: text)
            guard seenBlocks.insert(blk.range.location).inserted else { pos = max(blk.range.end, line.end); continue }
            for l in blk.lines { removals += l.markers }
            for r in blk.runs {
                switch r.kind {
                case .bold, .italic, .strike, .underline, .code, .kbd, .sub, .sup, .mark, .link, .footnoteRef: removals += [r.open, r.close]
                default: break
                }
            }
            pos = max(blk.range.end, pos + 1)
        }
        for r in removals.sorted(by: { $0.location > $1.location }) where r.end <= out.length { out.deleteCharacters(in: r) }
        return out as String
    }
}

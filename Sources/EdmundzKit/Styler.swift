import AppKit
import EdmundzCore

/// Builds the *display* of each paragraph lazily at layout time from the parsed block model. The text storage is never
/// changed; every substitution is length-preserving, so source offsets always equal display offsets.
public final class Styler: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate {
    public let model: DocumentModel
    let settings = Settings.shared
    let attachments = AttachmentFactory()

    /// The selection that drives reveal. Location -1 means "no caret yet" (document just opened): nothing is revealed.
    public var selection = NSRange(location: -1, length: 0)
    public var columnWidth: CGFloat = 700
    public var documentURL: URL? { didSet { attachments.documentURL = documentURL } }

    public private(set) var paragraphCalls = 0
    private let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    private var tableCache: [Int: (gen: Int, widths: [CGFloat])] = [:]
    private var lexCache: [Int: (gen: Int, states: [LexState])] = [:]
    /// Start offsets of `<details>` regions the user has expanded (HTML default is collapsed).
    public var openDetails = Set<Int>()
    /// Families named in the document's front-matter (`font:`, `heading-font:`, `code-font:`); win over Settings.
    public var familyOverrides: [FontRole: String] = [:]

    public init(model: DocumentModel) {
        self.model = model
        super.init()
    }

    // MARK: NSTextContentStorageDelegate

    public func textContentStorage(_ s: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        paragraphCalls += 1
        guard let ts = s.textStorage else { return nil }
        let text = ts.string as NSString
        currentText = text
        guard range.length > 0, let (block, li) = model.line(at: range.location, in: text) else {
            return NSTextParagraph(attributedString: NSAttributedString(string: text.substring(with: range), attributes: baseAttributes()))
        }
        return NSTextParagraph(attributedString: display(text: text, block: block, lineIndex: li, range: range))
    }

    // MARK: NSTextLayoutManagerDelegate

    public func textLayoutManager(_ m: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in element: NSTextElement) -> NSTextLayoutFragment {
        if let p = element as? NSTextParagraph, p.attributedString.length > 0,
           let d = p.attributedString.attribute(.deco, at: 0, effectiveRange: nil) as? Deco {
            return DecoratedFragment(element: element, range: element.elementRange, deco: d)
        }
        return NSTextLayoutFragment(textElement: element, range: element.elementRange)
    }

    // MARK: fonts and paragraph styles

    var bodySize: CGFloat { settings.bodySize }
    func body(bold: Bool = false, italic: Bool = false, size: CGFloat? = nil) -> NSFont { settings.font(.body, size: size ?? bodySize, bold: bold, italic: italic, override: familyOverrides[.body]) }
    func codeFont(size: CGFloat? = nil) -> NSFont { settings.font(.code, size: size ?? bodySize * 0.88, override: familyOverrides[.code]) }
    func headingFont(size: CGFloat) -> NSFont { settings.font(.heading, size: size, bold: true, override: familyOverrides[.heading] ?? familyOverrides[.body]) }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = settings.lineHeight
        return [.font: body(), .foregroundColor: Palette.text, .paragraphStyle: ps]
    }

    private func isCaretIn(_ r: NSRange, strictEnd: Bool = false) -> Bool {
        guard selection.location >= 0 else { return false }
        if selection.length > 0 { return NSIntersectionRange(selection, r).length > 0 || (selection.location >= r.location && selection.end <= r.end) }
        return selection.location >= r.location && (strictEnd ? selection.location < r.end : selection.location <= r.end)
    }

    private func blockRevealed(_ b: ParsedBlock, closed: Bool = true) -> Bool {
        guard selection.location >= 0 else { return false }
        let r = b.range
        if selection.length > 0 { return NSIntersectionRange(selection, r).length > 0 || (selection.location >= r.location && selection.end <= r.end) }
        return selection.location >= r.location && (selection.location < r.end || (selection.location == r.end && !closed))
    }

    // MARK: main entry

    func display(text: NSString, block: ParsedBlock, lineIndex li: Int, range: NSRange) -> NSAttributedString {
        let line = block.lines[li]
        let str = text.substring(with: range)
        let a = NSMutableAttributedString(string: str, attributes: baseAttributes())
        let n = a.length
        let contentEnd = range.location + contentLength(str)
        let caretOnLine = isCaretIn(NSRange(location: range.location, length: contentEnd - range.location))
        let ps = (a.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        if let d = model.fences.details(containing: range.location), let out = detailsLine(d, a, ps, range, caretOnLine: caretOnLine) { return out }

        func local(_ r: NSRange) -> NSRange? {
            let c = NSIntersectionRange(r, range)
            return c.length > 0 ? NSRange(location: c.location - range.location, length: c.length) : nil
        }
        func hide(_ r: NSRange) { if let l = local(r) { a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: l) } }
        func dim(_ r: NSRange) { if let l = local(r) { a.addAttribute(.foregroundColor, value: Palette.marker, range: l) } }
        func collapse(height: CGFloat = 1) {
            a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: 0, length: n))
            ps.minimumLineHeight = height; ps.maximumLineHeight = height; ps.lineHeightMultiple = 0
        }
        func replaceChar(at loc: Int, with s: String) {
            let l = loc - range.location
            guard l >= 0, l < n, (s as NSString).length == 1 else { return }
            a.replaceCharacters(in: NSRange(location: l, length: 1), with: s)
        }
        func replace(_ r: NSRange, with s: String) -> Bool {
            guard let l = local(r), (s as NSString).length == l.length else { return false }
            a.replaceCharacters(in: l, with: s); return true
        }
        func setFont(_ f: NSFont, _ r: NSRange? = nil) { a.addAttribute(.font, value: f, range: r ?? NSRange(location: 0, length: n)) }

        var quoteIndent: CGFloat = 0
        var skipRuns = false
        let revealedBlock = blockRevealed(block, closed: true)

        // MARK: line kind
        switch line.kind {
        case .blank:
            let h = bodySize * 0.6
            ps.minimumLineHeight = h; ps.maximumLineHeight = h; ps.lineHeightMultiple = 0
            skipRuns = true

        case .heading(let level):
            let scale: [CGFloat] = [2.0, 1.6, 1.32, 1.15, 1.05, 1.0]
            let size = bodySize * scale[min(max(level, 1), 6) - 1]
            setFont(headingFont(size: size))
            a.addAttribute(.heading, value: level, range: NSRange(location: 0, length: n))
            if level <= 2 { ps.paragraphSpacingBefore = size * 0.5 } else { ps.paragraphSpacingBefore = size * 0.3 }
            ps.lineHeightMultiple = max(1.1, settings.lineHeight - 0.25)
            if !caretOnLine { line.markers.forEach(hide) } else { line.markers.forEach(dim) }

        case .setextUnderline:
            if caretOnLine { setFont(codeFont()); dim(range) } else { collapse() }
            skipRuns = true

        case .fenceOpen(let lang):
            skipRuns = true
            a.addAttribute(.deco, value: Deco(.code(.top)), range: NSRange(location: 0, length: n))
            if revealedBlock { setFont(codeFont()); a.addAttribute(.foregroundColor, value: Palette.marker, range: NSRange(location: 0, length: n)); ps.lineHeightMultiple = 1.2; ps.firstLineHeadIndent = 0 }
            else { collapse(height: 12) }
            _ = lang

        case .fenceClose:
            skipRuns = true
            a.addAttribute(.deco, value: Deco(.code(.bottom)), range: NSRange(location: 0, length: n))
            if revealedBlock { setFont(codeFont()); a.addAttribute(.foregroundColor, value: Palette.marker, range: NSRange(location: 0, length: n)); ps.lineHeightMultiple = 1.2 }
            else { collapse(height: 12) }

        case .code(let lang):
            skipRuns = true
            setFont(codeFont())
            let isLast = li + 1 < block.lines.count && block.lines[li + 1].kind == .fenceClose
            a.addAttribute(.deco, value: Deco(.code(.middle)), range: NSRange(location: 0, length: n))
            ps.lineHeightMultiple = 1.2
            ps.firstLineHeadIndent = 4; ps.headIndent = 4
            let content = (str as NSString).substring(to: contentLength(str)) as NSString
            let tokens = CodeHighlighter.tokens(in: content, lang: lang, state: lexState(block, li, lang)).0
            for (r, k) in tokens { a.addAttribute(.foregroundColor, value: CodeHighlighter.color(k), range: r) }
            _ = isLast

        case .indentedCode:
            skipRuns = true
            setFont(codeFont()); ps.lineHeightMultiple = 1.2
            a.addAttribute(.deco, value: Deco(.code(.middle)), range: NSRange(location: 0, length: n))

        case .mermaidFence, .mermaidLine, .mathFence, .mathLine:
            skipRuns = true
            styleWidgetLine(a, ps, block, li, str, revealedBlock, collapse: collapse, replaceChar: replaceChar)

        case .frontMatterFence, .frontMatter:
            skipRuns = true
            styleFrontMatter(a, ps, block, li, str, range, revealedBlock, collapse: collapse, hide: hide)

        case .rule:
            skipRuns = true
            ps.minimumLineHeight = 28; ps.lineHeightMultiple = 0
            if caretOnLine { setFont(codeFont()); dim(range) } else { a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: 0, length: n)); a.addAttribute(.deco, value: Deco(.rule), range: NSRange(location: 0, length: n)) }

        case .htmlBlock:
            setFont(codeFont(size: bodySize * 0.8)); a.addAttribute(.foregroundColor, value: Palette.secondary, range: NSRange(location: 0, length: n)); skipRuns = true

        case .htmlComment:
            if caretOnLine || revealedBlock { setFont(codeFont(size: bodySize * 0.8)); a.addAttribute(.foregroundColor, value: Palette.marker, range: NSRange(location: 0, length: n)) } else { collapse() }
            skipRuns = true

        case .footnoteDef:
            setFont(body(size: bodySize * 0.9))
            if let num = line.number { if let l = local(num) { a.addAttributes([.font: body(bold: true, size: bodySize * 0.8), .foregroundColor: Palette.secondary], range: l) } }

        case .tableHeader, .tableRow, .tableDelimiter:
            styleTableLine(a, ps, block, li, range, revealedBlock, collapse: collapse, hide: hide, replace: replace)

        case .paragraph:
            break
        }

        // MARK: containers: quote, alert, list, task
        if line.quoteDepth > 0, !skipRuns || line.kind == .blank {
            quoteIndent = CGFloat(line.quoteDepth) * 16
            let tint = line.alert.map(Palette.alert)
            var role: Deco.Role = .middle
            if line.alert != nil {
                let first = line.alertTitle
                let last = li + 1 >= block.lines.count || block.lines[li + 1].alert == nil
                role = first && last ? .single : first ? .top : last ? .bottom : .middle
            }
            a.addAttribute(.deco, value: Deco(.quote(depth: line.quoteDepth, color: tint, role: role)), range: NSRange(location: 0, length: n))
            if caretOnLine { line.markers.forEach(dim) } else { line.markers.forEach(hide) }
            ps.firstLineHeadIndent = quoteIndent; ps.headIndent = quoteIndent
            if line.alert != nil {   // padding inside the callout tint: above the first line, below the last
                if line.alertTitle { ps.paragraphSpacingBefore = 8 }
                if li + 1 >= block.lines.count || block.lines[li + 1].alert == nil { ps.paragraphSpacing = 8 }
            }
            if line.alertTitle, let tag = (str as NSString).range(of: "[!") as NSRange?, tag.location != NSNotFound {
                let close = (str as NSString).range(of: "]", range: NSRange(location: tag.location, length: n - tag.location))
                if close.location != NSNotFound {
                    let full = NSRange(location: tag.location, length: close.location + 1 - tag.location)
                    if !caretOnLine {
                        hide(NSRange(location: range.location + tag.location, length: 2)); hide(NSRange(location: range.location + close.location, length: 1))
                    }
                    a.addAttributes([.font: body(bold: true, size: bodySize * 0.92), .foregroundColor: line.alert.map(Palette.alert) ?? Palette.secondary],
                                    range: NSRange(location: tag.location + (caretOnLine ? 0 : 2), length: full.length - (caretOnLine ? 0 : 3)))
                }
            }
        } else if line.quoteDepth > 0 {
            quoteIndent = CGFloat(line.quoteDepth) * 16
        }

        if line.bullet != nil || line.number != nil || line.contentStart > 0 && line.listDepth > 0 {
            applyListPrefix(a, ps, line, range, caretOnLine, quoteIndent: quoteIndent, replaceChar: replaceChar, hide: hide, local: local)
        }

        // MARK: inline runs
        if !skipRuns {
            for run in block.runs where run.range.end >= range.location && run.range.location <= range.end {
                if run.range.location == range.end && run.range.length > 0 { continue }
                applyRun(run, a, range, caretOnLine: caretOnLine, local: local, replaceChar: replaceChar, line: line, hide: hide, dim: dim)
            }
        }

        // alert / quote lines inside code etc. fall through; finalize
        a.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: n))
        return a
    }

    private func contentLength(_ s: String) -> Int {
        let ns = s as NSString
        var n = ns.length
        while n > 0, ns.character(at: n - 1) == 0x0A || ns.character(at: n - 1) == 0x0D { n -= 1 }
        return n
    }

    // MARK: <details>

    public func detailsIsOpen(_ d: DetailsSpan) -> Bool { openDetails.contains(d.range.location) || isCaretIn(d.range, strictEnd: true) }

    /// Display for a line inside a `<details>` region, or nil to render it as ordinary Markdown (open interior).
    private func detailsLine(_ d: DetailsSpan, _ a: NSMutableAttributedString, _ ps: NSMutableParagraphStyle, _ range: NSRange, caretOnLine: Bool) -> NSAttributedString? {
        let n = a.length
        let full = NSRange(location: 0, length: n)
        let open = detailsIsOpen(d)
        func collapse() {
            a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: full)
            ps.minimumLineHeight = 1; ps.maximumLineHeight = 1; ps.lineHeightMultiple = 0
            a.addAttribute(.paragraphStyle, value: ps, range: full)
        }
        func raw() {
            a.addAttributes([.font: codeFont(size: bodySize * 0.8), .foregroundColor: Palette.marker], range: full)
            a.addAttribute(.paragraphStyle, value: ps, range: full)
        }
        let isSummary = d.summaryLine.map { $0.location == range.location } ?? false
        if isSummary {
            if caretOnLine { raw(); return a }
            let ns = a.string as NSString
            let sr = ns.range(of: "<summary", options: .caseInsensitive)
            guard sr.location != NSNotFound else { return nil }
            let tagEnd = ns.range(of: ">", range: NSRange(location: sr.location, length: n - sr.location))
            guard tagEnd.location != NSNotFound else { return nil }
            let closeStart = ns.range(of: "</summary", options: .caseInsensitive, range: NSRange(location: tagEnd.end, length: n - tagEnd.end))
            let contentEnd = closeStart.location == NSNotFound ? contentLength(a.string) : closeStart.location
            // hide everything except the arrow (replacing "<") and the summary text
            if sr.location > 0 { a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: 0, length: sr.location)) }
            a.replaceCharacters(in: NSRange(location: sr.location, length: 1), with: open ? "▾" : "▸")
            a.addAttributes([.foregroundColor: Palette.secondary, .font: body(bold: true), .kern: 6], range: NSRange(location: sr.location, length: 1))
            if tagEnd.location > sr.location + 1 { a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: sr.location + 1, length: tagEnd.location - sr.location)) }
            if contentEnd > tagEnd.end { a.addAttributes([.font: body(bold: true), .foregroundColor: Palette.text], range: NSRange(location: tagEnd.end, length: contentEnd - tagEnd.end)) }
            if closeStart.location != NSNotFound { a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: closeStart.location, length: n - closeStart.location)) }
            a.addAttribute(.paragraphStyle, value: ps, range: full)
            return a
        }
        if range.location == d.openLine.location || range.location == d.closeLine.location {
            if caretOnLine { raw() } else { collapse() }
            return a
        }
        if open { return nil }
        collapse()
        return a
    }

    // MARK: code highlighting state

    /// Lexer state at the start of line `li` of a fenced block (block comments, triple quotes and templates span lines).
    /// Computed once per block and edit generation; blocks over 1,000 lines fall back to stateless per-line highlighting.
    private func lexState(_ block: ParsedBlock, _ li: Int, _ lang: String) -> LexState {
        guard CodeHighlighter.isStateful(lang), block.lines.count <= 1000, let text = model.sourceText else { return .normal }
        if let c = lexCache[block.range.location], c.gen == model.generation, li < c.states.count { return c.states[li] }
        var states: [LexState] = []
        var st = LexState.normal
        for l in block.lines {
            states.append(st)
            guard case .code = l.kind else { continue }
            var e = l.range.end
            while e > l.range.location, text.character(at: e - 1) == 0x0A || text.character(at: e - 1) == 0x0D { e -= 1 }
            st = CodeHighlighter.tokens(in: text.substring(with: NSRange(location: l.range.location, length: e - l.range.location)) as NSString, lang: lang, state: st).1
        }
        if lexCache.count > 32 { lexCache.removeAll() }
        lexCache[block.range.location] = (model.generation, states)
        return li < states.count ? states[li] : .normal
    }

    // MARK: lists

    private func applyListPrefix(_ a: NSMutableAttributedString, _ ps: NSMutableParagraphStyle, _ line: LineModel, _ range: NSRange, _ caretOnLine: Bool,
                                 quoteIndent: CGFloat, replaceChar: (Int, String) -> Void, hide: (NSRange) -> Void, local: (NSRange) -> NSRange?) {
        let n = a.length
        if !caretOnLine {
            if let b = line.bullet {
                if line.task != nil {
                    hide(b)   // a task item shows only its checkbox
                } else {
                    let glyphs = ["•", "◦", "▪"]
                    replaceChar(b.location, glyphs[min(max(line.listDepth - 1, 0), 2)])
                    if let l = local(b) { a.addAttribute(.foregroundColor, value: Palette.secondary, range: l) }
                }
            }
            if let num = line.number, let l = local(num) { a.addAttribute(.foregroundColor, value: Palette.secondary, range: l) }
            if let t = line.task, let l = local(t.range), l.length == 3 {
                replaceChar(t.range.location, t.checked ? "☑" : "☐")
                a.addAttribute(.foregroundColor, value: t.checked ? Palette.link : Palette.secondary, range: NSRange(location: l.location, length: 1))
                hide(NSRange(location: t.range.location + 1, length: 2))
                a.addAttribute(.init("edmundz.task"), value: t.checked, range: NSRange(location: l.location, length: 1))
                if t.checked, l.upperBound < n { a.addAttribute(.foregroundColor, value: Palette.secondary, range: NSRange(location: l.upperBound, length: max(0, a.length - l.upperBound))) }
            }
        } else {
            if let b = line.bullet, let l = local(b) { a.addAttribute(.foregroundColor, value: Palette.marker, range: l) }
            if let num = line.number, let l = local(num) { a.addAttribute(.foregroundColor, value: Palette.marker, range: l) }
            if let t = line.task, let l = local(t.range) { a.addAttribute(.foregroundColor, value: Palette.marker, range: l) }
        }
        // hanging indent: width of the (displayed) prefix
        let cs = min(line.contentStart, n)
        if cs > 0 {
            let prefix = a.attributedSubstring(from: NSRange(location: 0, length: cs))
            let w = ceil(prefix.size().width)
            ps.headIndent = w + quoteIndent
            ps.firstLineHeadIndent = quoteIndent
        }
    }

    // MARK: inline runs

    private func addTrait(_ a: NSMutableAttributedString, _ r: NSRange, bold: Bool = false, italic: Bool = false) {
        a.enumerateAttribute(.font, in: r) { v, sub, _ in
            guard let f = v as? NSFont else { return }
            let fm = NSFontManager.shared
            var out = f
            if bold { out = fm.convert(out, toHaveTrait: .boldFontMask) }
            if italic { out = fm.convert(out, toHaveTrait: .italicFontMask) }
            a.addAttribute(.font, value: out, range: sub)
        }
    }

    private func applyRun(_ run: Run, _ a: NSMutableAttributedString, _ range: NSRange, caretOnLine: Bool,
                          local: (NSRange) -> NSRange?, replaceChar: (Int, String) -> Void, line: LineModel,
                          hide: (NSRange) -> Void, dim: (NSRange) -> Void) {
        let reveal = isCaretIn(run.range)
        let content = run.content
        func markers() { if reveal { dim(run.open); dim(run.close) } else { hide(run.open); hide(run.close) } }

        switch run.kind {
        case .bold: if let l = local(content) { addTrait(a, l, bold: true) }; markers()
        case .italic: if let l = local(content) { addTrait(a, l, italic: true) }; markers()
        case .strike:
            if let l = local(content) { a.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Palette.secondary], range: l) }; markers()
        case .underline:
            if let l = local(content) { a.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: l) }; markers()
        case .code:
            if let l = local(content) { a.addAttributes([.font: codeFont(), .backgroundColor: Palette.codeBackground], range: l) }; markers()
        case .kbd:
            if let l = local(content) { a.addAttributes([.font: codeFont(size: bodySize * 0.8), .backgroundColor: Palette.codeBackground], range: l) }; markers()
        case .mark:
            if let l = local(content) { a.addAttribute(.backgroundColor, value: Palette.mark, range: l) }; markers()
        case .sub, .sup:
            if let l = local(content) {
                let up = run.kind == .sup
                a.addAttribute(.baselineOffset, value: (up ? 1 : -1) * bodySize * 0.3, range: l)
                a.enumerateAttribute(.font, in: l) { v, sub, _ in if let f = v as? NSFont { a.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: f.pointSize * 0.72), range: sub) } }
            }
            markers()
        case .link, .autolink:
            if let l = local(content.length > 0 ? content : run.range) {
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: Palette.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
                if case .link(let url) = run.kind { attrs[.init("edmundz.link")] = url }
                a.addAttributes(attrs, range: l)
            }
            markers()
        case .footnoteRef:
            if let l = local(content) {
                a.addAttributes([.foregroundColor: Palette.link, .baselineOffset: bodySize * 0.35, .font: body(size: bodySize * 0.7)], range: l)
            }
            markers()
        case .htmlComment:
            if reveal { dim(run.range) } else { hide(run.range) }
        case .htmlOther:
            if let l = local(run.range) { a.addAttributes([.foregroundColor: Palette.secondary, .font: codeFont(size: bodySize * 0.8)], range: l) }
        case .lineBreak:
            if reveal { dim(run.range) } else {
                replaceChar(run.range.location, "\u{2028}")
                if run.range.length > 1 { hide(NSRange(location: run.range.location + 1, length: run.range.length - 1)) }
            }
        case .emoji(let e):
            let len = (e as NSString).length
            if !reveal, run.range.length >= len, let l = local(NSRange(location: run.range.location, length: len)), l.length == len {
                a.replaceCharacters(in: l, with: e)
                if run.range.length > len { hide(NSRange(location: run.range.location + len, length: run.range.length - len)) }
            }
        case .image(let url, let alt, let size):
            guard run.range.location >= range.location, run.range.location < range.end else { hide(run.range); return }
            let wholeLine = isWholeLine(run, range, a)
            let maxW = max(80, columnWidth - (wholeLine ? 0 : 0) - CGFloat(line.contentStart) * bodySize * 0.5)
            let att = attachments.image(url: url, alt: alt, size: size, maxWidth: maxW, inline: !wholeLine, lineHeight: bodySize * settings.lineHeight)
            place(att, run, a, range, reveal: reveal, hide: hide, dim: dim)
        case .math(let display):
            guard run.range.location >= range.location, run.range.location < range.end else { hide(run.range); return }
            let latex = (mathSource(run, in: a, range))
            let att = attachments.math(latex: latex, display: display, fontSize: bodySize * (display ? 1.15 : 1.0))
            place(att, run, a, range, reveal: reveal, hide: hide, dim: dim)
        }
    }

    /// Source of a math run, recovered from the storage text via the display string offsets (display == source length).
    private var currentText: NSString?
    private func mathSource(_ run: Run, in a: NSMutableAttributedString, _ range: NSRange) -> String {
        guard let t = currentText ?? model.sourceText else { return "" }
        return t.substring(with: run.content)
    }

    private func isWholeLine(_ run: Run, _ range: NSRange, _ a: NSAttributedString) -> Bool {
        let s = a.string as NSString
        let before = run.range.location - range.location
        let after = run.range.end - range.location
        var i = 0
        while i < before, i < s.length { let c = s.character(at: i); if c != 0x20 && c != 0x09 && c != 0x3E && c != 0x2D && c != 0x2A && c != 0x2B && !(c >= 0x30 && c <= 0x39) && c != 0x2E && c != 0x5B && c != 0x5D && c != 0x78 { return false }; i += 1 }
        var j = after
        while j < s.length { let c = s.character(at: j); if c != 0x20 && c != 0x0A && c != 0x0D { return false }; j += 1 }
        return true
    }

    /// Puts the attachment on the first character of the run; the rest is hidden, or dimmed while the run is revealed.
    private func place(_ att: MediaAttachment, _ run: Run, _ a: NSMutableAttributedString, _ range: NSRange, reveal: Bool,
                       hide: (NSRange) -> Void, dim: (NSRange) -> Void) {
        let l = run.range.location - range.location
        guard l >= 0, l < a.length else { return }
        a.replaceCharacters(in: NSRange(location: l, length: 1), with: "\u{FFFC}")
        a.addAttribute(.attachment, value: att, range: NSRange(location: l, length: 1))
        let rest = NSRange(location: run.range.location + 1, length: run.range.length - 1)
        if rest.length > 0 { if reveal { dim(rest) } else { hide(rest) } }
    }

    // MARK: widgets (mermaid, display math)

    private func styleWidgetLine(_ a: NSMutableAttributedString, _ ps: NSMutableParagraphStyle, _ block: ParsedBlock, _ li: Int, _ str: String, _ revealed: Bool,
                                 collapse: (CGFloat) -> Void, replaceChar: (Int, String) -> Void) {
        let n = a.length
        let count = block.lines.count
        let isLast = li == count - 1
        let line = block.lines[li]
        let full = NSRange(location: 0, length: n)
        // the closing fence ("```" or "$$" on its own line) carries the picture; an unclosed block has none yet
        let lastKind = block.lines[count - 1].kind
        let blockClosed = (lastKind == .mermaidFence || lastKind == .mathFence) && count > 1
        let closing = isLast && blockClosed
        if !revealed {
            if !isLast { collapse(1); return }
            // the whole block is one image on its last line
            collapse(1); ps.minimumLineHeight = 0; ps.maximumLineHeight = 0; ps.lineHeightMultiple = 1
            ps.alignment = .center
            attachWidget(a, block, line, at: 0, ps)
            return
        }
        // editing: the source sits in a rounded panel that ends at its last line, and the picture lies below it on the page
        let panelLast = blockClosed ? count - 2 : count - 1
        if li <= panelLast {
            a.addAttributes([.font: codeFont(), .foregroundColor: li == 0 ? Palette.marker : Palette.text], range: full)
            let role: Deco.Role = panelLast == 0 ? .single : (li == 0 ? .top : (li == panelLast ? .bottom : .middle))
            a.addAttribute(.deco, value: Deco(.code(role)), range: full)
            ps.lineHeightMultiple = 1.2; ps.firstLineHeadIndent = 4; ps.headIndent = 4
            if li == panelLast { ps.paragraphSpacing = 8 }      // padding under the last line of source inside the panel
        }
        if closing {
            // no panel here: the diagram or formula is centered inside the column, with space above and below
            ps.firstLineHeadIndent = 0; ps.headIndent = 0
            ps.alignment = .center
            ps.paragraphSpacingBefore = 12; ps.paragraphSpacing = 8
            ps.lineHeightMultiple = 1
            attachWidget(a, block, line, at: 0, ps, maxWidth: columnWidth - 12)
        }
    }

    private func attachWidget(_ a: NSMutableAttributedString, _ block: ParsedBlock, _ line: LineModel, at idx: Int, _ ps: NSMutableParagraphStyle, maxWidth: CGFloat? = nil) {
        guard let kind = block.widget else { return }
        let att: MediaAttachment
        switch kind {
        case .mermaid: att = attachments.mermaid(source: block.widgetSource, maxWidth: maxWidth ?? columnWidth)
        case .mathBlock: att = attachments.math(latex: block.widgetSource, display: true, fontSize: bodySize * 1.25)
        }
        a.replaceCharacters(in: NSRange(location: idx, length: 1), with: "\u{FFFC}")
        a.addAttribute(.attachment, value: att, range: NSRange(location: idx, length: 1))
        a.addAttribute(.font, value: body(), range: NSRange(location: idx, length: 1))
        a.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: idx, length: 1))
        if a.length > 1 {
            // the rest of the line is the fence text: hidden while the picture shows
            a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: 1, length: a.length - 1))
        }
    }

    // MARK: front matter

    private func styleFrontMatter(_ a: NSMutableAttributedString, _ ps: NSMutableParagraphStyle, _ block: ParsedBlock, _ li: Int, _ str: String, _ range: NSRange,
                                  _ revealed: Bool, collapse: (CGFloat) -> Void, hide: (NSRange) -> Void) {
        let n = a.length
        let full = NSRange(location: 0, length: n)
        let isFence = block.lines[li].kind == .frontMatterFence
        let role: Deco.Role = li == 0 ? .top : (li == block.lines.count - 1 ? .bottom : .middle)
        if !settings.showFrontMatter && !revealed { collapse(1); return }
        if revealed {
            a.addAttributes([.font: codeFont(), .foregroundColor: isFence ? Palette.marker : Palette.text], range: full)
            a.addAttribute(.deco, value: Deco(.frontMatter(role)), range: full)
            ps.lineHeightMultiple = 1.2; ps.firstLineHeadIndent = 4; ps.headIndent = 4
            return
        }
        a.addAttribute(.deco, value: Deco(.frontMatter(role)), range: full)
        if isFence { collapse(10); return }
        let small = body(size: bodySize * 0.86)
        a.addAttributes([.font: small, .foregroundColor: Palette.secondary], range: full)
        ps.firstLineHeadIndent = 6; ps.headIndent = 6; ps.lineHeightMultiple = 1.3
        let ns = str as NSString
        let colon = ns.range(of: ":")
        if colon.location != NSNotFound, colon.location > 0 {
            a.addAttributes([.font: body(bold: true, size: bodySize * 0.86), .foregroundColor: Palette.text], range: NSRange(location: 0, length: colon.location))
            if colon.location + 1 < n {
                // chips for list values such as tags: [a, b]
                let key = ns.substring(to: colon.location).lowercased()
                if key == "tags" || key == "tag" || key == "keywords" || key == "categories" {
                    var i = colon.location + 1
                    var start = -1
                    while i < ns.length {
                        let c = ns.character(at: i)
                        let sep = c == 0x2C || c == 0x5B || c == 0x5D || c == 0x0A || c == 0x0D || c == 0x20 && start < 0
                        if sep || c == 0x20 && false {
                            if start >= 0 { chip(a, NSRange(location: start, length: i - start)); start = -1 }
                            if c == 0x5B || c == 0x5D { hide(NSRange(location: range.location + i, length: 1)) }
                        } else if start < 0 { start = i }
                        i += 1
                    }
                    if start >= 0 { chip(a, NSRange(location: start, length: ns.length - start)) }
                }
            }
        }
    }

    private func chip(_ a: NSMutableAttributedString, _ r: NSRange) {
        var rr = r
        while rr.length > 0, (a.string as NSString).character(at: rr.end - 1) == 0x20 { rr.length -= 1 }
        guard rr.length > 0 else { return }
        a.addAttributes([.backgroundColor: Palette.link.withAlphaComponent(0.16), .foregroundColor: Palette.link], range: rr)
    }

    // MARK: tables

    private func styleTableLine(_ a: NSMutableAttributedString, _ ps: NSMutableParagraphStyle, _ block: ParsedBlock, _ li: Int, _ range: NSRange,
                                _ revealed: Bool, collapse: (CGFloat) -> Void, hide: (NSRange) -> Void, replace: (NSRange, String) -> Bool) {
        let line = block.lines[li]
        let n = a.length
        let full = NSRange(location: 0, length: n)
        if revealed {
            a.addAttributes([.font: codeFont(), .foregroundColor: Palette.text], range: full)
            let role: Deco.Role = block.lines.count == 1 ? .single : (li == 0 ? .top : (li == block.lines.count - 1 ? .bottom : .middle))
            a.addAttribute(.deco, value: Deco(.code(role)), range: full)
            ps.lineHeightMultiple = 1.2; ps.firstLineHeadIndent = 4; ps.headIndent = 4
            return
        }
        let widths = columnWidths(for: block)
        var edges: [CGFloat] = [0]
        for w in widths { edges.append((edges.last ?? 0) + w) }
        if line.kind == .tableDelimiter {
            collapse(1)
            a.addAttribute(.deco, value: Deco(.tableRow(header: false, last: false, totalWidth: edges.last ?? 0, edges: edges, gridOnly: true)), range: NSRange(location: 0, length: n))
            return
        }
        guard let t = line.table else { return }
        let isHeader = line.kind == .tableHeader
        let pad: CGFloat = 10
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for (i, w) in widths.enumerated() {
            let align = i < t.alignments.count ? t.alignments[i] : .none
            switch align {
            case .center: stops.append(NSTextTab(textAlignment: .center, location: x + w / 2))
            case .right: stops.append(NSTextTab(textAlignment: .right, location: x + w - pad))
            default: stops.append(NSTextTab(textAlignment: .left, location: x + pad))
            }
            x += w
        }
        ps.tabStops = stops; ps.defaultTabInterval = 0
        ps.lineBreakMode = .byClipping
        let total = x
        // pipes become tabs (same length); a trailing pipe and the padding spaces are hidden
        let first = t.cells.first?.location ?? 0
        let leadingPipe = t.pipes.first.map { $0.location < first } ?? false
        for (k, p) in t.pipes.enumerated() {
            let isTrailing = k == t.pipes.count - 1 && (t.cells.last.map { p.location >= $0.end } ?? true) && (k > 0 || !leadingPipe)
            if isTrailing || (!leadingPipe && k == 0 && false) { hide(p) } else { _ = replace(p, "\t") }
        }
        if !leadingPipe { ps.firstLineHeadIndent = pad }
        // hide whitespace between pipes and cell text
        let ns = a.string as NSString
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x20 || c == 0x09 && false {
                let abs = range.location + i
                let inCell = t.cells.contains { abs >= $0.location && abs < $0.end }
                if !inCell { a.addAttributes([.font: hiddenFont], range: NSRange(location: i, length: 1)) }
            }
            i += 1
        }
        if isHeader { a.enumerateAttribute(.font, in: full) { v, r, _ in if let f = v as? NSFont, f.pointSize > 1 { a.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask), range: r) } } }
        let isLastRow = li == block.lines.count - 1
        a.addAttribute(.deco, value: Deco(.tableRow(header: isHeader, last: isLastRow, totalWidth: total, edges: edges, gridOnly: false)), range: full)
        ps.lineHeightMultiple = 1.5
    }

    private func columnWidths(for block: ParsedBlock) -> [CGFloat] {
        if let c = tableCache[block.range.location], c.gen == model.generation { return c.widths }
        var widths: [CGFloat] = []
        guard let text = model.sourceText else { return [] }
        for l in block.lines {
            guard let t = l.table, l.kind != .tableDelimiter else { continue }
            let font = l.kind == .tableHeader ? body(bold: true) : body()
            for (i, c) in t.cells.enumerated() {
                let w = ceil(text.substring(with: c).size(withAttributes: [.font: font]).width) + 28
                if i >= widths.count { widths.append(w) } else { widths[i] = max(widths[i], w) }
            }
        }
        if tableCache.count > 64 { tableCache.removeAll() }
        tableCache[block.range.location] = (model.generation, widths)
        return widths
    }
}

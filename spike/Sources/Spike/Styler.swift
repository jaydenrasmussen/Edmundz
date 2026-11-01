import AppKit

enum SpanKind { case bold, italic, code }

struct Span {
    var kind: SpanKind
    var open: NSRange
    var content: NSRange
    var close: NSRange
    var whole: NSRange { NSRange(location: open.location, length: close.upperBound - open.location) }
}

/// Computes display attributes lazily, per paragraph, at layout time.
/// The text storage is never mutated: it always equals the file.
final class Styler: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate {
    let base = NSFont.systemFont(ofSize: 16)
    lazy var bold = NSFont.systemFont(ofSize: 16, weight: .bold)
    lazy var italic: NSFont = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    lazy var code = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    var caret: Int = -1
    var imageColumnWidth: CGFloat = 760
    static let imageRegex = try! NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(([^)\s]+)\)\s*$"#)
    var paragraphCalls = 0

    static let hiddenKey = NSAttributedString.Key("edmundz.hidden")

    func textContentStorage(_ s: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        paragraphCalls += 1
        guard let ts = s.textStorage else { return nil }
        let text = ts.attributedSubstring(from: range).string
        let a = NSMutableAttributedString(string: text)
        let localCaret = (caret >= range.location && caret <= range.upperBound) ? caret - range.location : nil
        if styleRule(a, caret: localCaret) {}
        else if styleTable(a, range: range, in: ts.string as NSString, caret: localCaret) {}
        else if !styleImage(a, caret: localCaret) { style(a, caret: localCaret) }
        return NSTextParagraph(attributedString: a)
    }

    // MARK: horizontal rule, drawn by a custom layout fragment

    func styleRule(_ a: NSMutableAttributedString, caret: Int?) -> Bool {
        let t = a.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t == "---" || t == "***" || t == "___" else { return false }
        let ps = NSMutableParagraphStyle(); ps.minimumLineHeight = 28
        let full = NSRange(location: 0, length: a.length)
        a.setAttributes([.font: base, .paragraphStyle: ps, .foregroundColor: NSColor.tertiaryLabelColor, Styler.ruleKey: true], range: full)
        if caret == nil { a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: full) }
        return true
    }
    static let ruleKey = NSAttributedString.Key("edmundz.rule")

    func textLayoutManager(_ m: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in element: NSTextElement) -> NSTextLayoutFragment {
        if let p = element as? NSTextParagraph, p.attributedString.length > 0,
           p.attributedString.attribute(Styler.ruleKey, at: 0, effectiveRange: nil) != nil {
            return RuleFragment(textElement: element, range: element.elementRange)
        }
        return NSTextLayoutFragment(textElement: element, range: element.elementRange)
    }

    // MARK: tables: rows are separate paragraphs; "|" becomes a tab and tab stops align the columns

    static let delimRow = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)
    var tableCache = NSCache<NSString, NSArray>()
    var tableWidthCalls = 0

    func isTableLine(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).hasPrefix("|") }

    func styleTable(_ a: NSMutableAttributedString, range: NSRange, in ns: NSString, caret: Int?) -> Bool {
        guard isTableLine(a.string) else { return false }
        // find the contiguous block of table lines around this row
        var first = range, last = range
        while first.location > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: first.location - 1, length: 0))
            if isTableLine(ns.substring(with: prev)) { first = prev } else { break }
        }
        while last.upperBound < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: last.upperBound, length: 0))
            if isTableLine(ns.substring(with: next)) { last = next } else { break }
        }
        let block = NSRange(location: first.location, length: last.upperBound - first.location)
        let text = ns.substring(with: block)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2, Styler.delimRow.firstMatch(in: lines[1], range: NSRange(location: 0, length: (lines[1] as NSString).length)) != nil else { return false }
        let rowIndex = ns.substring(with: NSRange(location: first.location, length: range.location - first.location)).split(separator: "\n", omittingEmptySubsequences: true).count
        let full = NSRange(location: 0, length: a.length)
        if caret != nil { // raw source while the caret is in this row
            a.setAttributes([.font: code, .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.4)], range: full); return true
        }
        if rowIndex == 1 { // delimiter row: collapsed
            let ps = NSMutableParagraphStyle(); ps.maximumLineHeight = 2; ps.minimumLineHeight = 2
            a.setAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: ps], range: full); return true
        }
        var widths: [CGFloat]
        if let cached = tableCache.object(forKey: text as NSString) as? [CGFloat] { widths = cached } else {
            tableWidthCalls += 1
            widths = []
            for (ri, line) in lines.enumerated() where ri != 1 {
                let cells = cellsOf(line)
                for (ci, c) in cells.enumerated() {
                    let w = (c as NSString).size(withAttributes: [.font: ri == 0 ? bold : base]).width + 24
                    if ci >= widths.count { widths.append(w) } else { widths[ci] = max(widths[ci], w) }
                }
            }
            tableCache.setObject(widths as NSArray, forKey: text as NSString)
        }
        let ps = NSMutableParagraphStyle()
        var x: CGFloat = 6
        var stops = [NSTextTab(textAlignment: .left, location: x)]          // leading "|" -> first cell starts here
        for w in widths { x += w; stops.append(NSTextTab(textAlignment: .left, location: x)) }   // later "|" -> next cell
        ps.tabStops = stops
        ps.lineBreakMode = .byClipping
        a.setAttributes([.font: rowIndex == 0 ? bold : base, .foregroundColor: NSColor.labelColor, .paragraphStyle: ps], range: full)
        if rowIndex % 2 == 0 && rowIndex > 0 { a.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.05), range: full) }
        let ns2 = a.string as NSString
        for i in 0..<ns2.length {
            let ch = ns2.character(at: i)
            if ch == 0x7C {
                // same length: offsets stay 1:1. The trailing "|" is hidden instead of becoming a tab.
                let trailing = (a.string as NSString).substring(from: i + 1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if trailing { a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: i, length: 1)) }
                else { a.replaceCharacters(in: NSRange(location: i, length: 1), with: "\t") }
            }
        }
        return true
    }

    func cellsOf(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// A paragraph that is only `![alt](path)`: the "!" becomes the image attachment (same length, so offsets map 1:1);
    /// the rest of the source is hidden, or shown dimmed after the image while the caret is on this line.
    func styleImage(_ a: NSMutableAttributedString, caret: Int?) -> Bool {
        let n = a.length
        guard n > 4, a.string.hasPrefix("![") else { return false }
        let ns = a.string as NSString
        guard let m = Styler.imageRegex.firstMatch(in: a.string, range: NSRange(location: 0, length: n)) else { return false }
        let path = ns.substring(with: m.range(at: 2)); if styleImageDebug < 3 { styleImageDebug += 1; print("styleImage path=\(path) size=\(String(describing: ImageCache.pixelSize(URL(fileURLWithPath: path))))") }
        let url = URL(fileURLWithPath: path)
        guard let px = ImageCache.pixelSize(url) else { return false }
        let w = min(imageColumnWidth, px.width / 2), h = w * px.height / px.width   // never upscale beyond 2x pixels per point
        a.setAttributes([.font: base, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: n))
        a.replaceCharacters(in: NSRange(location: 0, length: 1), with: "\u{FFFC}")
        a.addAttribute(.attachment, value: LazyImageAttachment(url: url, displaySize: CGSize(width: w, height: h)), range: NSRange(location: 0, length: 1))
        let rest = NSRange(location: 1, length: n - 1)
        if caret != nil { a.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: rest) }
        else { a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: rest) }
        return true
    }

    func style(_ a: NSMutableAttributedString, caret: Int?) {
        let n = a.length
        a.setAttributes([.font: base, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: n))
        let ns = a.string as NSString
        var buf = [unichar](repeating: 0, count: n)
        ns.getCharacters(&buf, range: NSRange(location: 0, length: n))

        // Heading: "# " ... "###### "
        var level = 0
        while level < n && level < 6 && buf[level] == 0x23 { level += 1 }
        if level > 0 && level < n && buf[level] == 0x20 {
            let size = 16 + CGFloat(7 - level) * 3
            a.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: NSRange(location: 0, length: n))
            let marker = NSRange(location: 0, length: level + 1)
            let reveal = caret.map { $0 <= level + 1 } ?? false
            mark(a, marker, reveal: reveal)
        }

        for sp in scan(buf) {
            let reveal = caret.map { $0 >= sp.whole.location && $0 <= sp.whole.upperBound } ?? false
            switch sp.kind {
            case .bold: a.addAttribute(.font, value: bold, range: sp.content)
            case .italic: a.addAttribute(.font, value: italic, range: sp.content)
            case .code:
                a.addAttribute(.font, value: code, range: sp.content)
                a.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: sp.content)
            }
            mark(a, sp.open, reveal: reveal)
            mark(a, sp.close, reveal: reveal)
        }
    }

    private func mark(_ a: NSMutableAttributedString, _ r: NSRange, reveal: Bool) {
        if reveal {
            a.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
        } else {
            a.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, Styler.hiddenKey: true], range: r)
        }
    }

    func scan(_ b: [unichar]) -> [Span] {
        var spans: [Span] = []
        let n = b.count
        var i = 0
        let star: unichar = 0x2A, tick: unichar = 0x60
        while i < n {
            let c = b[i]
            if c == tick {
                var j = i + 1
                while j < n && b[j] != tick { j += 1 }
                if j < n && j > i + 1 {
                    spans.append(Span(kind: .code, open: NSRange(location: i, length: 1),
                                      content: NSRange(location: i + 1, length: j - i - 1),
                                      close: NSRange(location: j, length: 1)))
                    i = j + 1; continue
                }
            } else if c == star {
                if i + 1 < n && b[i + 1] == star {
                    var j = i + 2
                    while j + 1 < n && !(b[j] == star && b[j + 1] == star) { j += 1 }
                    if j + 1 < n && j > i + 2 {
                        spans.append(Span(kind: .bold, open: NSRange(location: i, length: 2),
                                          content: NSRange(location: i + 2, length: j - i - 2),
                                          close: NSRange(location: j, length: 2)))
                        i = j + 2; continue
                    }
                } else {
                    var j = i + 1
                    while j < n && b[j] != star { j += 1 }
                    if j < n && j > i + 1 {
                        spans.append(Span(kind: .italic, open: NSRange(location: i, length: 1),
                                          content: NSRange(location: i + 1, length: j - i - 1),
                                          close: NSRange(location: j, length: 1)))
                        i = j + 1; continue
                    }
                }
            }
            i += 1
        }
        return spans
    }
}
var styleImageDebug = 0

final class RuleFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in ctx: CGContext) {
        let w = textLayoutManager?.textContainer?.size.width ?? 600
        let y = point.y + layoutFragmentFrame.height / 2
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: point.x + 5, y: y)); ctx.addLine(to: CGPoint(x: point.x + w - 5, y: y)); ctx.strokePath()
        super.draw(at: point, in: ctx)
    }
    override var renderingSurfaceBounds: CGRect {
        var r = super.renderingSurfaceBounds
        r.size.width = max(r.width, textLayoutManager?.textContainer?.size.width ?? 600)
        return r
    }
}

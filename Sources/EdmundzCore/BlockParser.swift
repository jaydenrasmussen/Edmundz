import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Turns one block of Markdown into per-line models and inline runs, in absolute document offsets.
public enum BlockParser {
    typealias Node = UnsafeMutablePointer<cmark_node>

    private static let registered: Void = { cmark_gfm_core_extensions_ensure_registered() }()

    static func attributes(of tag: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let re = try? NSRegularExpression(pattern: #"([A-Za-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return out }
        let ns = tag as NSString
        for m in re.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let v = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : (m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : "")
            out[ns.substring(with: m.range(at: 1)).lowercased()] = v
        }
        return out
    }

    static func parseSize(_ attrs: String) -> ImageSize {
        var size = ImageSize()
        for part in attrs.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let v = Double(kv[1].replacingOccurrences(of: "px", with: ""))
            if kv[0] == "width" { size.width = v } else if kv[0] == "height" { size.height = v }
        }
        return size
    }

    // MARK: fences (parsed without cmark)

    public static func parseFence(_ span: FenceSpan, in text: NSString) -> ParsedBlock {
        var lines: [LineModel] = []
        var p = span.range.location
        var idx = 0
        let end = span.range.end
        var interior = NSRange(location: span.range.location, length: 0)
        while p < end {
            var ls = 0, le = 0, ce = 0
            text.getLineStart(&ls, end: &le, contentsEnd: &ce, for: NSRange(location: p, length: 0))
            var m = LineModel(range: NSRange(location: ls, length: le - ls))
            let isFirst = idx == 0
            let isLast = span.closed && le >= end
            let whole = [NSRange(location: ls, length: ce - ls)]
            switch span.kind {
            case .code(let lang):
                if isFirst { m.kind = .fenceOpen(lang: lang); m.markers = whole }
                else if isLast { m.kind = .fenceClose; m.markers = whole }
                else { m.kind = .code(lang: lang) }
            case .mermaid:
                if isFirst || isLast { m.kind = .mermaidFence; m.markers = whole } else { m.kind = .mermaidLine }
                m.widgetIndex = idx
            case .math:
                let t = text.substring(with: NSRange(location: ls, length: ce - ls)).trimmingCharacters(in: .whitespaces)
                m.kind = (t == "$$") ? .mathFence : .mathLine
                m.widgetIndex = idx
            case .frontMatter:
                if isFirst || isLast { m.kind = .frontMatterFence; m.markers = whole } else { m.kind = .frontMatter }
            }
            if !isFirst && !isLast && interior.location == span.range.location { interior.location = ls }
            if !isLast { interior.length = max(interior.length, le - interior.location) }
            lines.append(m)
            p = le; idx += 1
        }
        var block = ParsedBlock(range: span.range, lines: lines, runs: [])
        switch span.kind {
        case .mermaid:
            block.widget = .mermaid
            block.widgetSource = interior.length > 0 ? text.substring(with: interior) : ""
        case .math:
            block.widget = .mathBlock
            var s = text.substring(with: span.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("$$") { s.removeFirst(2) }
            if s.hasSuffix("$$") { s.removeLast(2) }
            block.widgetSource = s.trimmingCharacters(in: .whitespacesAndNewlines)
        default: break
        }
        return block
    }

    // MARK: chunks (cmark)

    public static func parse(chunk: NSRange, in text: NSString) -> ParsedBlock {
        _ = registered
        let src = text.substring(with: chunk) as NSString
        let base = chunk.location

        struct Line { var start: Int; var end: Int; var contentEnd: Int; var ascii: Bool; var str: String }
        var table: [Line] = []
        var p = 0
        while p < src.length {
            var ls = 0, le = 0, ce = 0
            src.getLineStart(&ls, end: &le, contentsEnd: &ce, for: NSRange(location: p, length: 0))
            let s = src.substring(with: NSRange(location: ls, length: ce - ls))
            table.append(Line(start: ls, end: le, contentEnd: ce, ascii: s.utf8.count == (ce - ls), str: s))
            p = le
        }

        var models = table.map { l -> LineModel in
            var m = LineModel(range: NSRange(location: base + l.start, length: l.end - l.start))
            if l.str.allSatisfy({ $0 == " " || $0 == "\t" }) { m.kind = .blank }
            return m
        }

        let mathSpans = MathScanner.scan(src)
        let masked = MathScanner.mask(src, spans: mathSpans)

        // 1-based cmark line/col (col in UTF-8 bytes) -> block-relative UTF-16 offset
        func offset(_ line: Int32, _ col: Int32, exclusiveEnd: Bool = false) -> Int? {
            let li = Int(line) - 1
            guard li >= 0, li < table.count else { return nil }
            let l = table[li]
            let c = Int(col) + (exclusiveEnd ? 0 : -1)
            if c < 0 { return nil }
            if l.ascii { return min(l.start + c, l.contentEnd) }
            let u8 = l.str.utf8
            let idx = u8.index(u8.startIndex, offsetBy: min(c, u8.count))
            return l.start + idx.utf16Offset(in: l.str)
        }
        func startOf(_ n: Node) -> Int? { offset(cmark_node_get_start_line(n), cmark_node_get_start_column(n)) }
        func endOf(_ n: Node) -> Int? { offset(cmark_node_get_end_line(n), cmark_node_get_end_column(n), exclusiveEnd: true) }
        func lineOf(_ off: Int) -> Int {
            var lo = 0, hi = table.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if table[mid].start <= off { lo = mid } else { hi = mid - 1 } }
            return lo
        }
        func ch(_ off: Int) -> unichar { off >= 0 && off < src.length ? src.character(at: off) : 0 }
        func name(_ n: Node) -> String { String(cString: cmark_node_get_type_string(n)) }
        func lastLine(_ n: Node) -> Int {
            var e = Int(cmark_node_get_end_line(n)) - 1
            if cmark_node_get_end_column(n) == 0 { e -= 1 }
            return min(max(e, Int(cmark_node_get_start_line(n)) - 1), table.count - 1)
        }
        func abs(_ r: NSRange) -> NSRange { NSRange(location: base + r.location, length: r.length) }

        var runs: [Run] = []
        var tagEvents: [(name: String, close: Bool, range: NSRange)] = []

        // search ±10 within the line for one of `expected` at/near `off`; returns corrected offset
        func fixStart(_ off: Int, _ expected: [unichar]) -> Int? {
            if expected.contains(ch(off)) { return off }
            let li = lineOf(min(max(off, 0), max(src.length - 1, 0)))
            for d in 1...10 {
                for cand in [off - d, off + d] where cand >= table[li].start && cand < table[li].contentEnd && expected.contains(ch(cand)) { return cand }
            }
            return nil
        }
        func fixEnd(_ off: Int, _ expected: [unichar]) -> Int? {  // off exclusive; char at off-1
            if expected.contains(ch(off - 1)) { return off }
            for d in 1...10 {
                for cand in [off - d, off + d] where cand > 0 && cand <= src.length && expected.contains(ch(cand - 1)) { return cand }
            }
            return nil
        }

        // MARK: inline

        func inlines(_ parent: Node) {
            var child = cmark_node_first_child(parent)
            while let c = child { inline(c); child = cmark_node_next(c) }
        }

        func inline(_ n: Node) {
            let t = name(n)
            guard let s0 = startOf(n), let e0 = endOf(n), e0 > s0 else { if t == "emph" || t == "strong" || t == "strikethrough" || t == "link" { inlines(n) }; return }
            switch t {
            case "emph", "strong":
                let delims: [unichar] = [0x2A, 0x5F]
                if let s = fixStart(s0, delims), let e = fixEnd(e0 + (s - s0), delims) {
                    let len = t == "strong" ? 2 : 1
                    if e - s >= 2 * len + 1 {
                        let kind: RunKind = t == "strong" ? .bold : .italic
                        runs.append(Run(kind: kind, range: abs(NSRange(location: s, length: e - s)),
                                        open: abs(NSRange(location: s, length: len)), close: abs(NSRange(location: e - len, length: len))))
                    }
                }
                inlines(n)
            case "strikethrough":
                if let s = fixStart(s0, [0x7E]), let e = fixEnd(e0 + (s - s0), [0x7E]) {
                    let len = (ch(s + 1) == 0x7E && e - s >= 5) ? 2 : 1
                    runs.append(Run(kind: .strike, range: abs(NSRange(location: s, length: e - s)),
                                    open: abs(NSRange(location: s, length: len)), close: abs(NSRange(location: e - len, length: len))))
                }
                inlines(n)
            case "code":
                // cmark reports only the content; the backtick runs sit on either side of it
                var os = s0, oe = e0
                while os > 0, ch(os - 1) == 0x60 { os -= 1 }
                while oe < src.length, ch(oe) == 0x60 { oe += 1 }
                if s0 - os > 0, oe - e0 > 0 {
                    runs.append(Run(kind: .code, range: abs(NSRange(location: os, length: oe - os)),
                                    open: abs(NSRange(location: os, length: s0 - os)), close: abs(NSRange(location: e0, length: oe - e0))))
                }
            case "link":
                let url = cmark_node_get_url(n).map { String(cString: $0) } ?? ""
                var childEnd: Int? = nil
                if let last = cmark_node_last_child(n) { childEnd = endOf(last) }
                if ch(s0) == 0x5B, let e = fixEnd(e0, [0x29, 0x5D]) {
                    let closeStart = max(s0 + 1, childEnd ?? (s0 + 1))
                    runs.append(Run(kind: .link(url: url), range: abs(NSRange(location: s0, length: e - s0)),
                                    open: abs(NSRange(location: s0, length: 1)), close: abs(NSRange(location: closeStart, length: e - closeStart))))
                } else if ch(s0) == 0x3C {
                    runs.append(Run(kind: .autolink, range: abs(NSRange(location: s0, length: e0 - s0)),
                                    open: abs(NSRange(location: s0, length: 1)), close: abs(NSRange(location: e0 - 1, length: 1))))
                } else {
                    // cmark's autolink extension can report columns off by one after an earlier link: anchor on the URL text itself
                    var rs = s0, re = e0
                    if let first = cmark_node_first_child(n), let lit = cmark_node_get_literal(first) {
                        let text = String(cString: lit) as NSString
                        let lo = max(0, s0 - 4), hi = min(src.length, e0 + 4)
                        let found = src.range(of: text as String, options: [], range: NSRange(location: lo, length: max(0, hi - lo)))
                        if found.location != NSNotFound { rs = found.location; re = found.end }
                    }
                    runs.append(Run(kind: .autolink, range: abs(NSRange(location: rs, length: re - rs)),
                                    open: abs(NSRange(location: rs, length: 0)), close: abs(NSRange(location: re, length: 0))))
                }
                inlines(n)
            case "image":
                let url = cmark_node_get_url(n).map { String(cString: $0) } ?? ""
                var alt = ""
                var c = cmark_node_first_child(n)
                while let k = c { if let lit = cmark_node_get_literal(k) { alt += String(cString: lit) }; c = cmark_node_next(k) }
                if ch(s0) == 0x21 {
                    // optional "{width=300 height=200}" directly after the image
                    var e = e0
                    var size: ImageSize? = nil
                    if ch(e0) == 0x7B {
                        var j = e0 + 1
                        while j < src.length, ch(j) != 0x7D, ch(j) != 0x0A { j += 1 }
                        if j < src.length, ch(j) == 0x7D {
                            let attrs = src.substring(with: NSRange(location: e0 + 1, length: j - e0 - 1))
                            let parsed = BlockParser.parseSize(attrs)
                            if parsed.width != nil || parsed.height != nil { size = parsed; e = j + 1 }
                        }
                    }
                    runs.append(Run(kind: .image(url: url, alt: alt, size: size), range: abs(NSRange(location: s0, length: e - s0)),
                                    open: abs(NSRange(location: s0, length: 0)), close: abs(NSRange(location: e, length: 0))))
                }
            case "html_inline":
                let lit = cmark_node_get_literal(n).map { String(cString: $0) } ?? ""
                let r = abs(NSRange(location: s0, length: e0 - s0))
                if lit.hasPrefix("<!--") { runs.append(Run(kind: .htmlComment, range: r, open: r, close: NSRange(location: r.end, length: 0))); return }
                var nm = ""
                var isClose = false
                var it = lit.dropFirst()
                if it.first == "/" { isClose = true; it = it.dropFirst() }
                nm = String(it.prefix { $0.isLetter || $0.isNumber }).lowercased()
                if nm == "img" {
                    let attrs = BlockParser.attributes(of: lit)
                    if let srcAttr = attrs["src"] {
                        let size = ImageSize(width: attrs["width"].flatMap(Double.init), height: attrs["height"].flatMap(Double.init))
                        runs.append(Run(kind: .image(url: srcAttr, alt: attrs["alt"] ?? "", size: (size.width != nil || size.height != nil) ? size : nil),
                                        range: r, open: NSRange(location: r.location, length: 0), close: NSRange(location: r.end, length: 0)))
                        return
                    }
                }
                if nm == "br" { runs.append(Run(kind: .lineBreak, range: r, open: r, close: NSRange(location: r.end, length: 0))); return }
                if ["ins", "u", "kbd", "sub", "sup", "mark"].contains(nm) { tagEvents.append((nm, isClose, r)) }
                else { runs.append(Run(kind: .htmlOther, range: r, open: r, close: NSRange(location: r.end, length: 0))) }
            case "text", "softbreak", "linebreak":
                break
            default:
                // footnote references arrive as an extension node
                if ch(s0) == 0x5B, ch(s0 + 1) == 0x5E, e0 - s0 >= 4, ch(e0 - 1) == 0x5D {
                    runs.append(Run(kind: .footnoteRef, range: abs(NSRange(location: s0, length: e0 - s0)),
                                    open: abs(NSRange(location: s0, length: 2)), close: abs(NSRange(location: e0 - 1, length: 1))))
                } else { inlines(n) }
            }
        }

        // MARK: line-prefix scanning

        /// Quote markers at the start of a line: returns (marker ranges (rel), content start (rel))
        func quotePrefix(_ li: Int) -> (markers: [NSRange], end: Int, depth: Int) {
            let l = table[li]
            var i = l.start
            var markers: [NSRange] = []
            var depth = 0
            while true {
                var j = i
                var sp = 0
                while j < l.contentEnd, ch(j) == 0x20, sp < 3 { j += 1; sp += 1 }
                guard j < l.contentEnd, ch(j) == 0x3E else { break }
                var k = j + 1
                if k < l.contentEnd, ch(k) == 0x20 { k += 1 }
                markers.append(NSRange(location: j, length: k - j))
                depth += 1
                i = k
            }
            return (markers, i, depth)
        }

        // MARK: blocks

        func walk(_ n: Node, quote: Int, listDepth: Int) {
            let t = name(n)
            switch t {
            case "document":
                children(n, quote, listDepth)
            case "block_quote":
                guard let sl = Optional(Int(cmark_node_get_start_line(n)) - 1), sl >= 0 else { return }
                let el = lastLine(n)
                if quote == 0 {
                    var alert: AlertKind?
                    for li in sl...max(sl, el) {
                        let q = quotePrefix(li)
                        models[li].quoteDepth = max(q.depth, 1)
                        models[li].markers.append(contentsOf: q.markers.map(abs))
                        models[li].contentStart = max(models[li].contentStart, q.end - table[li].start)
                        if li == sl {
                            let rest = src.substring(with: NSRange(location: q.end, length: table[li].contentEnd - q.end)).trimmingCharacters(in: .whitespaces)
                            if rest.hasPrefix("[!"), rest.hasSuffix("]"), let k = AlertKind(rawValue: rest.dropFirst(2).dropLast().lowercased()) { alert = k }
                        }
                    }
                    if let a = alert { for li in sl...max(sl, el) { models[li].alert = a }; models[sl].alertTitle = true }
                }
                children(n, quote + 1, listDepth)
            case "list":
                children(n, quote, listDepth + 1)
            case "item", "tasklist":
                let sl = Int(cmark_node_get_start_line(n)) - 1
                guard sl >= 0, sl < table.count else { children(n, quote, listDepth); return }
                let el = lastLine(n)
                let l = table[sl]
                var i = l.start + (models[sl].contentStart)
                while i < l.contentEnd, ch(i) == 0x20 || ch(i) == 0x09 { i += 1 }
                let markerStart = i
                if i < l.contentEnd, [0x2D, 0x2B, 0x2A].contains(ch(i)) {
                    models[sl].bullet = abs(NSRange(location: i, length: 1)); i += 1
                } else {
                    var j = i
                    while j < l.contentEnd, ch(j) >= 0x30, ch(j) <= 0x39 { j += 1 }
                    if j > i, j < l.contentEnd, ch(j) == 0x2E || ch(j) == 0x29 { models[sl].number = abs(NSRange(location: i, length: j + 1 - i)); i = j + 1 }
                }
                while i < l.contentEnd, ch(i) == 0x20 { i += 1 }
                if t == "tasklist", i + 2 < l.contentEnd, ch(i) == 0x5B, ch(i + 2) == 0x5D {
                    let checked = cmark_gfm_extensions_get_tasklist_item_checked(n)
                    models[sl].task = TaskBox(range: abs(NSRange(location: i, length: 3)), checked: checked)
                    i += 3
                    while i < l.contentEnd, ch(i) == 0x20 { i += 1 }
                }
                _ = markerStart
                let cs = i - l.start
                models[sl].listDepth = listDepth
                models[sl].contentStart = cs
                if el > sl { for li in (sl + 1)...el where models[li].bullet == nil && models[li].number == nil {
                    models[li].listDepth = max(models[li].listDepth, listDepth)
                    models[li].contentStart = max(models[li].contentStart, cs)
                } }
                children(n, quote, listDepth)
            case "paragraph":
                inlines(n)
            case "heading":
                let level = Int(cmark_node_get_heading_level(n))
                let sl = Int(cmark_node_get_start_line(n)) - 1
                guard sl >= 0, sl < table.count else { return }
                let l = table[sl]
                var i = l.start + models[sl].contentStart
                while i < l.contentEnd, ch(i) == 0x20 { i += 1 }
                if ch(i) == 0x23 {
                    var j = i
                    while j < l.contentEnd, ch(j) == 0x23 { j += 1 }
                    while j < l.contentEnd, ch(j) == 0x20 || ch(j) == 0x09 { j += 1 }
                    models[sl].kind = .heading(level)
                    models[sl].markers.append(abs(NSRange(location: i, length: j - i)))
                    // closing hashes
                    var e = l.contentEnd
                    while e > j, ch(e - 1) == 0x20 { e -= 1 }
                    var k = e
                    while k > j, ch(k - 1) == 0x23 { k -= 1 }
                    if k < e, k > j, ch(k - 1) == 0x20 { models[sl].markers.append(abs(NSRange(location: k - 1, length: l.contentEnd - (k - 1)))) }
                } else {
                    let ul = lastLine(n)
                    let underline = (cmark_node_get_end_column(n) == 0) ? Int(cmark_node_get_end_line(n)) - 2 : ul
                    for li in sl..<min(max(underline, sl + 1), table.count) { models[li].kind = .heading(level) }
                    if underline >= 0, underline < table.count, underline > sl {
                        models[underline].kind = .setextUnderline
                        models[underline].markers = [abs(NSRange(location: table[underline].start, length: table[underline].contentEnd - table[underline].start))]
                    }
                }
                inlines(n)
            case "code_block":
                let sl = Int(cmark_node_get_start_line(n)) - 1
                let el = lastLine(n)
                guard sl >= 0, sl < table.count else { return }
                let first = table[sl].str.drop { $0 == " " }
                if first.hasPrefix("```") || first.hasPrefix("~~~") {
                    let lang = String(first.drop { $0 == "`" || $0 == "~" }.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
                    for li in sl...max(sl, el) { models[li].kind = .code(lang: lang) }
                    models[sl].kind = .fenceOpen(lang: lang)
                    models[sl].markers = [abs(NSRange(location: table[sl].start, length: table[sl].contentEnd - table[sl].start))]
                    if el > sl {
                        let lastStr = table[el].str.drop { $0 == " " }
                        if lastStr.hasPrefix("```") || lastStr.hasPrefix("~~~") {
                            models[el].kind = .fenceClose
                            models[el].markers = [abs(NSRange(location: table[el].start, length: table[el].contentEnd - table[el].start))]
                        }
                    }
                } else {
                    for li in sl...max(sl, el) where models[li].kind != .blank { models[li].kind = .indentedCode }
                }
            case "thematic_break":
                let sl = Int(cmark_node_get_start_line(n)) - 1
                if sl >= 0, sl < table.count { models[sl].kind = .rule }
            case "html_block":
                let sl = Int(cmark_node_get_start_line(n)) - 1
                let el = lastLine(n)
                guard sl >= 0, sl < table.count else { return }
                let joined = (sl...max(sl, el)).map { table[$0].str }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                // a lone <img ...> line is shown as an image, not as dimmed HTML
                if sl == el, joined.lowercased().hasPrefix("<img"), joined.hasSuffix(">"), !joined.dropFirst().contains("<") {
                    let attrs = BlockParser.attributes(of: joined)
                    if let srcAttr = attrs["src"] {
                        let from = table[sl].start + (table[sl].str as NSString).range(of: "<").location
                        let size = ImageSize(width: attrs["width"].flatMap(Double.init), height: attrs["height"].flatMap(Double.init))
                        runs.append(Run(kind: .image(url: srcAttr, alt: attrs["alt"] ?? "", size: (size.width != nil || size.height != nil) ? size : nil),
                                        range: abs(NSRange(location: from, length: (joined as NSString).length)),
                                        open: abs(NSRange(location: from, length: 0)), close: abs(NSRange(location: from + (joined as NSString).length, length: 0))))
                        return
                    }
                }
                let kind: LineKind = (joined.hasPrefix("<!--") && joined.hasSuffix("-->")) ? .htmlComment : .htmlBlock
                for li in sl...max(sl, el) { models[li].kind = kind }
            case "table":
                walkTable(n, quote: quote)
            default:
                children(n, quote, listDepth)
            }
        }

        func children(_ n: Node, _ q: Int, _ d: Int) {
            var c = cmark_node_first_child(n)
            while let k = c { walk(k, quote: q, listDepth: d); c = cmark_node_next(k) }
        }

        func walkTable(_ n: Node, quote: Int) {
            let sl = Int(cmark_node_get_start_line(n)) - 1
            let el = lastLine(n)
            guard sl >= 0, sl + 1 < table.count else { return }
            var aligns: [TableAlignment] = []
            let cols = Int(cmark_gfm_extensions_get_table_columns(n))
            if let a = cmark_gfm_extensions_get_table_alignments(n) {
                for i in 0..<cols { aligns.append(a[i] == 0x6C ? .left : a[i] == 0x63 ? .center : a[i] == 0x72 ? .right : .none) }
            }
            func split(_ li: Int) -> TableLine {
                let l = table[li]
                let from = l.start + models[li].contentStart
                var pipeAt: [Int] = []
                var i = from
                while i < l.contentEnd {
                    let c = ch(i)
                    if c == 0x5C { i += 2; continue }
                    if c == 0x7C { pipeAt.append(i) }
                    i += 1
                }
                var bounds = [from - 1] + pipeAt + [l.contentEnd]   // segment k lies between bounds[k] and bounds[k+1]
                var segs: [NSRange] = []
                for k in 0..<(bounds.count - 1) {
                    var a = bounds[k] + 1, b = bounds[k + 1]
                    while a < b, ch(a) == 0x20 || ch(a) == 0x09 { a += 1 }
                    while b > a, ch(b - 1) == 0x20 || ch(b - 1) == 0x09 { b -= 1 }
                    segs.append(NSRange(location: a, length: b - a))
                }
                bounds.removeAll()
                // a line that starts with "|" has a blank leading segment; one that ends with "|" has a blank trailing one
                if let f = segs.first, f.length == 0, !pipeAt.isEmpty, pipeAt[0] == from || src.substring(with: NSRange(location: from, length: pipeAt[0] - from)).trimmingCharacters(in: .whitespaces).isEmpty { segs.removeFirst() }
                if let lst = segs.last, lst.length == 0, !pipeAt.isEmpty { segs.removeLast() }
                return TableLine(alignments: aligns, cells: segs.map(abs), pipes: pipeAt.map { abs(NSRange(location: $0, length: 1)) })
            }
            for li in sl...max(sl, el) {
                models[li].kind = li == sl ? .tableHeader : (li == sl + 1 ? .tableDelimiter : .tableRow)
                var tl = split(li)
                if li == sl + 1 { tl.cells = [] }
                models[li].table = tl
            }
            var row = cmark_node_first_child(n)
            while let r = row {
                var cell = cmark_node_first_child(r)
                while let c = cell { inlines(c); cell = cmark_node_next(c) }
                row = cmark_node_next(r)
            }
        }

        // MARK: run cmark

        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS | CMARK_OPT_FOOTNOTES) else {
            return ParsedBlock(range: chunk, lines: models, runs: [])
        }
        for ext in ["table", "strikethrough", "tasklist", "autolink"] {
            if let e = cmark_find_syntax_extension(ext) { cmark_parser_attach_syntax_extension(parser, e) }
        }
        let bytes = Array(masked.utf8)
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { cmark_parser_feed(parser, $0, buf.count) }
        }
        let doc = cmark_parser_finish(parser)
        cmark_parser_free(parser)
        if let doc {
            walk(doc, quote: 0, listDepth: 0)
            cmark_node_free(doc)
        }

        // footnote definitions: "[^id]:" at line start (outside code)
        for (li, l) in table.enumerated() where models[li].kind == .paragraph && l.str.drop(while: { $0 == " " }).hasPrefix("[^") {
            var i = l.start + models[li].contentStart
            while i < l.contentEnd, ch(i) == 0x20 { i += 1 }
            if ch(i) == 0x5B, ch(i + 1) == 0x5E {
                var j = i + 2
                while j < l.contentEnd, ch(j) != 0x5D, ch(j) != 0x20 { j += 1 }
                if j + 1 < l.contentEnd + 1, ch(j) == 0x5D, ch(j + 1) == 0x3A {
                    models[li].kind = .footnoteDef
                    models[li].number = abs(NSRange(location: i, length: j + 2 - i))
                }
            }
        }

        // pair html tags
        var open: [String: [NSRange]] = [:]
        for e in tagEvents {
            if !e.close { open[e.name, default: []].append(e.range) }
            else if let o = open[e.name]?.popLast() {
                let kind: RunKind = (e.name == "ins" || e.name == "u") ? .underline : e.name == "kbd" ? .kbd : e.name == "sub" ? .sub : e.name == "sup" ? .sup : .mark
                runs.append(Run(kind: kind, range: NSRange(location: o.location, length: e.range.end - o.location), open: o, close: e.range))
            } else { runs.append(Run(kind: .htmlOther, range: e.range, open: e.range, close: NSRange(location: e.range.end, length: 0))) }
        }
        for (_, rs) in open { for r in rs { runs.append(Run(kind: .htmlOther, range: r, open: r, close: NSRange(location: r.end, length: 0))) } }

        // math
        for m in mathSpans {
            runs.append(Run(kind: .math(display: m.display), range: abs(m.range), open: abs(m.open), close: abs(m.close)))
        }
        // emoji (not inside code, math or raw html)
        let blocked = runs.filter { r in
            if case .code = r.kind { return true }; if case .math = r.kind { return true }
            if case .htmlOther = r.kind { return true }; if case .link = r.kind { return false }; return false
        }.map { $0.range }
        for (r, e) in Emoji.find(in: src) {
            let a = abs(r)
            let li = lineOf(r.location)
            switch models[li].kind { case .code, .indentedCode, .fenceOpen, .fenceClose, .htmlBlock, .htmlComment: continue; default: break }
            if blocked.contains(where: { $0.intersects(a) }) { continue }
            runs.append(Run(kind: .emoji(e), range: a, open: NSRange(location: a.location, length: 0), close: NSRange(location: a.end, length: 0)))
        }

        // footnote references "[^id]" (cmark only recognises them when the definition is in the same block)
        var f = 0
        while f < src.length - 3 {
            if ch(f) == 0x5B, ch(f + 1) == 0x5E {
                var j = f + 2
                while j < src.length, ch(j) != 0x5D, ch(j) != 0x20, ch(j) != 0x0A, ch(j) != 0x5B { j += 1 }
                let li = lineOf(f)
                let isDef = ch(j + 1) == 0x3A && f == table[li].start + models[li].contentStart
                let a = abs(NSRange(location: f, length: j + 1 - f))
                if j < src.length, ch(j) == 0x5D, j > f + 2, !isDef, !blocked.contains(where: { $0.intersects(a) }),
                   !runs.contains(where: { r in if case .link = r.kind { return r.range.intersects(a) }; return false }) {
                    runs.append(Run(kind: .footnoteRef, range: a, open: NSRange(location: a.location, length: 2), close: NSRange(location: a.end - 1, length: 1)))
                    f = j
                }
            }
            f += 1
        }

        runs.sort { $0.range.location < $1.range.location }
        return ParsedBlock(range: chunk, lines: models, runs: runs)
    }
}

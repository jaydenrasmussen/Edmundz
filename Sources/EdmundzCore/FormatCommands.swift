import Foundation

public struct TextEdit: Equatable {
    public var range: NSRange
    public var replacement: String
    public init(_ range: NSRange, _ replacement: String) { self.range = range; self.replacement = replacement }
}

public struct EditResult: Equatable {
    public var edits: [TextEdit]
    public var selection: NSRange
    public init(edits: [TextEdit], selection: NSRange) { self.edits = edits; self.selection = selection }

    /// Applies the edits (disjoint) to `text`. Used by tests and by the editor to build one undo step.
    public func applied(to text: String) -> String {
        let m = NSMutableString(string: text)
        for e in edits.sorted(by: { $0.range.location > $1.range.location }) { m.replaceCharacters(in: e.range, with: e.replacement) }
        return m as String
    }
}

public enum InlineFormat {
    case bold, italic, underline, strike, code

    var open: String { switch self { case .bold: "**"; case .italic: "*"; case .underline: "<ins>"; case .strike: "~~"; case .code: "`" } }
    var close: String { switch self { case .underline: "</ins>"; default: open } }

    func matches(_ k: RunKind) -> Bool {
        switch (self, k) {
        case (.bold, .bold), (.italic, .italic), (.underline, .underline), (.strike, .strike), (.code, .code): return true
        default: return false
        }
    }
}

public enum ListKind { case bullet, ordered, task }

/// Pure editing operations: given text and a selection, produce edits and a new selection.
public enum FormatCommands {

    // MARK: helpers

    /// New position of `p` after applying disjoint `edits`. Insertions at `p` count as before it.
    static func mapped(_ p: Int, _ edits: [TextEdit]) -> Int {
        var shift = 0
        for e in edits {
            if e.range.end <= p && !(e.range.length == 0 && e.range.location > p) { shift += (e.replacement as NSString).length - e.range.length }
            else if e.range.location < p && p < e.range.end { return e.range.location + (e.replacement as NSString).length + shift - 0 }
        }
        return p + shift
    }

    static func lineRanges(covering sel: NSRange, in t: NSString) -> [NSRange] {
        var out: [NSRange] = []
        guard t.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var r = t.lineRange(for: NSRange(location: min(sel.location, t.length), length: 0))
        if sel.location >= t.length { r = t.lineRange(for: NSRange(location: t.length - 1, length: 0)) }
        out.append(r)
        // selection ends exactly at a line start (after the newline): do not include that line
        let end = sel.length > 0 ? sel.end - 1 : sel.location
        while r.end <= end, r.end < t.length {
            r = t.lineRange(for: NSRange(location: r.end, length: 0))
            out.append(r)
        }
        return out
    }

    static func contentRange(_ line: NSRange, _ t: NSString) -> NSRange {
        var e = line.end
        while e > line.location, t.character(at: e - 1) == 0x0A || t.character(at: e - 1) == 0x0D { e -= 1 }
        return NSRange(location: line.location, length: e - line.location)
    }

    static func lineModel(at offset: Int, _ t: NSString, _ model: DocumentModel) -> LineModel? {
        guard t.length > 0 else { return nil }
        return model.line(at: min(offset, t.length - 1), in: t).map { $0.block.lines[$0.index] }
    }

    static func isLiteralLine(_ k: LineKind) -> Bool {
        switch k {
        case .code, .fenceOpen, .fenceClose, .indentedCode, .mathFence, .mathLine, .mermaidFence, .mermaidLine,
             .frontMatter, .frontMatterFence, .htmlBlock, .htmlComment, .rule, .setextUnderline, .tableDelimiter: return true
        default: return false
        }
    }

    /// Absolute offset where editable text starts on a line (after quote markers, list marker, task box, heading hashes).
    static func contentStart(_ m: LineModel) -> Int {
        var s = m.range.location + m.contentStart
        for mk in m.markers where mk.location == m.range.location + (m.range.length > 0 ? 0 : 0) || mk.location < s + 1 {
            if case .heading = m.kind { s = max(s, mk.end) }
        }
        if case .heading = m.kind, let first = m.markers.first { s = max(s, first.end) }
        return s
    }

    // MARK: inline toggles (bold, italic, underline, strike, code)

    public static func toggleInline(_ f: InlineFormat, text t: NSString, selection sel: NSRange, model: DocumentModel) -> EditResult? {
        // gather runs and line models over the selection
        var runs: [Run] = []
        var lines: [LineModel] = []
        var off = min(sel.location, max(0, t.length - 1))
        if t.length > 0 {
            while true {
                let b = model.block(at: off, in: t)
                runs.append(contentsOf: b.runs); lines.append(contentsOf: b.lines)
                if b.range.end >= sel.end || b.range.end >= t.length { break }
                off = b.range.end
            }
        }
        if let m = lineModel(at: sel.location, t, model), isLiteralLine(m.kind) { return nil }

        // unwrap when the selection touches runs of this kind
        let hit = runs.filter { f.matches($0.kind) && (sel.length == 0 ? ($0.range.location <= sel.location && sel.location <= $0.range.end) : $0.range.intersects(sel) || (sel.location >= $0.range.location && sel.end <= $0.range.end)) }
        if !hit.isEmpty {
            var edits: [TextEdit] = []
            for r in hit { edits.append(TextEdit(r.open, "")); edits.append(TextEdit(r.close, "")) }
            edits.sort { $0.range.location < $1.range.location }
            return EditResult(edits: edits, selection: NSRange(location: mapped(sel.location, edits), length: mapped(sel.end, edits) - mapped(sel.location, edits)))
        }

        // wrap
        var segs: [NSRange] = []
        if sel.length == 0 {
            if let w = wordRange(at: sel.location, t) { segs = [w] }
        } else {
            for line in lineRanges(covering: sel, in: t) {
                let c = contentRange(line, t)
                guard let m = lineModel(at: line.location, t, model), !isLiteralLine(m.kind), m.kind != .blank else { continue }
                var s = NSIntersectionRange(sel, c)
                s.location = max(s.location, min(contentStart(m), c.end)); s.length = max(0, min(s.end, c.end) - s.location)
                while s.length > 0, isSpace(t.character(at: s.location)) { s.location += 1; s.length -= 1 }
                while s.length > 0, isSpace(t.character(at: s.end - 1)) { s.length -= 1 }
                if s.length > 0 { segs.append(s) }
            }
        }
        var open = f.open, close = f.close
        if f == .code, segs.contains(where: { t.substring(with: $0).contains("`") }) { open = "``"; close = "``" }
        if segs.isEmpty {
            let ins = open + close
            return EditResult(edits: [TextEdit(NSRange(location: sel.location, length: 0), ins)],
                              selection: NSRange(location: sel.location + (open as NSString).length, length: 0))
        }
        var edits: [TextEdit] = []
        for s in segs { edits.append(TextEdit(NSRange(location: s.location, length: 0), open)); edits.append(TextEdit(NSRange(location: s.end, length: 0), close)) }
        let first = segs.first!, last = segs.last!
        let newStart = first.location + (open as NSString).length + shiftBefore(first.location, edits, excludingInsertAt: true)
        let newEnd = last.end + shiftBefore(last.end, edits, excludingInsertAt: true)
        return EditResult(edits: edits, selection: NSRange(location: newStart, length: newEnd - newStart))
    }

    /// Total inserted length by edits located strictly before `p` (edits at `p` are not counted).
    static func shiftBefore(_ p: Int, _ edits: [TextEdit], excludingInsertAt: Bool) -> Int {
        var s = 0
        for e in edits where e.range.location < p { s += (e.replacement as NSString).length - e.range.length }
        return s
    }

    static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

    static func wordRange(at p: Int, _ t: NSString) -> NSRange? {
        func isWord(_ c: unichar) -> Bool {
            if c == 0x5F || c == 0x27 { return true }
            guard let u = Unicode.Scalar(c) else { return true }   // surrogate halves belong to words
            return CharacterSet.alphanumerics.contains(u)
        }
        var a = p, b = p
        while a > 0, isWord(t.character(at: a - 1)) { a -= 1 }
        while b < t.length, isWord(t.character(at: b)) { b += 1 }
        return b > a ? NSRange(location: a, length: b - a) : nil
    }

    // MARK: headings

    /// level 0 removes the heading. Pressing the level a line already has toggles it off.
    public static func setHeading(_ level: Int, text t: NSString, selection sel: NSRange, model: DocumentModel) -> EditResult {
        var targets: [(NSRange, LineModel)] = []
        for line in lineRanges(covering: sel, in: t) {
            guard let m = lineModel(at: line.location, t, model), m.kind != .blank, !isLiteralLine(m.kind) else { continue }
            if case .tableHeader = m.kind { continue }; if case .tableRow = m.kind { continue }
            targets.append((line, m))
        }
        guard !targets.isEmpty else { return EditResult(edits: [], selection: sel) }
        func current(_ m: LineModel) -> Int { if case .heading(let n) = m.kind { return n }; return 0 }
        let allSame = level > 0 && targets.allSatisfy { current($0.1) == level }
        let newLevel = allSame ? 0 : level
        let prefix = newLevel > 0 ? String(repeating: "#", count: newLevel) + " " : ""
        var edits: [TextEdit] = []
        for (line, m) in targets {
            if case .heading = m.kind, let first = m.markers.first {
                edits.append(TextEdit(first, prefix))
            } else if case .heading = m.kind {
                // setext: add the prefix and drop the underline line
                let next = t.lineRange(for: NSRange(location: line.end, length: 0))
                edits.append(TextEdit(NSRange(location: line.location, length: 0), prefix))
                if line.end < t.length { edits.append(TextEdit(next, "")) }
            } else if newLevel > 0 {
                edits.append(TextEdit(NSRange(location: min(contentStart(m), contentRange(line, t).end), length: 0), prefix))
            }
        }
        edits.sort { $0.range.location < $1.range.location }
        let a = mapped(sel.location, edits), b = mapped(sel.end, edits)
        return EditResult(edits: edits, selection: NSRange(location: a, length: max(0, b - a)))
    }

    // MARK: lists

    public static func toggleList(_ kind: ListKind, text t: NSString, selection sel: NSRange, model: DocumentModel) -> EditResult {
        var targets: [(NSRange, LineModel)] = []
        for line in lineRanges(covering: sel, in: t) {
            guard let m = lineModel(at: line.location, t, model), m.kind != .blank, !isLiteralLine(m.kind) else { continue }
            if case .heading = m.kind { continue }
            targets.append((line, m))
        }
        guard !targets.isEmpty else { return EditResult(edits: [], selection: sel) }
        func isKind(_ m: LineModel) -> Bool {
            switch kind {
            case .bullet: return m.bullet != nil && m.task == nil
            case .ordered: return m.number != nil
            case .task: return m.task != nil
            }
        }
        let remove = targets.allSatisfy { isKind($0.1) }
        var edits: [TextEdit] = []
        var n = 0
        for (line, m) in targets {
            // region = from after quote prefix + indentation to the content start
            var start = line.location + (m.quoteDepth > 0 ? m.contentStart : 0)
            if m.bullet != nil || m.number != nil {
                start = line.location + (m.quoteDepth > 0 ? quotePrefixLength(m) : 0)
                while start < line.end, t.character(at: start) == 0x20 || t.character(at: start) == 0x09 { start += 1 }
            } else {
                while start < line.end, t.character(at: start) == 0x20 { start += 1 }
            }
            let end = (m.bullet != nil || m.number != nil) ? line.location + m.contentStart : start
            n += 1
            let marker: String
            if remove { marker = "" } else {
                switch kind { case .bullet: marker = "- "; case .ordered: marker = "\(n). "; case .task: marker = "- [ ] " }
            }
            edits.append(TextEdit(NSRange(location: start, length: max(0, end - start)), marker))
        }
        edits.sort { $0.range.location < $1.range.location }
        let a = mapped(sel.location, edits), b = mapped(sel.end, edits)
        return EditResult(edits: edits, selection: NSRange(location: a, length: max(0, b - a)))
    }

    static func quotePrefixLength(_ m: LineModel) -> Int {
        guard let last = m.markers.last else { return 0 }
        return last.end - m.range.location
    }

    // MARK: indent / outdent

    public static func indent(outdent: Bool, text t: NSString, selection sel: NSRange, model: DocumentModel) -> EditResult? {
        var edits: [TextEdit] = []
        var touched = false
        for line in lineRanges(covering: sel, in: t) {
            guard let m = lineModel(at: line.location, t, model), m.kind != .blank, !isLiteralLine(m.kind) else { continue }
            let isItem = m.bullet != nil || m.number != nil
            guard isItem else { continue }
            touched = true
            var lead = line.location
            while lead < line.end, t.character(at: lead) == 0x20 { lead += 1 }
            let indentNow = lead - line.location
            if !outdent {
                // align under the previous item's content when there is one
                var add = 2
                if line.location > 0, let prev = lineModel(at: line.location - 1, t, model), prev.bullet != nil || prev.number != nil, prev.contentStart > indentNow { add = prev.contentStart - indentNow }
                edits.append(TextEdit(NSRange(location: line.location, length: 0), String(repeating: " ", count: add)))
            } else if indentNow > 0 {
                var target = 0
                var p = line.location
                while p > 0 {
                    let pl = t.lineRange(for: NSRange(location: p - 1, length: 0))
                    if let pm = lineModel(at: pl.location, t, model), pm.bullet != nil || pm.number != nil {
                        var pi = pl.location
                        while pi < pl.end, t.character(at: pi) == 0x20 { pi += 1 }
                        if pi - pl.location < indentNow { target = pi - pl.location; break }
                    } else if let pm = lineModel(at: pl.location, t, model), pm.kind == .blank { p = pl.location; continue } else { break }
                    p = pl.location
                }
                edits.append(TextEdit(NSRange(location: line.location, length: indentNow - target), ""))
            }
        }
        guard touched, !edits.isEmpty else { return nil }
        edits.sort { $0.range.location < $1.range.location }
        let a = mapped(sel.location, edits), b = mapped(sel.end, edits)
        return EditResult(edits: edits, selection: NSRange(location: a, length: max(0, b - a)))
    }

    // MARK: Return key

    /// Continues a list or quote on Return; returns nil when the default newline should be used.
    public static func newline(text t: NSString, selection sel: NSRange, model: DocumentModel) -> EditResult? {
        guard sel.length == 0, t.length > 0 else { return nil }
        let at = min(sel.location, t.length - 1)
        guard let m = lineModel(at: sel.location > 0 && sel.location == t.length ? t.length - 1 : at, t, model) else { return nil }
        let line = m.range
        let cEnd = contentRange(line, t).end
        let cs = line.location + m.contentStart
        let isItem = m.bullet != nil || m.number != nil
        let inQuote = m.quoteDepth > 0 && m.alert == nil || m.quoteDepth > 0
        guard isItem || inQuote else { return nil }
        guard sel.location >= cs else { return nil }          // caret inside the marker: default newline
        let itemEmpty = isItem ? (cs >= cEnd) : (cs >= cEnd)
        if itemEmpty {
            // exit: remove the marker/quote prefix, keep any indentation out
            let e = TextEdit(NSRange(location: line.location, length: cEnd - line.location), "")
            return EditResult(edits: [e], selection: NSRange(location: line.location, length: 0))
        }
        var prefix = (t.substring(with: NSRange(location: line.location, length: max(0, cs - line.location))) as NSString)
        var p = prefix as String
        if isItem {
            if let num = m.number {
                let numStr = t.substring(with: num)
                let digits = numStr.dropLast()
                if let n = Int(digits), let delim = numStr.last {
                    let old = "\(digits)\(delim)"
                    let next = "\(n + 1)\(delim)"
                    p = p.replacingOccurrences(of: old, with: next, options: [], range: p.range(of: old))
                }
            }
            if m.task != nil, let tb = m.task {
                let rel = tb.range.location - line.location
                let ns = NSMutableString(string: p)
                if rel >= 0, rel + 3 <= ns.length { ns.replaceCharacters(in: NSRange(location: rel, length: 3), with: "[ ]") }
                p = ns as String
            }
        }
        prefix = p as NSString
        let ins = "\n" + (prefix as String)
        return EditResult(edits: [TextEdit(NSRange(location: sel.location, length: 0), ins)],
                          selection: NSRange(location: sel.location + (ins as NSString).length, length: 0))
    }

    // MARK: link

    /// Wraps the selection as a link, or selects the destination of the link the caret is in.
    public static func link(text t: NSString, selection sel: NSRange, model: DocumentModel) -> EditResult {
        if t.length > 0 {
            let b = model.block(at: min(sel.location, t.length - 1), in: t)
            if let r = b.runs.first(where: { if case .link = $0.kind { return $0.range.location <= sel.location && sel.location <= $0.range.end && $0.close.length > 2 }; return false }) {
                // destination sits between "](" and ")"
                let close = r.close
                let dest = NSRange(location: close.location + 2, length: max(0, close.length - 3))
                return EditResult(edits: [], selection: dest)
            }
        }
        if sel.length > 0 {
            let s = t.substring(with: sel)
            let ins = "[\(s)]()"
            return EditResult(edits: [TextEdit(sel, ins)], selection: NSRange(location: sel.location + (ins as NSString).length - 1, length: 0))
        }
        return EditResult(edits: [TextEdit(sel, "[]()")], selection: NSRange(location: sel.location + 1, length: 0))
    }
}

// MARK: table navigation and asset import helpers

extension FormatCommands {
    /// Tab / Shift-Tab inside a table: moves to the next or previous cell (selecting its text). Tab in the last cell of the
    /// last row appends a new empty row. Returns nil when the caret is not in a table.
    public static func nextCell(text t: NSString, selection sel: NSRange, backward: Bool, model: DocumentModel) -> EditResult? {
        guard t.length > 0 else { return nil }
        let blk = model.block(at: min(sel.location, t.length - 1), in: t)
        var cells: [(line: Int, range: NSRange)] = []
        var columns = 0
        for (i, l) in blk.lines.enumerated() {
            guard l.kind == .tableHeader || l.kind == .tableRow, let tl = l.table else { continue }
            columns = max(columns, tl.cells.count)
            for c in tl.cells { cells.append((i, c)) }
        }
        guard !cells.isEmpty, let here = blk.lineIndex(containing: sel.location),
              blk.lines[here].kind == .tableHeader || blk.lines[here].kind == .tableRow || blk.lines[here].kind == .tableDelimiter else { return nil }
        // current cell: the one containing the caret, otherwise the first starting after it
        var idx = cells.firstIndex { $0.range.location <= sel.location && sel.location <= $0.range.end }
        if idx == nil { idx = cells.firstIndex { $0.range.location > sel.location } ?? cells.count - 1 }
        var target = idx! + (backward ? -1 : 1)
        if backward { target = max(target, 0); return EditResult(edits: [], selection: cells[target].range) }
        if target < cells.count { return EditResult(edits: [], selection: cells[target].range) }
        // past the last cell: append a row
        let last = blk.lines.last { $0.table != nil && $0.kind != .tableDelimiter }!
        var end = last.range.end
        while end > last.range.location, t.character(at: end - 1) == 0x0A || t.character(at: end - 1) == 0x0D { end -= 1 }
        let row = "| " + Array(repeating: " ", count: max(columns, 1)).joined(separator: " | ") + " |"
        let ins = "\n" + row
        return EditResult(edits: [TextEdit(NSRange(location: end, length: 0), ins)], selection: NSRange(location: end + 3, length: 0))
    }
}

/// Naming and link text for images imported by paste or drop (v1.1).
public enum AssetNaming {
    /// "image.png" -> "image.png", then "image-2.png", "image-3.png"... until `exists` is false.
    public static func uniqueName(base: String, ext: String, exists: (String) -> Bool) -> String {
        let clean = base.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let stem = clean.isEmpty ? "image" : clean
        var name = "\(stem).\(ext)"
        var n = 2
        while exists(name) { name = "\(stem)-\(n).\(ext)"; n += 1 }
        return name
    }

    /// `![alt](folder/name)` with spaces in the path percent-encoded so the link stays valid CommonMark.
    public static func markdownImage(alt: String, folder: String, name: String) -> String {
        let path = ([folder, name].filter { !$0.isEmpty }.joined(separator: "/")).addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? name
        let safeAlt = alt.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "![\(safeAlt)](\(path))"
    }
}
